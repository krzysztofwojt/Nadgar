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

    private let credentialStore: CredentialStoring
    private let tokenService: OpenAIRealtimeTokenServing
    private let settingsStore: UserDefaults
    private let safetyIdentifierStore: SafetyIdentifierStore
    private var connectivity: PhoneConnectivityController?
    private var savedAPIKey: String

    init(
        credentialStore: CredentialStoring = KeychainCredentialStore(),
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
            return
        }

        let controller = PhoneConnectivityController(
            settingsProvider: { [weak self] in
                self?.currentSettings() ?? .default
            },
            apiKeyProvider: { [credentialStore] in
                try credentialStore.loadAPIKey()
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
            }
        )
        connectivity = controller
        controller.activate()
        sendSettingsToWatch()
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
            deleteSavedAPIKey()
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

    private func deleteSavedAPIKey() {
        do {
            try credentialStore.deleteAPIKey()
            apiKeyDraft = ""
            savedAPIKey = ""
            persistSavedSettings(hasAPIKey: false)
            lastError = nil
        } catch {
            apiKeyValidationError = error.localizedDescription
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
