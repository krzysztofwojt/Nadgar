import Foundation
import os
import Security
import WristAssistShared

@MainActor
final class WatchVoiceViewModel: ObservableObject {
    private static let minimumRecordingMilliseconds = 250
    private static let transcriptionPlaceholderText = "Transcribing..."
    private static let transcriptionFailedPlaceholderText = "Transcription failed"
    private static let assistantPlaceholderText = "Writing..."
    private static let assistantFailedPlaceholderText = "Response failed"
    private static let recordingStartFailedText = "Recording could not be started."
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
        category: "WatchVoiceViewModel"
    )

    @Published private(set) var pttState: WatchPTTState
    @Published private(set) var settings: ProviderSettings
    @Published private(set) var errorMessage: String?
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var isPushToTalkRecording = false
    @Published private(set) var isRecordingLocked = false

    var hasAPIKey: Bool {
        normalizedAPIKey != nil
    }

    var canBeginRecording: Bool {
        hasAPIKey &&
            !isPushToTalkRecording &&
            !isRecordingLocked &&
            !isRecordingStartPending &&
            (pttState == .ready || pttState == .failed)
    }

    var isProcessing: Bool {
        pttState == .transcribing || pttState == .thinking
    }

    var statusText: String {
        pttState.statusText
    }

    private let connectivity: WatchConnectivityClient
    private let configurationStore: WatchConfigurationStore
    private let recorder: WatchPTTRecorder
    private let transcriptionClient: OpenAITranscriptionClient
    private let responsesClient: OpenAIResponsesClient
    private let openAITestMode: WatchOpenAITestMode
    private var apiKey: String?
    private var isPushToTalkHoldActive = false
    private var isRecordingStartPending = false
    private var shouldFinishPushToTalkAfterStart = false
    private var shouldLockPushToTalkAfterStart = false
    private var shouldCancelPushToTalkAfterStart = false
    private var activeRecordingStartID: UUID?
    private var activeTurnID = UUID()
    private var remainingMockTranscriptionFailures = 0

    private struct TranscribingPlaceholderReservation {
        var id: UUID
        var previousMessage: ChatMessage?
    }

    init(
        connectivity: WatchConnectivityClient = WatchConnectivityClient(),
        configurationStore: WatchConfigurationStore = WatchConfigurationStore(),
        recorder: WatchPTTRecorder? = nil,
        transcriptionClient: OpenAITranscriptionClient = OpenAITranscriptionClient(),
        responsesClient: OpenAIResponsesClient = OpenAIResponsesClient(),
        openAITestMode: WatchOpenAITestMode = .current
    ) {
        let localConfiguration = configurationStore.loadConfiguration()

        self.connectivity = connectivity
        self.configurationStore = configurationStore
        self.recorder = recorder ?? WatchPTTRecorder()
        self.transcriptionClient = transcriptionClient
        self.responsesClient = responsesClient
        self.openAITestMode = openAITestMode
        self.remainingMockTranscriptionFailures = openAITestMode.transcriptionFailuresBeforeSuccess
        self.pttState = .ready
        self.settings = localConfiguration.settings
        self.apiKey = openAITestMode.apiKeyOverride ?? (try? configurationStore.loadAPIKey())
        self.messages = []

        self.recorder.cleanupTemporaryFiles()

        connectivity.onConfigurationChanged = { [weak self] configuration in
            Task { @MainActor in
                self?.applyConfiguration(configuration)
            }
        }
        connectivity.onSettingsChanged = { [weak self] settings in
            Task { @MainActor in
                self?.applySettingsOnly(settings)
            }
        }
        connectivity.onSyncAPIKey = { [weak self] apiKey in
            self?.syncAPIKeyFromPhone(apiKey) ?? false
        }
        connectivity.onDeleteAPIKey = { [weak self] in
            self?.deleteAPIKeyFromWatch() ?? false
        }
        connectivity.hasLocalAPIKey = { [weak self] in
            self?.hasAPIKey ?? false
        }
        connectivity.activate()

        if openAITestMode.isEnabled {
            Self.logger.info("openai mock mode enabled")
        }
    }

    func requestInitialSettings() async {
        do {
            applyConfiguration(try await connectivity.requestConfiguration())
        } catch {
            errorMessage = nil
        }

        if !openAITestMode.isEnabled {
            try? await connectivity.requestKeyStatus()
        }

        await prewarmRecorderIfPossible()
    }

    func prepareForForeground() async {
        await prewarmRecorderIfPossible()
    }

    func suspendAudioWarmup() {
        recorder.cancel()

        guard isPushToTalkRecording || isRecordingStartPending || isPushToTalkHoldActive else {
            return
        }

        activeTurnID = UUID()
        activeRecordingStartID = nil
        isPushToTalkHoldActive = false
        isRecordingStartPending = false
        shouldFinishPushToTalkAfterStart = false
        shouldLockPushToTalkAfterStart = false
        shouldCancelPushToTalkAfterStart = false
        isPushToTalkRecording = false
        isRecordingLocked = false

        if pttState == .recording {
            pttState = .ready
        }
    }

    func beginPushToTalkRecording() {
        guard !isPushToTalkHoldActive else { return }
        isPushToTalkHoldActive = true

        guard canBeginRecording else {
            isPushToTalkHoldActive = false
            Self.logger.info("ptt begin ignored state=\(self.pttState.rawValue, privacy: .public) hasKey=\(self.hasAPIKey, privacy: .public)")
            return
        }

        errorMessage = nil
        isRecordingStartPending = true
        shouldFinishPushToTalkAfterStart = false
        shouldLockPushToTalkAfterStart = false
        shouldCancelPushToTalkAfterStart = false
        isPushToTalkRecording = true
        isRecordingLocked = false
        pttState = .recording
        let recordingStartID = UUID()
        activeRecordingStartID = recordingStartID
        Self.logger.info("ptt recording requested")

        Task {
            do {
                try await recorder.start()
                guard activeRecordingStartID == recordingStartID else {
                    Self.logger.info("ptt recording start ignored because it is stale")
                    return
                }

                activeRecordingStartID = nil
                isRecordingStartPending = false
                Self.logger.info("ptt recording active")

                if shouldCancelPushToTalkAfterStart {
                    shouldCancelPushToTalkAfterStart = false
                    await cancelPushToTalkRecordingIfNeeded()
                    return
                }

                if shouldLockPushToTalkAfterStart {
                    shouldLockPushToTalkAfterStart = false
                    isRecordingLocked = true
                    Self.logger.info("ptt recording locked")
                    return
                }

                if shouldFinishPushToTalkAfterStart || !isPushToTalkHoldActive {
                    shouldFinishPushToTalkAfterStart = false
                    await finishPushToTalkRecordingIfNeeded()
                }
            } catch {
                guard activeRecordingStartID == recordingStartID else {
                    Self.logger.info("ptt recording start failure ignored because it is stale")
                    return
                }

                activeRecordingStartID = nil

                if shouldCancelPushToTalkAfterStart {
                    await cancelPushToTalkRecordingIfNeeded()
                    return
                }

                isRecordingStartPending = false
                shouldFinishPushToTalkAfterStart = false
                shouldLockPushToTalkAfterStart = false
                shouldCancelPushToTalkAfterStart = false
                isPushToTalkRecording = false
                isPushToTalkHoldActive = false
                isRecordingLocked = false
                recorder.cancel()

                if (error as? WatchPTTRecorderError) == .recordingStartCancelled {
                    pttState = .ready
                    errorMessage = nil
                    Self.logger.info("ptt recording start cancelled")
                    return
                }

                pttState = .failed
                errorMessage = error.localizedDescription
                appendRecordingStartFailure(error.localizedDescription)
                Self.logger.error("ptt recording start failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func endPushToTalkRecording() {
        guard isPushToTalkHoldActive || isPushToTalkRecording || isRecordingStartPending else { return }
        isPushToTalkHoldActive = false

        if isRecordingStartPending {
            shouldFinishPushToTalkAfterStart = true
            return
        }

        Task {
            await finishPushToTalkRecordingIfNeeded()
        }
    }

    func lockPushToTalkRecording() {
        guard isPushToTalkHoldActive || isPushToTalkRecording || isRecordingStartPending else { return }
        isPushToTalkHoldActive = false

        if isRecordingStartPending {
            isRecordingLocked = true
            shouldLockPushToTalkAfterStart = true
            shouldFinishPushToTalkAfterStart = false
            shouldCancelPushToTalkAfterStart = false
            return
        }

        guard isPushToTalkRecording else { return }
        isRecordingLocked = true
        Self.logger.info("ptt recording locked")
    }

    func finishLockedPushToTalkRecording() {
        guard isRecordingLocked else { return }
        isRecordingLocked = false
        isPushToTalkHoldActive = false

        if isRecordingStartPending {
            shouldFinishPushToTalkAfterStart = true
            shouldLockPushToTalkAfterStart = false
            shouldCancelPushToTalkAfterStart = false
            return
        }

        Task {
            await finishPushToTalkRecordingIfNeeded()
        }
    }

    func cancelPushToTalkRecording() {
        guard isPushToTalkHoldActive || isPushToTalkRecording || isRecordingStartPending || isRecordingLocked else { return }
        isPushToTalkHoldActive = false
        isRecordingLocked = false
        shouldFinishPushToTalkAfterStart = false
        shouldLockPushToTalkAfterStart = false

        if isRecordingStartPending {
            shouldCancelPushToTalkAfterStart = true
            isPushToTalkRecording = false
            pttState = .ready
            recorder.cancel()
            return
        }

        Task {
            await cancelPushToTalkRecordingIfNeeded()
        }
    }

    private func finishPushToTalkRecordingIfNeeded() async {
        guard isPushToTalkRecording else { return }
        isPushToTalkRecording = false
        isRecordingLocked = false
        shouldFinishPushToTalkAfterStart = false
        shouldLockPushToTalkAfterStart = false
        shouldCancelPushToTalkAfterStart = false

        guard let apiKey = normalizedAPIKey else {
            recorder.cancel()
            pttState = .ready
            errorMessage = nil
            return
        }

        let turnID = UUID()
        activeTurnID = turnID
        pttState = .transcribing
        let userPlaceholder = reserveTranscribingPlaceholder()
        Self.logger.info("ptt recording finishing")

        var recordedFile: WatchRecordedAudioFile?
        var assistantPlaceholderID: UUID?
        defer {
            recorder.deleteTemporaryFile(at: recordedFile?.url)
        }

        do {
            let file = try recorder.finish()
            recordedFile = file
            await prewarmRecorderIfPossible()

            guard file.durationMilliseconds >= Self.minimumRecordingMilliseconds else {
                cancelTranscribingPlaceholder(userPlaceholder)
                pttState = .ready
                errorMessage = nil
                Self.logger.info("ptt recording ignored reason=too_short durationMs=\(file.durationMilliseconds, privacy: .public)")
                return
            }

            let transcript = try await transcribe(file: file, apiKey: apiKey)
            guard activeTurnID == turnID else { return }

            updateTranscribingPlaceholder(id: userPlaceholder.id, transcript: transcript)
            pttState = .thinking
            assistantPlaceholderID = appendAssistantPlaceholder()
            Self.logger.info("ptt transcript appended characters=\(transcript.count, privacy: .public)")

            let assistantText = try await assistantResponse(apiKey: apiKey, messages: messages)
            guard activeTurnID == turnID else { return }

            updateAssistantPlaceholder(id: assistantPlaceholderID, response: assistantText)
            pttState = .ready
            errorMessage = nil
            Self.logger.info("ptt assistant response appended characters=\(assistantText.count, privacy: .public)")
        } catch {
            guard activeTurnID == turnID else { return }
            let failureDescription = error.localizedDescription
            failTranscribingPlaceholder(id: userPlaceholder.id, errorDescription: failureDescription)
            failAssistantPlaceholder(id: assistantPlaceholderID, errorDescription: failureDescription)
            pttState = .failed
            errorMessage = failureDescription
            recorder.cancel()
            await prewarmRecorderIfPossible()
            Self.logger.error("ptt turn failed error=\(failureDescription, privacy: .public)")
        }
    }

    private func cancelPushToTalkRecordingIfNeeded() async {
        activeTurnID = UUID()
        recorder.cancel()
        isPushToTalkHoldActive = false
        isRecordingStartPending = false
        shouldFinishPushToTalkAfterStart = false
        shouldLockPushToTalkAfterStart = false
        shouldCancelPushToTalkAfterStart = false
        isPushToTalkRecording = false
        isRecordingLocked = false
        pttState = .ready
        errorMessage = nil
        await prewarmRecorderIfPossible()
        Self.logger.info("ptt recording cancelled")
    }

    private func applyConfiguration(_ configuration: WatchConfiguration) {
        applySettings(configuration.settings)
    }

    private func applySettingsOnly(_ incomingSettings: ProviderSettings) {
        applySettings(incomingSettings)
    }

    private func applySettings(_ incomingSettings: ProviderSettings) {
        var updatedSettings = incomingSettings
        updatedSettings.hasAPIKey = hasAPIKey

        do {
            try configurationStore.saveSettings(updatedSettings)
            settings = updatedSettings
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncAPIKeyFromPhone(_ incomingAPIKey: String) -> Bool {
        guard !openAITestMode.isEnabled else {
            return true
        }

        let trimmed = incomingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return deleteAPIKeyFromWatch()
        }

        do {
            let previousAPIKey = normalizedAPIKey
            try configurationStore.saveAPIKey(trimmed)
            apiKey = trimmed
            setSettingsHasAPIKey(true)
            errorMessage = nil

            if previousAPIKey != trimmed {
                resetSessionForCredentialChange()
            }

            Task { @MainActor in
                await self.prewarmRecorderIfPossible()
            }

            return true
        } catch {
            errorMessage = error.localizedDescription
            return hasAPIKey
        }
    }

    private func deleteAPIKeyFromWatch() -> Bool {
        guard !openAITestMode.isEnabled else {
            return true
        }

        do {
            try configurationStore.deleteAPIKey()
            apiKey = nil
            setSettingsHasAPIKey(false)
            errorMessage = nil
            resetSessionForCredentialChange()
        } catch {
            errorMessage = error.localizedDescription
        }

        return hasAPIKey
    }

    private func setSettingsHasAPIKey(_ hasAPIKey: Bool) {
        var updatedSettings = settings
        updatedSettings.hasAPIKey = hasAPIKey
        settings = updatedSettings
        try? configurationStore.saveSettings(updatedSettings)
    }

    private func resetSessionForCredentialChange() {
        activeTurnID = UUID()
        activeRecordingStartID = nil
        recorder.cancel()
        recorder.cleanupTemporaryFiles()
        messages.removeAll()
        isPushToTalkHoldActive = false
        isRecordingStartPending = false
        shouldFinishPushToTalkAfterStart = false
        shouldLockPushToTalkAfterStart = false
        shouldCancelPushToTalkAfterStart = false
        isPushToTalkRecording = false
        isRecordingLocked = false
        pttState = .ready
    }

    private func prewarmRecorderIfPossible() async {
        guard hasAPIKey else { return }

        do {
            try await recorder.prewarm()
        } catch {
            Self.logger.info("ptt recorder prewarm skipped error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func transcribe(file: WatchRecordedAudioFile, apiKey: String) async throws -> String {
        if openAITestMode.isEnabled {
            await openAITestMode.simulateTranscriptionDelay()

            if remainingMockTranscriptionFailures > 0 {
                remainingMockTranscriptionFailures -= 1
                throw WatchOpenAITestModeError.transcriptionFailed
            }

            return openAITestMode.transcript(durationMilliseconds: file.durationMilliseconds)
        }

        return try await transcriptionClient.transcribe(audioURL: file.url, apiKey: apiKey)
    }

    private func assistantResponse(apiKey: String, messages: [ChatMessage]) async throws -> String {
        if openAITestMode.isEnabled {
            await openAITestMode.simulateResponseDelay()
            return openAITestMode.assistantText(turnNumber: messages.filter { $0.role == .user && !$0.isPlaceholder }.count)
        }

        return try await responsesClient.responseText(
            apiKey: apiKey,
            settings: settings,
            messages: messages
        )
    }

    private func reserveTranscribingPlaceholder() -> TranscribingPlaceholderReservation {
        if let reusableIndex = reusableTranscribingPlaceholderIndex() {
            let previousMessage = messages[reusableIndex]
            var updatedMessages = messages
            updatedMessages[reusableIndex].text = Self.transcriptionPlaceholderText
            updatedMessages[reusableIndex].createdAt = Date()
            updatedMessages[reusableIndex].isPlaceholder = true
            messages = updatedMessages
            return TranscribingPlaceholderReservation(
                id: previousMessage.id,
                previousMessage: previousMessage
            )
        }

        let message = ChatMessage(
            role: .user,
            text: Self.transcriptionPlaceholderText,
            isPlaceholder: true
        )
        messages.append(message)
        return TranscribingPlaceholderReservation(id: message.id, previousMessage: nil)
    }

    private func reusableTranscribingPlaceholderIndex() -> Int? {
        messages.indices.reversed().first { index in
            let message = messages[index]

            return message.role == .user &&
                message.isPlaceholder &&
                isTranscribingPlaceholderText(message.text)
        }
    }

    private func isTranscribingPlaceholderText(_ text: String) -> Bool {
        text == Self.transcriptionPlaceholderText ||
            text == Self.transcriptionFailedPlaceholderText ||
            text.hasPrefix("\(Self.transcriptionFailedPlaceholderText):")
    }

    private func cancelTranscribingPlaceholder(_ reservation: TranscribingPlaceholderReservation) {
        if let previousMessage = reservation.previousMessage {
            updateMessage(id: reservation.id) { message in
                message = previousMessage
            }
        } else {
            removeMessage(id: reservation.id)
        }
    }

    private func appendRecordingStartFailure(_ errorDescription: String) {
        let trimmedDescription = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmedDescription.isEmpty ? Self.recordingStartFailedText : trimmedDescription

        if let lastMessage = messages.last,
           lastMessage.role == .assistant,
           lastMessage.isPlaceholder,
           lastMessage.text == text
        {
            return
        }

        messages.append(ChatMessage(role: .assistant, text: text, isPlaceholder: true))
    }

    private func updateTranscribingPlaceholder(id: UUID, transcript: String) {
        updateMessage(id: id) { message in
            message.text = transcript
            message.isPlaceholder = false
        } fallback: {
            self.messages.append(ChatMessage(id: id, role: .user, text: transcript))
        }
    }

    private func failTranscribingPlaceholder(id: UUID, errorDescription: String) {
        updateMessage(id: id) { message in
            guard message.isPlaceholder else { return }

            message.text = failurePlaceholderText(
                prefix: Self.transcriptionFailedPlaceholderText,
                errorDescription: errorDescription
            )
            message.isPlaceholder = true
        }
    }

    private func appendAssistantPlaceholder() -> UUID {
        let message = ChatMessage(
            role: .assistant,
            text: Self.assistantPlaceholderText,
            isPlaceholder: true
        )
        messages.append(message)
        return message.id
    }

    private func updateAssistantPlaceholder(id: UUID?, response: String) {
        guard let id else {
            messages.append(ChatMessage(role: .assistant, text: response))
            return
        }

        updateMessage(id: id) { message in
            message.text = response
            message.isPlaceholder = false
        } fallback: {
            self.messages.append(ChatMessage(role: .assistant, text: response))
        }
    }

    private func failAssistantPlaceholder(id: UUID?, errorDescription: String) {
        guard let id else { return }

        updateMessage(id: id) { message in
            message.text = failurePlaceholderText(
                prefix: Self.assistantFailedPlaceholderText,
                errorDescription: errorDescription
            )
            message.isPlaceholder = true
        }
    }

    private func failurePlaceholderText(prefix: String, errorDescription: String) -> String {
        let trimmedDescription = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { return prefix }
        return "\(prefix): \(trimmedDescription)"
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    private func updateMessage(
        id: UUID,
        update: (inout ChatMessage) -> Void,
        fallback: (() -> Void)? = nil
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            fallback?()
            return
        }

        var updatedMessages = messages
        update(&updatedMessages[index])
        messages = updatedMessages
    }

    private var normalizedAPIKey: String? {
        if let apiKeyOverride = openAITestMode.apiKeyOverride {
            return apiKeyOverride
        }

        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct WatchOpenAITestMode: Equatable {
    var isEnabled: Bool
    var transcriptionFailuresBeforeSuccess: Int = 0

    var apiKeyOverride: String? {
        isEnabled ? "__wristassist_mock_openai__" : nil
    }

    static let disabled = WatchOpenAITestMode(isEnabled: false)

    static var current: WatchOpenAITestMode {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        let isLaunchArgumentEnabled = processInfo.arguments.contains("-WristAssistMockOpenAI")
        let environmentValue = processInfo.environment["WRISTASSIST_MOCK_OPENAI"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isEnvironmentEnabled = ["1", "true", "yes", "on"].contains(environmentValue ?? "")
        let transcriptionFailuresBeforeSuccess = max(
            0,
            integerArgument(named: "-WristAssistMockTranscriptionFailures", in: processInfo.arguments) ??
                integerEnvironmentValue(
                    named: "WRISTASSIST_MOCK_TRANSCRIPTION_FAILURES",
                    in: processInfo.environment
                ) ??
                0
        )

        return WatchOpenAITestMode(
            isEnabled: isLaunchArgumentEnabled || isEnvironmentEnabled || transcriptionFailuresBeforeSuccess > 0,
            transcriptionFailuresBeforeSuccess: transcriptionFailuresBeforeSuccess
        )
        #else
        return .disabled
        #endif
    }

    func simulateTranscriptionDelay() async {
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    func simulateResponseDelay() async {
        try? await Task.sleep(nanoseconds: 650_000_000)
    }

    func transcript(durationMilliseconds: Int) -> String {
        let seconds = Double(durationMilliseconds) / 1_000
        return String(format: "Mock transcript from %.1fs recording.", seconds)
    }

    func assistantText(turnNumber: Int) -> String {
        "Mock response \(turnNumber): PTT recording, transcription, and chat rendering completed without OpenAI."
    }

    private static func integerArgument(named name: String, in arguments: [String]) -> Int? {
        for (index, argument) in arguments.enumerated() {
            if argument == name,
               arguments.indices.contains(index + 1)
            {
                return Int(arguments[index + 1])
            }

            let prefix = "\(name)="
            if argument.hasPrefix(prefix) {
                return Int(argument.dropFirst(prefix.count))
            }
        }

        return nil
    }

    private static func integerEnvironmentValue(named name: String, in environment: [String: String]) -> Int? {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        return Int(value)
    }
}

enum WatchOpenAITestModeError: LocalizedError {
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed:
            return "Mock transcription failed."
        }
    }
}

struct WatchConfigurationStore {
    private let defaults = UserDefaults.standard
    private let settingsKey = "WatchProviderSettings"
    private let apiKeyStore = WatchAPIKeyStore()

    init() {}

    func loadConfiguration() -> WatchConfiguration {
        let settings = loadSettings()
        return WatchConfiguration(settings: settings, hasAPIKey: apiKeyStore.hasAPIKey())
    }

    func saveSettings(_ settings: ProviderSettings) throws {
        var normalizedSettings = settings
        normalizedSettings.hasAPIKey = apiKeyStore.hasAPIKey()
        let data = try JSONEncoder().encode(normalizedSettings)
        defaults.set(data, forKey: settingsKey)
    }

    func saveAPIKey(_ apiKey: String) throws {
        try apiKeyStore.saveAPIKey(apiKey)
    }

    func loadAPIKey() throws -> String? {
        try apiKeyStore.loadAPIKey()
    }

    func deleteAPIKey() throws {
        try apiKeyStore.deleteAPIKey()
    }

    private func loadSettings() -> ProviderSettings {
        guard let data = defaults.data(forKey: settingsKey),
              var settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else {
            var defaults = ProviderSettings.default
            defaults.hasAPIKey = apiKeyStore.hasAPIKey()
            return defaults
        }

        settings.hasAPIKey = apiKeyStore.hasAPIKey()
        return settings
    }
}

private struct WatchAPIKeyStore: APIKeyStore {
    private let service = "com.kwojt.WristAssist.OpenAI"
    private let legacyServices = ["com.kwojt.WristAssist.watch.openai"]
    private let account = "openai-api-key"

    func saveAPIKey(_ apiKey: String) throws {
        try upsertAPIKey(apiKey, service: service)
        try deleteAPIKey(services: legacyServices)
    }

    func loadAPIKey() throws -> String? {
        if let apiKey = try loadAPIKey(from: service) {
            return apiKey
        }

        for legacyService in legacyServices {
            if let apiKey = try loadAPIKey(from: legacyService) {
                try saveAPIKey(apiKey)
                return apiKey
            }
        }

        return nil
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(services: allServices)
    }

    func hasAPIKey() -> Bool {
        guard let apiKey = try? loadAPIKey() else {
            return false
        }

        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var allServices: [String] {
        [service] + legacyServices
    }

    private func loadAPIKey(from service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw WatchAPIKeyStoreError.unhandledStatus(status)
        }

        guard let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            throw WatchAPIKeyStoreError.invalidData
        }

        return apiKey
    }

    private func upsertAPIKey(_ apiKey: String, service: String) throws {
        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw WatchAPIKeyStoreError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WatchAPIKeyStoreError.unhandledStatus(addStatus)
        }
    }

    private func deleteAPIKey(services: [String]) throws {
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw WatchAPIKeyStoreError.unhandledStatus(status)
            }
        }
    }
}

private enum WatchAPIKeyStoreError: LocalizedError, Equatable {
    case invalidData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The saved API key could not be decoded."
        case .unhandledStatus(let status):
            return "Keychain failed with status \(status)."
        }
    }
}
