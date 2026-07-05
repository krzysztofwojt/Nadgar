import Foundation
import NadgarShared

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var apiKeyDraft: String
    @Published var assistantModel: String {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var transcriptionModel: String {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var voice: String {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var isAutoReadEnabled: Bool {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var shouldIgnoreSilentModeForAutoRead: Bool {
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
    private let apiKeyValidator: OpenAIAPIKeyValidating
    private let settingsStore: UserDefaults
    private var connectivity: PhoneConnectivityController?
    private var savedAPIKey: String

    init(
        credentialStore: any APIKeyStore = KeychainCredentialStore(),
        apiKeyValidator: OpenAIAPIKeyValidating = OpenAIAPIKeyValidationService(),
        settingsStore: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.apiKeyValidator = apiKeyValidator
        self.settingsStore = settingsStore

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
        self.assistantModel = storedSettings.model
        self.transcriptionModel = storedSettings.transcriptionModel
        self.voice = storedSettings.voice
        self.isAutoReadEnabled = storedSettings.isAutoReadEnabled
        self.shouldIgnoreSilentModeForAutoRead = storedSettings.shouldIgnoreSilentModeForAutoRead
        self.instructions = storedSettings.instructions
        self.lastError = initialError
        if !savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingWatchKeyDeletion = false
        }
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
            statusHandler: { [weak self] status in
                Task { @MainActor in
                    self?.applyWatchStatus(status)
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
            try await apiKeyValidator.validateAPIKey(
                apiKey: trimmed,
                model: ProviderSettings.defaultModel
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

    func clearAPIKeyButtonTapped() {
        guard !hasUnsavedAPIKeyChanges else {
            clearAPIKeyDraft()
            return
        }

        clearAPIKey()
    }

    func clearAPIKey() {
        do {
            try credentialStore.deleteAPIKey()
            clearLocalSavedAPIKeyState()
            persistSavedSettings(hasAPIKey: false)
            apiKeyValidationError = nil
            lastError = nil
        } catch {
            apiKeyValidationError = error.localizedDescription
            return
        }

        pendingWatchKeyDeletion = true

        guard connectivity?.sendDeleteAPIKeyToWatch() == true else {
            watchStatus = "API key deleted locally. Open Nadgar on Apple Watch to finish deleting it there."
            return
        }
    }

    func saveSettings() {
        guard hasUnsavedSettingsChanges else { return }

        persistSettings(draftSettings(hasAPIKey: settings.hasAPIKey), syncDraft: true)
    }

    func setAutoReadEnabled(_ enabled: Bool) {
        guard isAutoReadEnabled != enabled else { return }

        isAutoReadEnabled = enabled
        persistAutoReadSettings(isEnabled: enabled)
    }

    func setShouldIgnoreSilentModeForAutoRead(_ enabled: Bool) {
        guard shouldIgnoreSilentModeForAutoRead != enabled else { return }

        shouldIgnoreSilentModeForAutoRead = enabled
        persistAutoReadSettings(shouldIgnoreSilentMode: enabled)
    }

    func sendSettingsToWatch() {
        connectivity?.sendSettings(currentSettings())
    }

    func clearConversationHistoryOnWatch() {
        guard connectivity?.sendClearConversationHistoryToWatch() == true else {
            watchStatus = "Open WristAssist on Apple Watch to clear conversation history."
            return
        }

        watchStatus = "Clear conversation request sent"
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

    private func persistAutoReadSettings(
        isEnabled: Bool? = nil,
        shouldIgnoreSilentMode: Bool? = nil
    ) {
        let newSettings = ProviderSettings(
            selectedAuthMode: settings.selectedAuthMode,
            hasAPIKey: settings.hasAPIKey,
            model: settings.model,
            transcriptionModel: settings.transcriptionModel,
            voice: settings.voice,
            instructions: settings.instructions,
            isAutoReadEnabled: isEnabled ?? settings.isAutoReadEnabled,
            shouldIgnoreSilentModeForAutoRead: shouldIgnoreSilentMode ?? settings.shouldIgnoreSilentModeForAutoRead,
            ttsModel: settings.ttsModel
        )
        persistSettings(newSettings, syncDraft: false)
    }

    private func persistSettings(_ newSettings: ProviderSettings, syncDraft: Bool) {
        settings = newSettings

        if syncDraft {
            assistantModel = settings.model
            transcriptionModel = settings.transcriptionModel
            voice = settings.voice
            isAutoReadEnabled = settings.isAutoReadEnabled
            shouldIgnoreSilentModeForAutoRead = settings.shouldIgnoreSilentModeForAutoRead
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
            model: assistantModel,
            transcriptionModel: transcriptionModel,
            voice: voice,
            instructions: instructions,
            isAutoReadEnabled: isAutoReadEnabled,
            shouldIgnoreSilentModeForAutoRead: shouldIgnoreSilentModeForAutoRead,
            ttsModel: ProviderSettings.defaultTTSModel
        )
    }

    private func currentSettings() -> ProviderSettings {
        currentSettings(hasAPIKey: settings.hasAPIKey)
    }

    private func currentSettings(hasAPIKey: Bool) -> ProviderSettings {
        ProviderSettings(
            selectedAuthMode: .openAIAPIKey,
            hasAPIKey: hasAPIKey,
            model: settings.model,
            transcriptionModel: settings.transcriptionModel,
            voice: settings.voice,
            instructions: settings.instructions,
            isAutoReadEnabled: settings.isAutoReadEnabled,
            shouldIgnoreSilentModeForAutoRead: settings.shouldIgnoreSilentModeForAutoRead,
            ttsModel: settings.ttsModel
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
            watchStatus = "API key saved on iPhone. Open Nadgar on Apple Watch to sync."
            return
        }
    }

    private func clearLocalSavedAPIKeyState() {
        apiKeyDraft = ""
        savedAPIKey = ""
    }

    private func handleWatchKeyStatus(hasKey: Bool) {
        guard pendingWatchKeyDeletion else { return }

        guard !hasKey else {
            watchStatus = "Open Nadgar on Apple Watch to finish deleting the key there."
            lastError = nil
            return
        }

        pendingWatchKeyDeletion = false
        watchStatus = "Watch: API key deleted"
        lastError = nil
    }

    private func applyWatchStatus(_ status: String) {
        if pendingWatchKeyDeletion && status == "Watch: API key synced" {
            watchStatus = "Open Nadgar on Apple Watch to finish deleting the key there."
            lastError = nil
            return
        }

        watchStatus = status

        if status == "Watch: API key synced" ||
            status == "Watch: API key deleted" ||
            status == "Watch: Idle" ||
            status == "Watch: Listening" ||
            status == "Watch: Speaking"
        {
            lastError = nil
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
