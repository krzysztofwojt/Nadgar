import Foundation
import NadgarShared

struct ProviderModelOption: Identifiable, Hashable {
    var selection: TaskModelSelection
    var displayName: String

    var id: String {
        "\(selection.profileID)|\(selection.model)"
    }
}

struct ProviderProfileOption: Identifiable, Hashable {
    var profileID: String
    var displayName: String

    var id: String {
        profileID
    }
}

struct TaskModelOption: Identifiable, Hashable {
    var model: String
    var displayName: String

    var id: String {
        model
    }
}

struct HermesResponseModelOption: Identifiable, Hashable {
    var modelID: String
    var displayName: String

    var id: String {
        modelID
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var selectedResponse: TaskModelSelection? {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var selectedTranscription: TaskModelSelection? {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var selectedSpeech: TaskModelSelection? {
        didSet { refreshUnsavedSettingsChanges() }
    }
    @Published var speechVoicesByProfileID: [String: String] {
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
    @Published private var apiKeyDrafts: [String: String]
    @Published private var hermesBaseURLDrafts: [String: String]
    @Published private var savedAPIKeys: [String: String]
    @Published private var apiKeyValidationErrors: [String: String]
    @Published private var savingAPIKeyProfileIDs: Set<String>

    private let credentialStore: any APIKeyStore
    private let apiKeyValidator: OpenAIAPIKeyValidating
    private let hermesAPIKeyValidator: HermesAPIKeyValidating
    private let settingsStore: UserDefaults
    private var connectivity: PhoneConnectivityController?

    init(
        credentialStore: any APIKeyStore = KeychainCredentialStore(),
        apiKeyValidator: OpenAIAPIKeyValidating = OpenAIAPIKeyValidationService(),
        hermesAPIKeyValidator: HermesAPIKeyValidating = HermesAPIKeyValidationService(),
        settingsStore: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.apiKeyValidator = apiKeyValidator
        self.hermesAPIKeyValidator = hermesAPIKeyValidator
        self.settingsStore = settingsStore

        var initialError: String?
        var loadedSettings = Self.loadSettings(from: settingsStore)
        var loadedKeys: [String: String] = [:]
        var drafts: [String: String] = [:]
        var hermesURLDrafts: [String: String] = [:]

        for profile in loadedSettings.providerProfiles where profile.type.supportsAPIKey {
            do {
                let apiKey = try credentialStore.loadAPIKey(for: profile.id)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                drafts[profile.id] = apiKey
                if !apiKey.isEmpty {
                    loadedKeys[profile.id] = apiKey
                    loadedSettings.setAPIKeyStatus(true, for: profile.id)
                } else {
                    loadedSettings.setAPIKeyStatus(false, for: profile.id)
                }
            } catch {
                initialError = error.localizedDescription
                drafts[profile.id] = ""
                loadedSettings.setAPIKeyStatus(false, for: profile.id)
            }
        }
        for profile in loadedSettings.providerProfiles where profile.type == .hermes {
            hermesURLDrafts[profile.id] = profile.hermesBaseURL
        }
        loadedSettings.normalizeSelectionsAfterProfileChange()

        self.settings = loadedSettings
        self.selectedResponse = loadedSettings.selectedResponse
        self.selectedTranscription = loadedSettings.selectedTranscription
        self.selectedSpeech = loadedSettings.selectedSpeech
        self.speechVoicesByProfileID = loadedSettings.speechVoicesByProfileID
        self.voice = loadedSettings.voice
        self.isAutoReadEnabled = loadedSettings.isAutoReadEnabled
        self.shouldIgnoreSilentModeForAutoRead = loadedSettings.shouldIgnoreSilentModeForAutoRead
        self.instructions = loadedSettings.instructions
        self.apiKeyDrafts = drafts
        self.hermesBaseURLDrafts = hermesURLDrafts
        self.savedAPIKeys = loadedKeys
        self.apiKeyValidationErrors = [:]
        self.savingAPIKeyProfileIDs = []
        self.lastError = initialError
        prunePendingWatchKeyDeletions()
        persistSettingsIfLoadedStateChanged(loadedSettings)
        refreshUnsavedSettingsChanges()
    }

    func start() {
        guard connectivity == nil else {
            sendSettingsToWatch()
            connectivity?.sendCurrentKeyStateToReachableWatch()
            connectivity?.sendPendingConversationClearToReachableWatch()
            return
        }

        let controller = PhoneConnectivityController(
            settingsProvider: { [weak self] in
                self?.storedSettingsWithCurrentKeyStatuses() ?? .default
            },
            apiKeyProvider: { [credentialStore] profileID in
                try credentialStore.loadAPIKey(for: profileID)
            },
            pendingWatchKeyDeletionProvider: { [weak self] profileID in
                self?.pendingWatchKeyDeletionProfileIDs.contains(Self.normalizedProfileID(profileID)) ?? false
            },
            pendingWatchKeyDeletionIDsProvider: { [weak self] in
                Array(self?.pendingWatchKeyDeletionProfileIDs ?? [])
            },
            pendingConversationClearProvider: { [weak self] in
                self?.pendingWatchConversationClear ?? false
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
            watchKeyStatusHandler: { [weak self] profileID, hasKey in
                Task { @MainActor in
                    self?.handleWatchKeyStatus(profileID: profileID, hasKey: hasKey)
                }
            }
        )
        connectivity = controller
        controller.activate()
        sendSettingsToWatch()
        controller.sendCurrentKeyStateToReachableWatch()
        controller.sendPendingConversationClearToReachableWatch()
    }

    var providerProfiles: [ProviderProfile] {
        settings.providerProfiles
    }

    var responseProviderOptions: [ProviderProfileOption] {
        storedSettingsWithCurrentKeyStatuses().providerProfiles.compactMap { profile in
            guard !responseModelOptions(for: profile.id).isEmpty else { return nil }
            return ProviderProfileOption(profileID: profile.id, displayName: profile.name)
        }
    }

    var transcriptionProviderOptions: [ProviderProfileOption] {
        storedSettingsWithCurrentKeyStatuses().providerProfiles.compactMap { profile in
            guard profile.type.supportsTranscription, profile.hasAPIKey else { return nil }
            return ProviderProfileOption(profileID: profile.id, displayName: profile.name)
        }
    }

    var speechProviderOptions: [ProviderProfileOption] {
        let currentSettings = storedSettingsWithCurrentKeyStatuses()
        return currentSettings.providerProfiles.compactMap { profile in
            guard profile.hasAPIKey,
                  !currentSettings.speechModelOptions(for: profile.id).isEmpty
            else { return nil }
            return ProviderProfileOption(profileID: profile.id, displayName: profile.name)
        }
    }

    var selectedResponseModelOptions: [TaskModelOption] {
        responseModelOptions(for: selectedResponse?.profileID)
    }

    var selectedTranscriptionModelOptions: [TaskModelOption] {
        transcriptionModelOptions(for: selectedTranscription?.profileID)
    }

    var selectedSpeechModelOptions: [TaskModelOption] {
        speechModelOptions(for: selectedSpeech?.profileID)
    }

    var selectedSpeechVoiceOptions: [RealtimeVoiceOption] {
        speechVoiceOptions(for: selectedSpeech?.profileID)
    }

    var selectedSpeechVoice: String {
        guard let profileID = selectedSpeech?.profileID else { return "" }
        let options = speechVoiceOptions(for: profileID)
        guard !options.isEmpty else { return "" }
        return ProviderSettings.normalizedVoice(
            speechVoicesByProfileID[profileID] ?? voice,
            options: options
        )
    }

    var responseModelOptions: [ProviderModelOption] {
        let currentSettings = storedSettingsWithCurrentKeyStatuses()
        return currentSettings.providerProfiles.flatMap { profile -> [ProviderModelOption] in
            guard profile.hasAPIKey else { return [] }

            switch profile.type {
            case .openAI:
                return ProviderSettings.supportedAssistantModels.map { model in
                    ProviderModelOption(
                        selection: TaskModelSelection(profileID: profile.id, model: model.apiValue),
                        displayName: "\(profile.name) / \(model.displayName)"
                    )
                }
            case .hermes:
                guard profile.hasValidHermesBaseURL else { return [] }
                var options = profile.hermesResponseModels.map { model in
                    ProviderModelOption(
                        selection: TaskModelSelection(profileID: profile.id, model: model),
                        displayName: "\(profile.name) / \(model)"
                    )
                }
                if currentSettings.selectedResponse?.profileID == profile.id,
                   let currentModel = currentSettings.selectedResponse?.model,
                   !currentModel.isEmpty,
                   !profile.hermesResponseModels.contains(currentModel) {
                    options.insert(
                        ProviderModelOption(
                            selection: TaskModelSelection(profileID: profile.id, model: currentModel),
                            displayName: "\(profile.name) / \(currentModel) (current unavailable)"
                        ),
                        at: 0
                    )
                }
                return options
            case .custom:
                return []
            }
        }
    }

    var transcriptionModelOptions: [ProviderModelOption] {
        modelOptions(using: ProviderSettings.supportedTranscriptionModels)
    }

    var speechModelOptions: [ProviderModelOption] {
        let currentSettings = storedSettingsWithCurrentKeyStatuses()
        return currentSettings.providerProfiles.flatMap { profile -> [ProviderModelOption] in
            guard profile.hasAPIKey else { return [] }
            return currentSettings.speechModelOptions(for: profile.id).map { model in
                ProviderModelOption(
                    selection: TaskModelSelection(profileID: profile.id, model: model.apiValue),
                    displayName: "\(profile.name) / \(model.displayName)"
                )
            }
        }
    }

    func selectResponseProvider(profileID: String?) {
        guard let profileID, !profileID.isEmpty else {
            selectedResponse = nil
            return
        }

        guard selectedResponse?.profileID != profileID else { return }
        guard let model = preferredResponseModel(for: profileID) else {
            selectedResponse = nil
            return
        }
        selectedResponse = TaskModelSelection(profileID: profileID, model: model)
    }

    func selectResponseModel(_ model: String) {
        guard let profileID = selectedResponse?.profileID,
              responseModelOptions(for: profileID).contains(where: { $0.model == model })
        else { return }
        selectedResponse = TaskModelSelection(profileID: profileID, model: model)
    }

    func selectTranscriptionProvider(profileID: String?) {
        guard let profileID, !profileID.isEmpty else {
            selectedTranscription = nil
            return
        }

        guard selectedTranscription?.profileID != profileID else { return }
        guard let model = transcriptionModelOptions(for: profileID).first?.model else {
            selectedTranscription = nil
            return
        }
        selectedTranscription = TaskModelSelection(profileID: profileID, model: model)
    }

    func selectTranscriptionModel(_ model: String) {
        guard let profileID = selectedTranscription?.profileID,
              transcriptionModelOptions(for: profileID).contains(where: { $0.model == model })
        else { return }
        selectedTranscription = TaskModelSelection(profileID: profileID, model: model)
    }

    func selectSpeechProvider(profileID: String?) {
        guard let profileID, !profileID.isEmpty else {
            selectedSpeech = nil
            return
        }

        guard selectedSpeech?.profileID != profileID else { return }
        guard let model = speechModelOptions(for: profileID).first?.model else {
            selectedSpeech = nil
            return
        }
        selectedSpeech = TaskModelSelection(profileID: profileID, model: model)
        let options = speechVoiceOptions(for: profileID)
        if !options.isEmpty {
            voice = ProviderSettings.normalizedVoice(
                speechVoicesByProfileID[profileID] ?? ProviderSettings.defaultVoice,
                options: options
            )
        }
    }

    func selectSpeechModel(_ model: String) {
        guard let profileID = selectedSpeech?.profileID,
              speechModelOptions(for: profileID).contains(where: { $0.model == model })
        else { return }
        selectedSpeech = TaskModelSelection(profileID: profileID, model: model)
    }

    func selectSpeechVoice(_ selectedVoice: String) {
        guard let profileID = selectedSpeech?.profileID,
              !selectedSpeechVoiceOptions.isEmpty
        else { return }

        let normalizedVoice = ProviderSettings.normalizedVoice(
            selectedVoice,
            options: selectedSpeechVoiceOptions
        )
        speechVoicesByProfileID[profileID] = normalizedVoice
        voice = normalizedVoice
    }

    var canSaveSettings: Bool {
        hasUnsavedSettingsChanges
    }

    var keychainStatus: String {
        if providerProfiles.isEmpty {
            return "No providers"
        }

        if apiKeyDrafts.contains(where: { profileID, draft in
            normalizedAPIKey(draft) != normalizedAPIKey(savedAPIKeys[profileID] ?? "")
        }) {
            return "Unsaved changes"
        }

        let configuredCount = settings.providerProfiles.filter { $0.type.supportsAPIKey && $0.hasAPIKey }.count
        switch configuredCount {
        case 0:
            return "No keys"
        case 1:
            return "1 key"
        default:
            return "\(configuredCount) keys"
        }
    }

    @discardableResult
    func addProvider(type: ProviderType) -> String {
        let profile = ProviderProfile(type: type)
        apiKeyDrafts[profile.id] = ""
        if profile.type == .hermes {
            hermesBaseURLDrafts[profile.id] = profile.hermesBaseURL
        }

        var updatedSettings = storedSettingsWithCurrentKeyStatuses()
        updatedSettings.providerProfiles.append(profile)
        updatedSettings.normalizeSelectionsAfterProfileChange()
        persistSettings(updatedSettings, syncDraft: true, syncKeychain: true)
        return profile.id
    }

    func deleteProviders(at offsets: IndexSet) {
        let idsToDelete = offsets.compactMap { index in
            settings.providerProfiles.indices.contains(index) ? settings.providerProfiles[index].id : nil
        }
        deleteProviders(ids: idsToDelete)
    }

    func deleteProvider(id profileID: String) {
        deleteProviders(ids: [profileID])
    }

    func updateProviderName(profileID: String, name: String) {
        guard let index = settings.providerProfiles.firstIndex(where: { $0.id == profileID }) else { return }

        var profile = settings.providerProfiles[index]
        let oldName = profile.name
        profile.setName(name)
        guard profile.name != oldName else { return }

        var updatedSettings = storedSettingsWithCurrentKeyStatuses()
        updatedSettings.providerProfiles[index] = profile
        persistSettings(updatedSettings, syncDraft: false)
    }

    func apiKeyDraft(for profileID: String) -> String {
        apiKeyDrafts[profileID] ?? ""
    }

    func updateAPIKeyDraft(_ apiKey: String, for profileID: String) {
        apiKeyDrafts[profileID] = apiKey

        if !hasUnsavedAPIKeyChanges(for: profileID) {
            apiKeyValidationErrors[profileID] = nil
        }
    }

    func hermesBaseURLDraft(for profileID: String) -> String {
        hermesBaseURLDrafts[profileID] ?? settings.profile(id: profileID)?.hermesBaseURL ?? ""
    }

    func updateHermesBaseURLDraft(_ baseURL: String, for profileID: String) {
        hermesBaseURLDrafts[profileID] = baseURL

        let normalizedDraft = ProviderProfile.normalizedHermesBaseURL(baseURL)
        if normalizedDraft == settings.profile(id: profileID)?.hermesBaseURL {
            apiKeyValidationErrors[profileID] = nil
        }
    }

    @discardableResult
    func commitHermesBaseURLDraft(profileID: String) -> Bool {
        guard let index = settings.providerProfiles.firstIndex(where: { $0.id == profileID }) else {
            return false
        }

        var profile = settings.providerProfiles[index]
        guard profile.type == .hermes else {
            return false
        }

        let oldBaseURL = profile.hermesBaseURL
        profile.setHermesBaseURL(hermesBaseURLDraft(for: profileID))
        hermesBaseURLDrafts[profileID] = profile.hermesBaseURL
        guard profile.hermesBaseURL != oldBaseURL else {
            return false
        }

        profile.setHermesResponseModels([])
        var updatedSettings = storedSettingsWithCurrentKeyStatuses()
        updatedSettings.providerProfiles[index] = profile
        updatedSettings.normalizeSelectionsAfterProfileChange()
        apiKeyValidationErrors[profileID] = nil
        persistSettings(updatedSettings, syncDraft: true)
        return true
    }

    func clearAPIKeyDraft(for profileID: String) {
        updateAPIKeyDraft("", for: profileID)
    }

    func clearAPIKeyButtonTapped(for profileID: String) {
        guard !hasUnsavedAPIKeyChanges(for: profileID) else {
            clearAPIKeyDraft(for: profileID)
            return
        }

        clearAPIKey(for: profileID)
    }

    func saveAPIKeyDraft(for profileID: String) async {
        guard let existingProfile = settings.profile(id: profileID) else {
            apiKeyValidationErrors[profileID] = "Provider was deleted."
            return
        }
        if existingProfile.type == .hermes {
            commitHermesBaseURLDraft(profileID: profileID)
        }
        guard let profile = settings.profile(id: profileID) else {
            apiKeyValidationErrors[profileID] = "Provider was deleted."
            return
        }
        guard profile.type.supportsAPIKey else {
            apiKeyValidationErrors[profileID] = "This provider does not use an API key yet."
            return
        }

        let trimmed = normalizedAPIKey(apiKeyDrafts[profileID] ?? "")
        guard trimmed != normalizedAPIKey(savedAPIKeys[profileID] ?? "") else {
            apiKeyValidationErrors[profileID] = nil
            return
        }

        savingAPIKeyProfileIDs.insert(profileID)
        apiKeyValidationErrors[profileID] = nil
        defer {
            savingAPIKeyProfileIDs.remove(profileID)
        }

        guard !trimmed.isEmpty else {
            clearAPIKey(for: profileID)
            return
        }

        do {
            let hermesModels = try await validateAPIKey(trimmed, for: profile)
            guard let currentProfile = settings.profile(id: profileID),
                  currentProfile.type == profile.type
            else {
                apiKeyValidationErrors[profileID] = "Provider was deleted."
                return
            }
            if currentProfile.type == .hermes,
               currentProfile.hermesBaseURL != profile.hermesBaseURL {
                apiKeyValidationErrors[profileID] = "Hermes URL changed. Save the key again."
                return
            }
            try credentialStore.saveAPIKey(trimmed, for: profileID)
            savedAPIKeys[profileID] = trimmed
            apiKeyDrafts[profileID] = trimmed
            apiKeyValidationErrors[profileID] = nil

            var updatedSettings = storedSettingsWithCurrentKeyStatuses()
            updatedSettings.setAPIKeyStatus(true, for: profileID)
            if let hermesModels {
                applyHermesResponseModels(hermesModels, to: profileID, in: &updatedSettings)
            }
            updatedSettings.normalizeSelectionsAfterProfileChange()
            removePendingWatchKeyDeletion(profileID: profileID)
            persistSettings(updatedSettings, syncDraft: true)
            syncAPIKeyToWatch(trimmed, profileID: profileID)
            lastError = nil
        } catch {
            apiKeyValidationErrors[profileID] = error.localizedDescription
        }
    }

    func hasUnsavedAPIKeyChanges(for profileID: String) -> Bool {
        normalizedAPIKey(apiKeyDrafts[profileID] ?? "") != normalizedAPIKey(savedAPIKeys[profileID] ?? "")
    }

    func canSaveAPIKey(for profileID: String) -> Bool {
        hasUnsavedAPIKeyChanges(for: profileID) && !isSavingAPIKey(for: profileID)
    }

    func hermesResponseModelOptions(for profileID: String) -> [HermesResponseModelOption] {
        guard let profile = settings.profile(id: profileID), profile.type == .hermes else { return [] }

        var models = profile.hermesResponseModels
        let currentModel = profile.hermesResponseModel
        if !currentModel.isEmpty, !models.contains(currentModel) {
            models.insert(currentModel, at: 0)
        }

        return models.map { model in
            let isUnavailable = model == currentModel && !profile.hermesResponseModels.contains(model)
            return HermesResponseModelOption(
                modelID: model,
                displayName: isUnavailable ? "\(model) (current unavailable)" : model
            )
        }
    }

    func canSelectHermesResponseModel(for profileID: String) -> Bool {
        guard let profile = settings.profile(id: profileID) else { return false }
        return profile.type == .hermes &&
            profile.hasAPIKey &&
            profile.hasValidHermesBaseURL &&
            !profile.hermesResponseModels.isEmpty &&
            !isSavingAPIKey(for: profileID)
    }

    func canRefreshHermesModels(for profileID: String) -> Bool {
        guard let profile = settings.profile(id: profileID) else { return false }
        return profile.type == .hermes &&
            ProviderProfile.hermesV1BaseURL(from: hermesBaseURLDraft(for: profileID)) != nil &&
            !normalizedAPIKey(savedAPIKeys[profileID] ?? "").isEmpty &&
            !hasUnsavedAPIKeyChanges(for: profileID) &&
            !isSavingAPIKey(for: profileID)
    }

    func refreshHermesModels(for profileID: String) async {
        guard let profile = settings.profile(id: profileID), profile.type == .hermes else {
            apiKeyValidationErrors[profileID] = "Provider was deleted."
            return
        }
        commitHermesBaseURLDraft(profileID: profileID)

        let apiKey = normalizedAPIKey(savedAPIKeys[profileID] ?? "")
        guard !apiKey.isEmpty else {
            apiKeyValidationErrors[profileID] = "Save the Hermes API key before refreshing models."
            return
        }

        savingAPIKeyProfileIDs.insert(profileID)
        apiKeyValidationErrors[profileID] = nil
        defer {
            savingAPIKeyProfileIDs.remove(profileID)
        }

        do {
            guard let profile = settings.profile(id: profileID), profile.type == .hermes else {
                apiKeyValidationErrors[profileID] = "Provider was deleted."
                return
            }
            let validatedBaseURL = profile.hermesBaseURL
            let models = try await hermesAPIKeyValidator.validateAPIKey(
                apiKey: apiKey,
                baseURL: validatedBaseURL
            )
            guard let currentProfile = settings.profile(id: profileID), currentProfile.type == .hermes else {
                apiKeyValidationErrors[profileID] = "Provider was deleted."
                return
            }
            guard currentProfile.hermesBaseURL == validatedBaseURL else {
                apiKeyValidationErrors[profileID] = "Hermes URL changed. Refresh models again."
                return
            }
            var updatedSettings = storedSettingsWithCurrentKeyStatuses()
            applyHermesResponseModels(models, to: profileID, in: &updatedSettings)
            updatedSettings.normalizeSelectionsAfterProfileChange()
            persistSettings(updatedSettings, syncDraft: true)
            lastError = nil
        } catch {
            apiKeyValidationErrors[profileID] = error.localizedDescription
        }
    }

    func hasAPIKeyText(for profileID: String) -> Bool {
        !normalizedAPIKey(apiKeyDrafts[profileID] ?? "").isEmpty
    }

    func canClearAPIKey(for profileID: String) -> Bool {
        !isSavingAPIKey(for: profileID)
    }

    func apiKeyValidationError(for profileID: String) -> String? {
        apiKeyValidationErrors[profileID]
    }

    func isSavingAPIKey(for profileID: String) -> Bool {
        savingAPIKeyProfileIDs.contains(profileID)
    }

    func updateHermesResponseModel(profileID: String, model: String) {
        guard let index = settings.providerProfiles.firstIndex(where: { $0.id == profileID }) else { return }

        var profile = settings.providerProfiles[index]
        let oldModel = profile.hermesResponseModel
        profile.setHermesResponseModel(model)
        guard profile.hermesResponseModel != oldModel else { return }

        var updatedSettings = storedSettingsWithCurrentKeyStatuses()
        updatedSettings.providerProfiles[index] = profile
        if updatedSettings.selectedResponse?.profileID == profileID {
            updatedSettings.selectedResponse = TaskModelSelection(
                profileID: profileID,
                model: profile.hermesResponseModel
            )
        }
        updatedSettings.normalizeSelectionsAfterProfileChange()
        apiKeyValidationErrors[profileID] = nil
        persistSettings(updatedSettings, syncDraft: true)
    }

    func saveSettings() {
        guard hasUnsavedSettingsChanges else { return }
        persistSettings(draftSettings(), syncDraft: true, syncKeychain: true)
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
        connectivity?.sendSettings(storedSettingsWithCurrentKeyStatuses())
    }

    func clearConversationHistoryOnWatch() {
        pendingWatchConversationClear = true

        guard connectivity?.sendClearConversationHistoryToWatch() == true else {
            watchStatus = "Open WristAssist on Apple Watch to clear conversation history."
            return
        }

        watchStatus = "Clear conversation request sent"
    }

    private func modelOptions(using models: [OpenAIModelOption]) -> [ProviderModelOption] {
        storedSettingsWithCurrentKeyStatuses().providerProfiles.flatMap { profile -> [ProviderModelOption] in
            guard profile.type == .openAI, profile.hasAPIKey else { return [] }
            return models.map { model in
                ProviderModelOption(
                    selection: TaskModelSelection(profileID: profile.id, model: model.apiValue),
                    displayName: "\(profile.name) / \(model.displayName)"
                )
            }
        }
    }

    private func responseModelOptions(for profileID: String?) -> [TaskModelOption] {
        guard let profileID,
              let profile = storedSettingsWithCurrentKeyStatuses().profile(id: profileID),
              profile.hasAPIKey
        else { return [] }

        switch profile.type {
        case .openAI:
            return ProviderSettings.supportedAssistantModels.map { model in
                TaskModelOption(model: model.apiValue, displayName: model.displayName)
            }
        case .hermes:
            guard profile.hasValidHermesBaseURL else { return [] }
            var options = profile.hermesResponseModels.map { model in
                TaskModelOption(model: model, displayName: model)
            }
            if selectedResponse?.profileID == profile.id,
               let currentModel = selectedResponse?.model,
               !currentModel.isEmpty,
               !profile.hermesResponseModels.contains(currentModel) {
                options.insert(
                    TaskModelOption(model: currentModel, displayName: "\(currentModel) (current unavailable)"),
                    at: 0
                )
            }
            return options
        case .custom:
            return []
        }
    }

    private func transcriptionModelOptions(for profileID: String?) -> [TaskModelOption] {
        guard let profileID,
              let profile = storedSettingsWithCurrentKeyStatuses().profile(id: profileID),
              profile.type.supportsTranscription,
              profile.hasAPIKey
        else { return [] }

        return ProviderSettings.supportedTranscriptionModels.map { model in
            TaskModelOption(model: model.apiValue, displayName: model.displayName)
        }
    }

    private func speechModelOptions(for profileID: String?) -> [TaskModelOption] {
        let currentSettings = storedSettingsWithCurrentKeyStatuses()
        guard let profileID,
              currentSettings.profile(id: profileID)?.hasAPIKey == true
        else { return [] }

        return currentSettings.speechModelOptions(for: profileID).map { model in
            TaskModelOption(model: model.apiValue, displayName: model.displayName)
        }
    }

    private func speechVoiceOptions(for profileID: String?) -> [RealtimeVoiceOption] {
        let currentSettings = storedSettingsWithCurrentKeyStatuses()
        guard let profileID,
              currentSettings.profile(id: profileID)?.hasAPIKey == true
        else { return [] }

        return currentSettings.speechVoiceOptions(for: profileID)
    }

    private func preferredResponseModel(for profileID: String) -> String? {
        guard let profile = storedSettingsWithCurrentKeyStatuses().profile(id: profileID) else { return nil }
        let options = responseModelOptions(for: profileID)
        guard !options.isEmpty else { return nil }

        let preferredModel: String
        switch profile.type {
        case .openAI:
            preferredModel = ProviderSettings.defaultModel
        case .hermes:
            preferredModel = profile.hermesResponseModel
        case .custom:
            return nil
        }

        if options.contains(where: { $0.model == preferredModel }) {
            return preferredModel
        }
        return options.first?.model
    }

    private func validateAPIKey(_ apiKey: String, for profile: ProviderProfile) async throws -> [String]? {
        switch profile.type {
        case .openAI:
            try await apiKeyValidator.validateAPIKey(
                apiKey: apiKey,
                model: ProviderSettings.defaultModel
            )
            return nil
        case .hermes:
            return try await hermesAPIKeyValidator.validateAPIKey(
                apiKey: apiKey,
                baseURL: profile.hermesBaseURL
            )
        case .custom:
            throw HermesAPIValidationError.hermesError("This provider is not configurable yet.")
        }
    }

    private func applyHermesResponseModels(
        _ models: [String],
        to profileID: String,
        in settings: inout ProviderSettings
    ) {
        guard let index = settings.providerProfiles.firstIndex(where: { $0.id == profileID }) else { return }

        var profile = settings.providerProfiles[index]
        profile.setHermesResponseModels(models)
        let currentModel = settings.selectedResponse?.profileID == profileID ?
            settings.selectedResponse?.model ?? profile.hermesResponseModel :
            profile.hermesResponseModel
        let selectedModel = preferredHermesResponseModel(
            currentModel: currentModel,
            availableModels: profile.hermesResponseModels
        )
        profile.setHermesResponseModel(selectedModel)
        settings.providerProfiles[index] = profile

        if settings.selectedResponse?.profileID == profileID {
            settings.selectedResponse = TaskModelSelection(profileID: profileID, model: profile.hermesResponseModel)
        }
    }

    private func preferredHermesResponseModel(currentModel: String, availableModels: [String]) -> String {
        let normalizedCurrent = ProviderProfile.normalizedHermesResponseModel(currentModel)
        if availableModels.contains(normalizedCurrent) {
            return normalizedCurrent
        }
        if availableModels.contains(ProviderProfile.defaultHermesResponseModel) {
            return ProviderProfile.defaultHermesResponseModel
        }
        if normalizedCurrent == ProviderProfile.defaultHermesResponseModel,
           let firstModel = availableModels.first {
            return firstModel
        }
        return normalizedCurrent
    }

    private func deleteProviders(ids: [String]) {
        let normalizedIDs = Set(ids.map(Self.normalizedProfileID))
        guard !normalizedIDs.isEmpty else { return }

        var deletionErrors: [String] = []
        for profileID in normalizedIDs {
            do {
                try credentialStore.deleteAPIKey(for: profileID)
            } catch {
                deletionErrors.append(error.localizedDescription)
            }
            apiKeyDrafts.removeValue(forKey: profileID)
            hermesBaseURLDrafts.removeValue(forKey: profileID)
            savedAPIKeys.removeValue(forKey: profileID)
            apiKeyValidationErrors.removeValue(forKey: profileID)
            savingAPIKeyProfileIDs.remove(profileID)
        }

        var updatedSettings = storedSettingsWithCurrentKeyStatuses()
        updatedSettings.providerProfiles.removeAll { normalizedIDs.contains($0.id) }
        updatedSettings.normalizeSelectionsAfterProfileChange()
        addPendingWatchKeyDeletions(profileIDs: normalizedIDs)
        persistSettings(updatedSettings, syncDraft: true)

        for profileID in normalizedIDs {
            sendDeleteAPIKeyToWatch(profileID: profileID)
        }

        lastError = deletionErrors.first
    }

    private func clearAPIKey(for profileID: String) {
        do {
            try credentialStore.deleteAPIKey(for: profileID)
            savedAPIKeys.removeValue(forKey: profileID)
            apiKeyDrafts[profileID] = ""
            apiKeyValidationErrors[profileID] = nil

            var updatedSettings = storedSettingsWithCurrentKeyStatuses()
            updatedSettings.setAPIKeyStatus(false, for: profileID)
            updatedSettings.normalizeSelectionsAfterProfileChange()
            addPendingWatchKeyDeletions(profileIDs: [Self.normalizedProfileID(profileID)])
            persistSettings(updatedSettings, syncDraft: true)
            lastError = nil
        } catch {
            apiKeyValidationErrors[profileID] = error.localizedDescription
            return
        }

        sendDeleteAPIKeyToWatch(profileID: profileID)
    }

    private func persistAutoReadSettings(
        isEnabled: Bool? = nil,
        shouldIgnoreSilentMode: Bool? = nil
    ) {
        var updatedSettings = settings
        updatedSettings.isAutoReadEnabled = isEnabled ?? settings.isAutoReadEnabled
        updatedSettings.shouldIgnoreSilentModeForAutoRead = shouldIgnoreSilentMode ??
            settings.shouldIgnoreSilentModeForAutoRead
        persistSettings(updatedSettings, syncDraft: false, syncKeychain: true)
    }

    private func persistSettings(_ newSettings: ProviderSettings, syncDraft: Bool, syncKeychain: Bool = false) {
        var normalizedSettings = newSettings
        normalizedSettings.normalizeSelectionsAfterProfileChange()
        if normalizedSettings != settings {
            normalizedSettings.configurationVersion = max(
                settings.configurationVersion + 1,
                normalizedSettings.configurationVersion
            )
        }
        settings = normalizedSettings

        if syncDraft {
            selectedResponse = settings.selectedResponse
            selectedTranscription = settings.selectedTranscription
            selectedSpeech = settings.selectedSpeech
            speechVoicesByProfileID = settings.speechVoicesByProfileID
            syncHermesBaseURLDrafts(from: settings)
            voice = settings.voice
            isAutoReadEnabled = settings.isAutoReadEnabled
            shouldIgnoreSilentModeForAutoRead = settings.shouldIgnoreSilentModeForAutoRead
            instructions = settings.instructions
        }

        do {
            let data = try JSONEncoder().encode(settings)
            settingsStore.set(data, forKey: Self.settingsKey)
            sendSettingsToWatch()
            if syncKeychain {
                syncKeychainStateToWatch()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistSettingsIfLoadedStateChanged(_ loadedSettings: ProviderSettings) {
        guard let data = settingsStore.data(forKey: Self.settingsKey),
              let decoded = try? JSONDecoder().decode(ProviderSettings.self, from: data),
              decoded == loadedSettings
        else {
            do {
                let data = try JSONEncoder().encode(loadedSettings)
                settingsStore.set(data, forKey: Self.settingsKey)
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
    }

    private func draftSettings() -> ProviderSettings {
        var draft = storedSettingsWithCurrentKeyStatuses()
        draft.selectedResponse = selectedResponse
        draft.selectedTranscription = selectedTranscription
        draft.selectedSpeech = selectedSpeech
        draft.speechVoicesByProfileID = speechVoicesByProfileID
        draft.model = selectedResponse?.model ?? ProviderSettings.defaultModel
        draft.transcriptionModel = selectedTranscription?.model ?? ProviderSettings.defaultTranscriptionModel
        draft.ttsModel = selectedSpeech?.model ?? ProviderSettings.defaultTTSModel
        let selectedVoice = selectedSpeechVoice
        if !selectedVoice.isEmpty {
            draft.voice = selectedVoice
        } else {
            draft.voice = voice
        }
        draft.instructions = instructions
        draft.isAutoReadEnabled = isAutoReadEnabled
        draft.shouldIgnoreSilentModeForAutoRead = shouldIgnoreSilentModeForAutoRead
        draft.normalizeSelectionsAfterProfileChange()
        return draft
    }

    private func storedSettingsWithCurrentKeyStatuses() -> ProviderSettings {
        var updatedSettings = settings
        for profile in updatedSettings.providerProfiles {
            let hasKey = !normalizedAPIKey(savedAPIKeys[profile.id] ?? "").isEmpty
            updatedSettings.setAPIKeyStatus(hasKey, for: profile.id)
        }
        updatedSettings.normalizeSelectionsAfterProfileChange()
        return updatedSettings
    }

    private func syncHermesBaseURLDrafts(from settings: ProviderSettings) {
        let hermesProfiles = settings.providerProfiles.filter { $0.type == .hermes }
        let hermesProfileIDs = Set(hermesProfiles.map(\.id))
        hermesBaseURLDrafts = hermesBaseURLDrafts.filter { hermesProfileIDs.contains($0.key) }

        for profile in hermesProfiles {
            hermesBaseURLDrafts[profile.id] = profile.hermesBaseURL
        }
    }

    private func refreshUnsavedSettingsChanges() {
        hasUnsavedSettingsChanges = draftSettings() != storedSettingsWithCurrentKeyStatuses()
    }

    private func normalizedAPIKey(_ apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedProfileID(_ profileID: String) -> String {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProviderProfile.legacyOpenAIProfileID : trimmed
    }

    private static let settingsKey = "ProviderSettings"
    private static let pendingWatchKeyDeletionKey = "PendingWatchAPIKeyDeletionProfileIDs"
    private static let legacyPendingWatchKeyDeletionKey = "PendingWatchAPIKeyDeletion"
    private static let pendingWatchConversationClearKey = "PendingWatchConversationClear"

    private var pendingWatchKeyDeletionProfileIDs: Set<String> {
        get {
            var ids = Set(settingsStore.stringArray(forKey: Self.pendingWatchKeyDeletionKey) ?? [])
            if settingsStore.bool(forKey: Self.legacyPendingWatchKeyDeletionKey) {
                ids.insert(ProviderProfile.legacyOpenAIProfileID)
            }
            return ids
        }
        set {
            settingsStore.set(Array(newValue).sorted(), forKey: Self.pendingWatchKeyDeletionKey)
            settingsStore.set(false, forKey: Self.legacyPendingWatchKeyDeletionKey)
        }
    }

    private var pendingWatchConversationClear: Bool {
        get {
            settingsStore.bool(forKey: Self.pendingWatchConversationClearKey)
        }
        set {
            settingsStore.set(newValue, forKey: Self.pendingWatchConversationClearKey)
        }
    }

    private func addPendingWatchKeyDeletions(profileIDs: Set<String>) {
        var pending = pendingWatchKeyDeletionProfileIDs
        pending.formUnion(profileIDs.map(Self.normalizedProfileID))
        pendingWatchKeyDeletionProfileIDs = pending
    }

    private func removePendingWatchKeyDeletion(profileID: String) {
        var pending = pendingWatchKeyDeletionProfileIDs
        pending.remove(Self.normalizedProfileID(profileID))
        pendingWatchKeyDeletionProfileIDs = pending
    }

    private func prunePendingWatchKeyDeletions() {
        let knownIDs = Set(settings.providerProfiles.map(\.id))
        var pending = pendingWatchKeyDeletionProfileIDs
        pending = pending.filter { !knownIDs.contains($0) || !hasSavedKey(profileID: $0) }
        pendingWatchKeyDeletionProfileIDs = pending
    }

    private func hasSavedKey(profileID: String) -> Bool {
        !normalizedAPIKey(savedAPIKeys[profileID] ?? "").isEmpty
    }

    private func syncAPIKeyToWatch(_ apiKey: String, profileID: String) {
        guard connectivity?.syncAPIKeyToWatch(apiKey, profileID: profileID) == true else {
            watchStatus = "API key saved on iPhone. Open Nadgar on Apple Watch to sync."
            return
        }
    }

    private func sendDeleteAPIKeyToWatch(profileID: String) {
        guard connectivity?.sendDeleteAPIKeyToWatch(profileID: profileID) == true else {
            watchStatus = "API key deleted locally. Open Nadgar on Apple Watch to finish deleting it there."
            return
        }
    }

    private func syncKeychainStateToWatch() {
        connectivity?.sendCurrentKeyStateToReachableWatch()
    }

    private func handleWatchKeyStatus(profileID: String?, hasKey: Bool) {
        let resolvedProfileID = Self.normalizedProfileID(profileID ?? ProviderProfile.legacyOpenAIProfileID)
        guard pendingWatchKeyDeletionProfileIDs.contains(resolvedProfileID) else { return }

        guard !hasKey else {
            watchStatus = "Open Nadgar on Apple Watch to finish deleting the key there."
            lastError = nil
            return
        }

        removePendingWatchKeyDeletion(profileID: resolvedProfileID)
        watchStatus = "Watch: API key deleted"
        lastError = nil
    }

    private func applyWatchStatus(_ status: String) {
        if status == "Watch: conversation history cleared" {
            pendingWatchConversationClear = false
            watchStatus = status
            lastError = nil
            return
        }

        if !pendingWatchKeyDeletionProfileIDs.isEmpty && status == "Watch: API key synced" {
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

    private static func loadSettings(from defaults: UserDefaults) -> ProviderSettings {
        guard let data = defaults.data(forKey: settingsKey),
              var settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else {
            return .default
        }

        if settings.selectedAuthMode == .chatGPTCodexUnavailable {
            settings.selectedAuthMode = .openAIAPIKey
        }
        return settings
    }
}
