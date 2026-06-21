import Foundation
import WristAssistShared

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var apiKeyDraft: String
    @Published var voice: String {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var instructions: String {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published private(set) var settings: ProviderSettings {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published private(set) var hasUnsavedSettingsChanges = false
    @Published private(set) var watchStatus = "Not connected"
    @Published private(set) var lastError: String?
    @Published private(set) var apiKeyValidationError: String?
    @Published private(set) var isSavingAPIKey = false

    private let credentialStore: any APIKeyStore
    private let tokenService: OpenAIRealtimeTokenServing
    private let settingsStore: UserDefaults
    private let safetyIdentifierStore: SafetyIdentifierStore
    private var connectivity: PhoneConnectivityController?
    private var savedAPIKey: String

    init(
        credentialStore: any APIKeyStore = KeychainCredentialStore(),
        tokenService: OpenAIRealtimeTokenServing = OpenAIRealtimeTokenService(),
        settingsStore: UserDefaults = .standard,
        safetyIdentifierStore: SafetyIdentifierStore = SafetyIdentifierStore()
    ) {
        self.credentialStore = credentialStore
        self.tokenService = tokenService
        self.settingsStore = settingsStore
        self.safetyIdentifierStore = safetyIdentifierStore

        var initialError: String?
        let storedAPIKey: String?
        do {
            storedAPIKey = try credentialStore.loadAPIKey()
        } catch {
            storedAPIKey = nil
            initialError = error.localizedDescription
        }

        let savedAPIKey = storedAPIKey ?? ""
        let storedSettings = Self.loadSettings(from: settingsStore, hasAPIKey: !savedAPIKey.isEmpty)
        self.apiKeyDraft = savedAPIKey
        self.savedAPIKey = savedAPIKey
        self.settings = storedSettings
        self.voice = storedSettings.voice
        self.instructions = storedSettings.instructions
        self.lastError = initialError
        refreshUnsavedSettingsChanges()
    }

    func start() {
        guard connectivity == nil else {
            sendSettingsToWatch()
            connectivity?.sendCurrentKeyStateToReachableWatch()
            return
        }

        let controller = PhoneConnectivityController(
            settingsProvider: { [weak self] in
                self?.currentSettings() ?? .default
            },
            apiKeyProvider: { [credentialStore] in
                try credentialStore.loadAPIKey()
            },
            pendingWatchKeyDeletionProvider: { [weak self] in
                self?.pendingWatchKeyDeletion ?? false
            },
            tokenService: tokenService,
            statusHandler: { [weak self] status in
                Task { @MainActor in
                    self?.watchStatus = status
                }
            },
            errorHandler: { [weak self] message in
                Task { @MainActor in
                    self?.lastError = message
                }
            },
            watchKeyStatusHandler: { [weak self] hasKey in
                Task { @MainActor in
                    self?.handleWatchKeyStatus(hasKey: hasKey)
                }
            }
        )
        connectivity = controller
        controller.activate()
        sendSettingsToWatch()
        controller.sendCurrentKeyStateToReachableWatch()
    }

    func saveAPIKeyDraft() async {
        let trimmed = normalizedAPIKey(apiKeyDraft)
        guard trimmed != normalizedAPIKey(savedAPIKey) else {
            apiKeyValidationError = nil
            return
        }

        isSavingAPIKey = true
        apiKeyValidationError = nil
        defer {
            isSavingAPIKey = false
        }

        guard !trimmed.isEmpty else {
            clearAPIKey()
            return
        }

        do {
            _ = try await tokenService.createClientSecret(
                apiKey: trimmed,
                settings: currentSettings(hasAPIKey: true),
                safetyIdentifier: safetyIdentifierStore.identifier()
            )
            try credentialStore.saveAPIKey(trimmed)
            savedAPIKey = trimmed
            if apiKeyDraft != trimmed {
                apiKeyDraft = trimmed
            }
            persistSavedSettings(hasAPIKey: true)
            pendingWatchKeyDeletion = false
            syncAPIKeyToWatch(trimmed)
            lastError = nil
        } catch {
            apiKeyValidationError = error.localizedDescription
        }
    }

    func updateAPIKeyDraft(_ apiKey: String) {
        apiKeyDraft = apiKey

        if !hasUnsavedAPIKeyChanges {
            apiKeyValidationError = nil
        }
    }

    func clearAPIKeyDraft() {
        updateAPIKeyDraft("")
    }

    func clearAPIKey() {
        var localDeleteSucceeded = false

        do {
            try credentialStore.deleteAPIKey()
            clearLocalSavedAPIKeyState()
            persistSavedSettings(hasAPIKey: false)
            apiKeyValidationError = nil
            lastError = nil
            localDeleteSucceeded = true
        } catch {
            apiKeyValidationError = error.localizedDescription
        }

        pendingWatchKeyDeletion = true

        guard connectivity?.sendDeleteAPIKeyToWatch() == true else {
            watchStatus = localDeleteSucceeded
                ? "API key deleted locally. Open WristAssist on Apple Watch to finish deleting it there."
                : "Open WristAssist on Apple Watch to finish deleting the key there."
            return
        }
    }

    func saveSettings() {
        guard hasUnsavedSettingsChanges else { return }

        persistSettings(draftSettings(hasAPIKey: settings.hasAPIKey), syncDraft: true)
    }

    func sendSettingsToWatch() {
        connectivity?.sendSettings(currentSettings())
    }

    var hasUnsavedAPIKeyChanges: Bool {
        normalizedAPIKey(apiKeyDraft) != normalizedAPIKey(savedAPIKey)
    }

    var canSaveAPIKey: Bool {
        hasUnsavedAPIKeyChanges && !isSavingAPIKey
    }

    var canSaveSettings: Bool {
        hasUnsavedSettingsChanges
    }

    var hasAPIKeyText: Bool {
        !normalizedAPIKey(apiKeyDraft).isEmpty
    }

    var canClearAPIKey: Bool {
        !isSavingAPIKey
    }

    private func persistSavedSettings(hasAPIKey: Bool) {
        persistSettings(currentSettings(hasAPIKey: hasAPIKey), syncDraft: false)
    }

    private func persistSettings(_ newSettings: ProviderSettings, syncDraft: Bool) {
        settings = newSettings

        if syncDraft {
            voice = settings.voice
            instructions = settings.instructions
        }

        do {
            let data = try JSONEncoder().encode(settings)
            settingsStore.set(data, forKey: Self.settingsKey)
            sendSettingsToWatch()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func draftSettings(hasAPIKey: Bool) -> ProviderSettings {
        ProviderSettings(
            selectedAuthMode: .openAIAPIKey,
            hasAPIKey: hasAPIKey,
            model: ProviderSettings.defaultModel,
            voice: voice,
            instructions: instructions
        )
    }

    private func currentSettings() -> ProviderSettings {
        currentSettings(hasAPIKey: settings.hasAPIKey)
    }

    private func currentSettings(hasAPIKey: Bool) -> ProviderSettings {
        ProviderSettings(
            selectedAuthMode: .openAIAPIKey,
            hasAPIKey: hasAPIKey,
            model: ProviderSettings.defaultModel,
            voice: settings.voice,
            instructions: settings.instructions
        )
    }

    private func refreshUnsavedSettingsChanges() {
        hasUnsavedSettingsChanges = draftSettings(hasAPIKey: settings.hasAPIKey) != currentSettings()
    }

    private func normalizedAPIKey(_ apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let settingsKey = "ProviderSettings"
    private static let pendingWatchKeyDeletionKey = "PendingWatchAPIKeyDeletion"

    private var pendingWatchKeyDeletion: Bool {
        get {
            settingsStore.bool(forKey: Self.pendingWatchKeyDeletionKey)
        }
        set {
            settingsStore.set(newValue, forKey: Self.pendingWatchKeyDeletionKey)
        }
    }

    private func syncAPIKeyToWatch(_ apiKey: String) {
        guard connectivity?.syncAPIKeyToWatch(apiKey) == true else {
            watchStatus = "API key saved on iPhone. Open WristAssist on Apple Watch to sync."
            return
        }
    }

    private func clearLocalSavedAPIKeyState() {
        apiKeyDraft = ""
        savedAPIKey = ""
    }

    private func handleWatchKeyStatus(hasKey: Bool) {
        guard pendingWatchKeyDeletion else { return }

        if !hasKey {
            pendingWatchKeyDeletion = false
            watchStatus = "Watch: API key deleted"
        }
    }

    private static func loadSettings(from defaults: UserDefaults, hasAPIKey: Bool) -> ProviderSettings {
        guard let data = defaults.data(forKey: settingsKey),
              var settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else {
            var defaults = ProviderSettings.default
            defaults.hasAPIKey = hasAPIKey
            return defaults
        }

        settings.hasAPIKey = hasAPIKey
        if settings.selectedAuthMode == .chatGPTCodexUnavailable {
            settings.selectedAuthMode = .openAIAPIKey
        }
        return settings
    }
}
