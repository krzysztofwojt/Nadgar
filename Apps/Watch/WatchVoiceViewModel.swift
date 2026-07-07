import Foundation
import os
import Security
import NadgarShared

@MainActor
final class WatchVoiceViewModel: ObservableObject {
    private static let minimumRecordingMilliseconds = 250
    private static let transcriptionPlaceholderText = "Transcribing..."
    private static let transcriptionFailedPlaceholderText = "Transcription failed"
    private static let assistantPlaceholderText = "Writing..."
    private static let assistantFailedPlaceholderText = "Response failed"
    private static let recordingStartFailedPrefix = "Recording could not be started"
    private static let recordingStartFailedText = "\(recordingStartFailedPrefix)."
    private static let providerConfigurationRequiredText = "Open Nadgar on your iPhone and configure a provider."
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.nadgar.Nadgar.watchkitapp",
        category: "WatchVoiceViewModel"
    )

    @Published private(set) var pttState: WatchPTTState
    @Published private(set) var settings: ProviderSettings
    @Published private(set) var errorMessage: String?
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var timelineItems: [ChatTimelineItem]
    @Published private(set) var isPushToTalkRecording = false
    @Published private(set) var isRecordingLocked = false

    var hasAPIKey: Bool {
        makeTurnConfiguration() != nil
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
    private let hermesResponsesClient: HermesResponsesClient
    private let speechClient: OpenAISpeechClient
    private let speechAudioPipeline: WatchAudioPipeline
    private let assistantProvider: any AssistantConversationProvider
    private let conversationStore: WatchConversationStore
    private let timelineFormatter: ChatTimelineFormatter
    private let openAITestMode: WatchOpenAITestMode
    private var conversation: WatchConversationRecord
    private var conversationRevision = 0
    private var apiKeys: [String: String]
    private var speechPlaybackTask: Task<Void, Never>?
    private var speechPlaybackID: UUID?
    private var speechFragmentContinuation: AsyncStream<String>.Continuation?
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
        var previousIndex: Int?
    }

    private struct ConversationMutationGuard {
        var contextEpochID: UUID
        var revision: Int
    }

    private struct WatchTurnConfiguration {
        var transcriptionProfileID: String
        var transcriptionModel: String
        var transcriptionAPIKey: String
        var responseProfileID: String
        var responseProfile: ProviderProfile
        var responseModel: String
        var responseAPIKey: String
        var speechProfileID: String?
        var speechModel: String?
        var speechAPIKey: String?
        var responseSettings: ProviderSettings
        var responseContextProviderID: String
    }

    init(
        connectivity: WatchConnectivityClient = WatchConnectivityClient(),
        configurationStore: WatchConfigurationStore = WatchConfigurationStore(),
        recorder: WatchPTTRecorder? = nil,
        transcriptionClient: OpenAITranscriptionClient = OpenAITranscriptionClient(),
        responsesClient: OpenAIResponsesClient = OpenAIResponsesClient(),
        hermesResponsesClient: HermesResponsesClient = HermesResponsesClient(),
        speechClient: OpenAISpeechClient = OpenAISpeechClient(),
        speechAudioPipeline: WatchAudioPipeline = WatchAudioPipeline(),
        assistantProvider: (any AssistantConversationProvider)? = nil,
        conversationStore: WatchConversationStore? = nil,
        openAITestMode: WatchOpenAITestMode = .current
    ) {
        let localConfiguration = configurationStore.loadConfiguration()
        let resolvedConversationStore = conversationStore ?? Self.defaultConversationStore()
        let loadedConversation: WatchConversationRecord
        let conversationLoadError: Error?
        do {
            loadedConversation = try resolvedConversationStore.load()
            conversationLoadError = nil
        } catch {
            loadedConversation = WatchConversationRecord()
            conversationLoadError = error
        }
        let timelineFormatter = ChatTimelineFormatter()
        let mockInitialMessages = openAITestMode.initialMessages()
        let initialConversation = openAITestMode.isEnabled
            ? WatchConversationRecord(messages: mockInitialMessages)
            : loadedConversation
        let displayMessages = initialConversation.displayMessages

        self.connectivity = connectivity
        self.configurationStore = configurationStore
        self.recorder = recorder ?? WatchPTTRecorder()
        self.transcriptionClient = transcriptionClient
        self.responsesClient = responsesClient
        self.hermesResponsesClient = hermesResponsesClient
        self.speechClient = speechClient
        self.speechAudioPipeline = speechAudioPipeline
        self.assistantProvider = assistantProvider ?? OpenAIResponsesConversationProvider(client: responsesClient)
        self.conversationStore = resolvedConversationStore
        self.timelineFormatter = timelineFormatter
        self.openAITestMode = openAITestMode
        self.remainingMockTranscriptionFailures = openAITestMode.transcriptionFailuresBeforeSuccess
        self.conversation = initialConversation
        self.pttState = .ready
        self.settings = localConfiguration.settings
        self.apiKeys = Self.loadAPIKeys(
            for: localConfiguration.settings.providerProfiles,
            configurationStore: configurationStore,
            openAITestMode: openAITestMode
        )
        self.messages = displayMessages
        self.timelineItems = timelineFormatter.items(
            for: displayMessages,
            hasEarlierMessages: initialConversation.messages.count > displayMessages.count,
            hasSummarizedEarlierContext: initialConversation.hasSummarizedEarlierContext,
            lastContextResetAt: initialConversation.lastContextResetAt,
            events: initialConversation.events
        )
        self.errorMessage = conversationLoadError?.localizedDescription

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
        connectivity.onSyncAPIKey = { [weak self] profileID, apiKey in
            self?.syncAPIKeyFromPhone(apiKey, profileID: profileID) ?? false
        }
        connectivity.onDeleteAPIKey = { [weak self] profileID in
            self?.deleteAPIKeyFromWatch(profileID: profileID) ?? false
        }
        connectivity.onClearConversationHistory = { [weak self] in
            self?.clearConversationHistoryFromPhone() ?? false
        }
        connectivity.hasLocalAPIKey = { [weak self] profileID in
            self?.hasAPIKey(profileID: profileID) ?? false
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
        stopAssistantSpeechPlayback()
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

        if pttState == .ready || pttState == .failed {
            stopAssistantSpeechPlayback()
        }

        guard canBeginRecording else {
            isPushToTalkHoldActive = false
            if !hasAPIKey {
                showProviderConfigurationRequired()
            }
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
                showRecordingStartFailure(error.localizedDescription)
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
        stopAssistantSpeechPlayback()
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

        guard let turnConfiguration = makeTurnConfiguration() else {
            recorder.cancel()
            pttState = .failed
            errorMessage = Self.providerConfigurationRequiredText
            showProviderConfigurationRequired()
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

            let transcript = try await transcribe(file: file, configuration: turnConfiguration)
            guard activeTurnID == turnID else { return }

            let previousActiveProviderID = conversation.activeProviderID
            conversation.activeProviderID = turnConfiguration.responseContextProviderID
            if previousActiveProviderID != conversation.activeProviderID {
                conversation.markActiveProviderContextRequiresLocalHistoryBootstrap()
                saveConversation()
            }
            let providerContextBeforeLocalTurn = conversation.activeProviderContext
            let userMessage = updateTranscribingPlaceholder(id: userPlaceholder.id, transcript: transcript)
            persistMessage(userMessage, marksProviderContextDirty: true)
            pttState = .thinking
            assistantPlaceholderID = appendAssistantPlaceholder()
            Self.logger.info("ptt transcript appended characters=\(transcript.count, privacy: .public)")

            let assistantRequest = makeAssistantTurnRequest(
                userMessage: userMessage,
                providerContext: providerContextBeforeLocalTurn,
                settings: turnConfiguration.responseSettings
            )
            let assistantMutationGuard = currentConversationMutationGuard()
            let assistantResult = try await assistantResponse(configuration: turnConfiguration, request: assistantRequest)
            guard activeTurnID == turnID,
                  isCurrentConversation(assistantMutationGuard)
            else { return }

            let assistantMessage = updateAssistantPlaceholder(id: assistantPlaceholderID, response: assistantResult.response)
            persistAssistantMessage(assistantMessage, providerContext: assistantResult.providerContext)
            startAssistantSpeechPlaybackIfNeeded(
                apiKey: turnConfiguration.speechAPIKey,
                settings: turnConfiguration.responseSettings
            )
            enqueueAssistantSpeechText(assistantResult.response.text)
            finishAssistantSpeechPlaybackInput()
            pttState = .ready
            errorMessage = nil
            await updateSummaryIfNeeded(configuration: turnConfiguration)
            Self.logger.info("ptt assistant response appended characters=\(assistantResult.response.text.count, privacy: .public) citations=\(assistantResult.response.citations.count, privacy: .public)")
        } catch {
            guard activeTurnID == turnID else { return }
            let failureDescription = error.localizedDescription
            stopAssistantSpeechPlayback()
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
        stopAssistantSpeechPlayback()
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
        guard incomingSettings.configurationVersion >= settings.configurationVersion else {
            Self.logger.info("settings ignored because configurationVersion is stale incoming=\(incomingSettings.configurationVersion, privacy: .public) current=\(self.settings.configurationVersion, privacy: .public)")
            return
        }

        var updatedSettings = incomingSettings
        applyLocalKeyStatuses(to: &updatedSettings)
        let shouldStopSpeechPlayback = settings.isAutoReadEnabled != updatedSettings.isAutoReadEnabled ||
            settings.shouldIgnoreSilentModeForAutoRead != updatedSettings.shouldIgnoreSilentModeForAutoRead ||
            settings.voice != updatedSettings.voice ||
            settings.ttsModel != updatedSettings.ttsModel ||
            settings.selectedSpeech != updatedSettings.selectedSpeech ||
            settings.speechVoicesByProfileID != updatedSettings.speechVoicesByProfileID
        let oldResponseContextID = responseContextProviderID(in: settings)
        let newResponseContextID = responseContextProviderID(in: updatedSettings)

        do {
            try configurationStore.saveSettings(updatedSettings)
            settings = updatedSettings
            Self.logger.info(
                "settings applied autoRead=\(updatedSettings.isAutoReadEnabled, privacy: .public) ignoresSilentMode=\(updatedSettings.shouldIgnoreSilentModeForAutoRead, privacy: .public) voice=\(updatedSettings.voice, privacy: .public) ttsModel=\(updatedSettings.ttsModel, privacy: .public)"
            )
            if shouldStopSpeechPlayback {
                stopAssistantSpeechPlayback()
            }
            if oldResponseContextID != newResponseContextID {
                activeTurnID = UUID()
                conversation.activeProviderID = newResponseContextID ?? AssistantProviderIDs.openAI
                conversation.markActiveProviderContextRequiresLocalHistoryBootstrap()
                saveConversation()
                refreshDisplayMessagesFromConversation()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncAPIKeyFromPhone(_ incomingAPIKey: String, profileID: String) -> Bool {
        guard !openAITestMode.isEnabled else {
            return true
        }

        let trimmed = incomingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return deleteAPIKeyFromWatch(profileID: profileID)
        }

        do {
            let previousAPIKey = normalizedAPIKey(for: profileID)
            try configurationStore.saveAPIKey(trimmed, for: profileID)
            apiKeys[profileID] = trimmed
            setSettingsHasAPIKey(true, for: profileID)
            errorMessage = nil

            if settings.selectedResponse?.profileID == profileID, previousAPIKey != trimmed {
                resetSessionForCredentialChange()
            }

            Task { @MainActor in
                await self.prewarmRecorderIfPossible()
            }

            return true
        } catch {
            errorMessage = error.localizedDescription
            return hasAPIKey(profileID: profileID)
        }
    }

    private func deleteAPIKeyFromWatch(profileID: String) -> Bool {
        guard !openAITestMode.isEnabled else {
            return true
        }

        do {
            try configurationStore.deleteAPIKey(for: profileID)
            apiKeys.removeValue(forKey: profileID)
            setSettingsHasAPIKey(false, for: profileID)
            errorMessage = nil
            if settings.selectedResponse?.profileID == profileID {
                resetSessionForCredentialChange()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        return hasAPIKey(profileID: profileID)
    }

    private func setSettingsHasAPIKey(_ hasAPIKey: Bool, for profileID: String) {
        var updatedSettings = settings
        updatedSettings.setAPIKeyStatus(hasAPIKey, for: profileID)
        settings = updatedSettings
        try? configurationStore.saveSettings(updatedSettings)
    }

    private func resetSessionForCredentialChange() {
        activeTurnID = UUID()
        activeRecordingStartID = nil
        stopAssistantSpeechPlayback()
        recorder.cancel()
        recorder.cleanupTemporaryFiles()
        conversation.rotateModelContext()
        saveConversation()
        refreshDisplayMessagesFromConversation()
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

    private func transcribe(
        file: WatchRecordedAudioFile,
        configuration: WatchTurnConfiguration
    ) async throws -> String {
        if openAITestMode.isEnabled {
            await openAITestMode.simulateTranscriptionDelay()

            if remainingMockTranscriptionFailures > 0 {
                remainingMockTranscriptionFailures -= 1
                throw WatchOpenAITestModeError.transcriptionFailed
            }

            return openAITestMode.transcript(durationMilliseconds: file.durationMilliseconds)
        }

        return try await transcriptionClient.transcribe(
            audioURL: file.url,
            apiKey: configuration.transcriptionAPIKey,
            model: configuration.transcriptionModel
        )
    }

    func openCitationOnPhone(_ citation: ChatCitation) async -> String? {
        guard let url = URL(string: citation.url) else {
            return "Source URL is invalid."
        }

        do {
            try await connectivity.openURLOnPhone(url)
            errorMessage = nil
            return nil
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            return message
        }
    }

    private func assistantResponse(
        configuration: WatchTurnConfiguration,
        request: AssistantTurnRequest
    ) async throws -> AssistantTurnResult {
        if openAITestMode.isEnabled {
            await openAITestMode.simulateResponseDelay()
            let turnNumber = conversation.messages.filter { $0.role == .user && !$0.isPlaceholder }.count
            let remoteTurnID = "mock-response-\(turnNumber)"
            return AssistantTurnResult(
                response: openAITestMode.assistantResponse(turnNumber: turnNumber),
                providerContext: ProviderContextState(
                    providerID: request.providerContext?.providerID ?? assistantProvider.providerID,
                    lastRemoteTurnID: remoteTurnID
                )
            )
        }

        switch configuration.responseProfile.type {
        case .openAI:
            var scopedRequest = request
            var providerContext = scopedRequest.providerContext ??
                ProviderContextState(providerID: configuration.responseContextProviderID)
            providerContext.providerID = configuration.responseContextProviderID
            scopedRequest.providerContext = providerContext
            return try await assistantProvider.respond(apiKey: configuration.responseAPIKey, request: scopedRequest)
        case .hermes:
            let provider = HermesResponsesConversationProvider(
                profile: configuration.responseProfile,
                providerID: configuration.responseContextProviderID,
                client: hermesResponsesClient
            )
            return try await provider.respond(apiKey: configuration.responseAPIKey, request: request)
        case .custom:
            throw AssistantProviderError.notConfigured
        }
    }

    private func assistantResponse(apiKey: String, messages: [ChatMessage]) async throws -> OpenAIAssistantResponse {
        if openAITestMode.isEnabled {
            await openAITestMode.simulateResponseDelay()
            return openAITestMode.assistantResponse(
                turnNumber: messages.filter { $0.role == .user && !$0.isPlaceholder }.count
            )
        }

        return try await responsesClient.response(
            apiKey: apiKey,
            settings: settings,
            messages: messages
        )
    }

    private func assistantResponseStream(
        apiKey: String,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<OpenAIResponsesStreamUpdate, Error> {
        if openAITestMode.isEnabled {
            return openAITestMode.assistantResponseStream(
                turnNumber: messages.filter { $0.role == .user && !$0.isPlaceholder }.count
            )
        }

        return responsesClient.streamedResponse(
            apiKey: apiKey,
            settings: settings,
            messages: messages
        )
    }

    private func streamAssistantResponse(
        apiKey: String,
        messages: [ChatMessage],
        placeholderID: UUID?,
        turnID: UUID
    ) async throws -> OpenAIAssistantResponse {
        var finalResponse: OpenAIAssistantResponse?
        var streamedText = ""
        var speechChunker = AssistantSpeechChunker()
        startAssistantSpeechPlaybackIfNeeded(apiKey: apiKey, settings: settings)
        defer {
            flushAssistantSpeechChunks(from: &speechChunker)
            finishAssistantSpeechPlaybackInput()
        }

        for try await update in assistantResponseStream(apiKey: apiKey, messages: messages) {
            guard activeTurnID == turnID else {
                throw CancellationError()
            }

            switch update {
            case .textDelta(let delta):
                streamedText += delta
                appendAssistantTextDelta(id: placeholderID, delta: delta)
                enqueueAssistantSpeechChunks(speechChunker.append(delta))
            case .completed(let response):
                let completedText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !completedText.isEmpty {
                    if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        enqueueAssistantSpeechChunks(speechChunker.append(response.text))
                    }
                    _ = updateAssistantPlaceholder(id: placeholderID, response: response)
                    finalResponse = response
                } else if !streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Self.logger.info("ptt stream completed without final text; keeping streamed text")
                }
            }
        }

        guard let finalResponse else {
            let trimmedText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                Self.logger.error("ptt stream ended without text or completion; falling back to full response")
                let fallbackResponse = try await assistantResponse(apiKey: apiKey, messages: messages)
                _ = updateAssistantPlaceholder(id: placeholderID, response: fallbackResponse)
                enqueueAssistantSpeechText(fallbackResponse.text)
                Self.logger.info("ptt full response fallback succeeded characters=\(fallbackResponse.text.count, privacy: .public) citations=\(fallbackResponse.citations.count, privacy: .public)")
                return fallbackResponse
            }

            let response = OpenAIAssistantResponse(text: trimmedText)
            _ = updateAssistantPlaceholder(id: placeholderID, response: response)
            Self.logger.info("ptt stream ended without completion; using streamed text characters=\(trimmedText.count, privacy: .public)")
            return response
        }

        return finalResponse
    }

    private func startAssistantSpeechPlaybackIfNeeded(
        apiKey: String?,
        settings: ProviderSettings
    ) {
        stopAssistantSpeechPlayback()
        guard settings.isAutoReadEnabled else {
            Self.logger.info("ptt speech playback skipped reason=auto_read_disabled")
            return
        }
        guard !openAITestMode.isEnabled else {
            Self.logger.info("ptt speech playback skipped reason=openai_test_mode")
            return
        }
        guard let apiKey else {
            Self.logger.info("ptt speech playback skipped reason=speech_provider_not_configured")
            return
        }

        recorder.invalidatePrewarmForAudioSessionChange()

        var streamContinuation: AsyncStream<String>.Continuation?
        let stream = AsyncStream<String> { continuation in
            streamContinuation = continuation
        }
        speechFragmentContinuation = streamContinuation

        let settingsSnapshot = settings
        Self.logger.info(
            "ptt speech playback starting voice=\(settingsSnapshot.voice, privacy: .public) model=\(settingsSnapshot.ttsModel, privacy: .public) ignoresSilentMode=\(settingsSnapshot.shouldIgnoreSilentModeForAutoRead, privacy: .public)"
        )
        let playbackID = UUID()
        speechPlaybackID = playbackID
        speechPlaybackTask = Task { [weak self, speechClient, speechAudioPipeline] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishAssistantSpeechPlaybackTask(id: playbackID)
                }
            }

            do {
                try speechAudioPipeline.startPlayback(
                    honorsSilentMode: !settingsSnapshot.shouldIgnoreSilentModeForAutoRead
                )

                for await fragment in stream {
                    try Task.checkCancellation()
                    let spokenText = AssistantSpeechTextSanitizer.spokenText(from: fragment)
                    guard !spokenText.isEmpty else {
                        Self.logger.info("ptt speech fragment skipped reason=empty_after_sanitizing")
                        continue
                    }

                    Self.logger.info("ptt speech fragment queued characters=\(spokenText.count, privacy: .public)")
                    for try await pcmData in speechClient.speechAudioStream(
                        apiKey: apiKey,
                        settings: settingsSnapshot,
                        input: spokenText
                    ) {
                        try Task.checkCancellation()
                        speechAudioPipeline.enqueueOutputAudio(pcmData)
                    }
                }
                try Task.checkCancellation()
                await speechAudioPipeline.waitForOutputPlaybackToDrain()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("ptt speech playback failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func enqueueAssistantSpeechChunks(_ chunks: [String]) {
        guard speechFragmentContinuation != nil else { return }

        for chunk in chunks where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speechFragmentContinuation?.yield(chunk)
        }
    }

    private func enqueueAssistantSpeechText(_ text: String) {
        guard speechFragmentContinuation != nil else { return }

        var chunker = AssistantSpeechChunker()
        enqueueAssistantSpeechChunks(chunker.append(text))
        enqueueAssistantSpeechChunks(chunker.flush())
    }

    private func flushAssistantSpeechChunks(from chunker: inout AssistantSpeechChunker) {
        enqueueAssistantSpeechChunks(chunker.flush())
    }

    private func finishAssistantSpeechPlaybackInput() {
        speechFragmentContinuation?.finish()
        speechFragmentContinuation = nil
    }

    private func stopAssistantSpeechPlayback() {
        let hadSpeechPlayback = speechPlaybackTask != nil || speechFragmentContinuation != nil
        speechFragmentContinuation?.finish()
        speechFragmentContinuation = nil
        speechPlaybackTask?.cancel()
        speechPlaybackID = nil
        speechPlaybackTask = nil
        if hadSpeechPlayback {
            speechAudioPipeline.stopPlaybackAndClearQueue()
        }
    }

    private func clearAssistantSpeechPlaybackTask(id: UUID) {
        guard speechPlaybackID == id else { return }

        speechPlaybackID = nil
        speechPlaybackTask = nil
        speechFragmentContinuation = nil
    }

    private func finishAssistantSpeechPlaybackTask(id: UUID) {
        guard speechPlaybackID == id else { return }

        speechAudioPipeline.stopPlaybackAndClearQueue()
        clearAssistantSpeechPlaybackTask(id: id)
    }

    private func reserveTranscribingPlaceholder() -> TranscribingPlaceholderReservation {
        if let reusableIndex = reusableTranscribingPlaceholderIndex() {
            let previousMessage = messages[reusableIndex]
            var updatedMessages = messages
            var reusedMessage = updatedMessages.remove(at: reusableIndex)
            reusedMessage.text = Self.transcriptionPlaceholderText
            reusedMessage.createdAt = Date()
            reusedMessage.isPlaceholder = true
            updatedMessages.append(reusedMessage)
            messages = updatedMessages
            refreshTimelineItems()
            return TranscribingPlaceholderReservation(
                id: previousMessage.id,
                previousMessage: previousMessage,
                previousIndex: reusableIndex
            )
        }

        let message = ChatMessage(
            role: .user,
            text: Self.transcriptionPlaceholderText,
            isPlaceholder: true
        )
        messages.append(message)
        refreshTimelineItems()
        return TranscribingPlaceholderReservation(id: message.id, previousMessage: nil, previousIndex: nil)
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
            text.hasPrefix("\(Self.transcriptionFailedPlaceholderText):") ||
            text == Self.recordingStartFailedText ||
            text.hasPrefix("\(Self.recordingStartFailedPrefix):") ||
            text == Self.providerConfigurationRequiredText
    }

    private func cancelTranscribingPlaceholder(_ reservation: TranscribingPlaceholderReservation) {
        if let previousMessage = reservation.previousMessage {
            var updatedMessages = messages
            updatedMessages.removeAll { $0.id == reservation.id }
            let insertionIndex = min(reservation.previousIndex ?? updatedMessages.count, updatedMessages.count)
            updatedMessages.insert(previousMessage, at: insertionIndex)
            messages = updatedMessages
            refreshTimelineItems()
        } else {
            removeMessage(id: reservation.id)
        }
    }

    private func showRecordingStartFailure(_ errorDescription: String) {
        let reservation = reserveTranscribingPlaceholder()
        let failureText = recordingStartFailureText(errorDescription)

        updateMessage(id: reservation.id) { message in
            message.role = .user
            message.text = failureText
            message.citations = []
            message.isPlaceholder = true
        } fallback: {
            self.messages.append(
                ChatMessage(
                    id: reservation.id,
                    role: .user,
                    text: failureText,
                    isPlaceholder: true
                )
            )
        }
    }

    private func recordingStartFailureText(_ errorDescription: String) -> String {
        let trimmedDescription = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty,
              trimmedDescription != Self.recordingStartFailedPrefix,
              trimmedDescription != Self.recordingStartFailedText
        else {
            return Self.recordingStartFailedText
        }

        return "\(Self.recordingStartFailedPrefix): \(trimmedDescription)"
    }

    private func updateTranscribingPlaceholder(id: UUID, transcript: String) -> ChatMessage {
        let createdAt = messages.first(where: { $0.id == id })?.createdAt ?? Date()
        let message = ChatMessage(id: id, role: .user, text: transcript, createdAt: createdAt)
        upsertDisplayMessage(message)
        return message
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
        refreshTimelineItems()
    }

    private func appendAssistantPlaceholder() -> UUID {
        let message = ChatMessage(
            role: .assistant,
            text: Self.assistantPlaceholderText,
            isPlaceholder: true
        )
        messages.append(message)
        refreshTimelineItems()
        return message.id
    }

    private func updateAssistantPlaceholder(id: UUID?, response: OpenAIAssistantResponse) -> ChatMessage {
        guard let id else {
            let message = ChatMessage(role: .assistant, text: response.text, citations: response.citations)
            upsertDisplayMessage(message)
            return message
        }

        let createdAt = messages.first(where: { $0.id == id })?.createdAt ?? Date()
        let message = ChatMessage(
            id: id,
            role: .assistant,
            text: response.text,
            createdAt: createdAt,
            citations: response.citations
        )
        upsertDisplayMessage(message)
        return message
    }

    private func appendAssistantTextDelta(id: UUID?, delta: String) {
        guard !delta.isEmpty else { return }

        guard let id else {
            messages.append(ChatMessage(role: .assistant, text: delta))
            return
        }

        updateMessage(id: id) { message in
            if message.isPlaceholder {
                message.text = ""
                message.citations = []
                message.isPlaceholder = false
            }
            message.text += delta
        } fallback: {
            self.messages.append(ChatMessage(id: id, role: .assistant, text: delta))
        }
    }

    private func failAssistantPlaceholder(id: UUID?, errorDescription: String) {
        guard let id else { return }

        updateMessage(id: id) { message in
            let failureText = failurePlaceholderText(
                prefix: Self.assistantFailedPlaceholderText,
                errorDescription: errorDescription
            )

            if message.role == .assistant,
               !message.isPlaceholder,
               !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message.text += "\n\n\(failureText)"
            } else {
                message.text = failureText
                message.isPlaceholder = true
            }
        }
        refreshTimelineItems()
    }

    private func failurePlaceholderText(prefix: String, errorDescription: String) -> String {
        let trimmedDescription = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { return prefix }
        return "\(prefix): \(trimmedDescription)"
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        refreshTimelineItems()
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
        refreshTimelineItems()
    }

    private func upsertDisplayMessage(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }

        messages.sort { $0.createdAt < $1.createdAt }
        applyDisplayWindowLimit()
        refreshTimelineItems()
    }

    private func applyDisplayWindowLimit() {
        guard messages.count > StandalonePTTDefaults.visibleMessagesLimit else { return }
        messages = Array(messages.suffix(StandalonePTTDefaults.visibleMessagesLimit))
    }

    private func makeAssistantTurnRequest(
        userMessage: ChatMessage,
        providerContext: ProviderContextState? = nil,
        settings: ProviderSettings
    ) -> AssistantTurnRequest {
        AssistantTurnRequest(
            conversationKey: conversation.conversationKey,
            contextEpochID: conversation.contextEpochID,
            providerContext: providerContext ?? conversation.activeProviderContext,
            userMessage: userMessage,
            recentMessages: conversation.currentEpochRawRecoveryMessages,
            humanSummary: conversation.humanSummaryForCurrentEpoch,
            summaryThroughMessageId: conversation.summaryThroughMessageIdForCurrentEpoch,
            settings: settings
        )
    }

    private func currentConversationMutationGuard() -> ConversationMutationGuard {
        ConversationMutationGuard(
            contextEpochID: conversation.contextEpochID,
            revision: conversationRevision
        )
    }

    private func isCurrentConversation(_ guardValue: ConversationMutationGuard) -> Bool {
        conversation.contextEpochID == guardValue.contextEpochID &&
            conversationRevision == guardValue.revision
    }

    private func persistMessage(_ message: ChatMessage, marksProviderContextDirty: Bool = false) {
        conversation.appendMessage(message)
        if marksProviderContextDirty {
            conversation.markActiveProviderContextRequiresLocalHistoryBootstrap()
        }
        saveConversation()
        refreshTimelineItems()
    }

    private func persistAssistantMessage(_ message: ChatMessage, providerContext: ProviderContextState?) {
        conversation.appendMessage(message)
        conversation.setProviderContext(providerContext)
        saveConversation()
        refreshTimelineItems()
    }

    private func updateSummaryIfNeeded(configuration: WatchTurnConfiguration) async {
        let currentEpochMessages = conversation.currentEpochMessages
        guard currentEpochMessages.count > StandalonePTTDefaults.rawRecoveryMessagesLimit else { return }

        let overflowCount = currentEpochMessages.count - StandalonePTTDefaults.rawRecoveryMessagesLimit
        let messagesToSummarize = Array(currentEpochMessages.prefix(overflowCount))
        guard let throughMessageId = messagesToSummarize.last?.id else { return }
        let summaryRequest = ConversationSummaryRequest(
            conversationKey: conversation.conversationKey,
            contextEpochID: conversation.contextEpochID,
            providerContext: conversation.activeProviderContext,
            currentSummary: conversation.humanSummaryForCurrentEpoch,
            messages: messagesToSummarize,
            throughMessageID: throughMessageId,
            settings: configuration.responseSettings
        )
        let mutationGuard = currentConversationMutationGuard()

        do {
            let result: ConversationSummaryResult?
            switch configuration.responseProfile.type {
            case .openAI:
                result = try await assistantProvider.summarizeIfNeeded(
                    apiKey: configuration.responseAPIKey,
                    request: summaryRequest
                )
            case .hermes:
                let provider = HermesResponsesConversationProvider(
                    profile: configuration.responseProfile,
                    providerID: configuration.responseContextProviderID,
                    client: hermesResponsesClient
                )
                result = try await provider.summarizeIfNeeded(
                    apiKey: configuration.responseAPIKey,
                    request: summaryRequest
                )
            case .custom:
                result = nil
            }
            guard let result else { return }
            guard isCurrentConversation(mutationGuard) else { return }

            let hasTransientPlaceholders = messages.contains { $0.isPlaceholder }
            conversation.markSummarized(summary: result.summary, through: result.throughMessageID)
            conversation.setProviderContext(result.providerContext)
            saveConversation()
            if hasTransientPlaceholders {
                refreshTimelineItems()
            } else {
                refreshDisplayMessagesFromConversation()
            }
            Self.logger.info("conversation summary updated summarizedMessages=\(messagesToSummarize.count, privacy: .public)")
        } catch {
            Self.logger.error("conversation summary update skipped error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveConversation() {
        conversationRevision += 1
        do {
            try conversationStore.save(conversation)
        } catch {
            errorMessage = error.localizedDescription
            Self.logger.error("conversation save failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshDisplayMessagesFromConversation() {
        messages = conversation.displayMessages
        refreshTimelineItems()
    }

    private func refreshTimelineItems() {
        let visiblePersistentIDs = Set(messages.filter { !$0.isPlaceholder }.map(\.id))
        let hasEarlierMessages = conversation.messages.contains { !visiblePersistentIDs.contains($0.id) }
        timelineItems = timelineFormatter.items(
            for: messages,
            hasEarlierMessages: hasEarlierMessages,
            hasSummarizedEarlierContext: conversation.hasSummarizedEarlierContext,
            lastContextResetAt: conversation.lastContextResetAt,
            events: conversation.events
        )
    }

    private func clearConversationHistoryFromPhone() -> Bool {
        activeTurnID = UUID()
        activeRecordingStartID = nil
        stopAssistantSpeechPlayback()
        recorder.cancel()
        isPushToTalkHoldActive = false
        isRecordingStartPending = false
        shouldFinishPushToTalkAfterStart = false
        shouldLockPushToTalkAfterStart = false
        shouldCancelPushToTalkAfterStart = false
        isPushToTalkRecording = false
        isRecordingLocked = false
        pttState = .ready
        conversation.clearHistory()
        conversationRevision += 1
        do {
            try conversationStore.clear()
            messages.removeAll()
            refreshTimelineItems()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private static func defaultConversationStore() -> WatchConversationStore {
        if let store = try? WatchConversationStore.defaultStore() {
            return store
        }

        return WatchConversationStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("watch-conversation.json")
        )
    }

    private func showProviderConfigurationRequired() {
        let reservation = reserveTranscribingPlaceholder()
        updateMessage(id: reservation.id) { message in
            message.role = .user
            message.text = Self.providerConfigurationRequiredText
            message.citations = []
            message.isPlaceholder = true
        } fallback: {
            self.messages.append(
                ChatMessage(
                    id: reservation.id,
                    role: .user,
                    text: Self.providerConfigurationRequiredText,
                    isPlaceholder: true
                )
            )
        }
        refreshTimelineItems()
    }

    private func makeTurnConfiguration() -> WatchTurnConfiguration? {
        guard let transcriptionSelection = settings.selectedTranscription,
              let transcriptionProfile = settings.profile(id: transcriptionSelection.profileID),
              transcriptionProfile.type == .openAI,
              let responseSelection = settings.selectedResponse,
              let responseProfile = settings.profile(id: responseSelection.profileID),
              responseProfile.type.supportsResponses,
              responseProfile.type != .hermes || responseProfile.hasValidHermesBaseURL,
              let transcriptionAPIKey = normalizedAPIKey(for: transcriptionProfile.id),
              let responseAPIKey = normalizedAPIKey(for: responseProfile.id)
        else {
            return nil
        }

        var responseSettings = settings
        applyLocalKeyStatuses(to: &responseSettings)
        responseSettings.model = responseSelection.model
        responseSettings.transcriptionModel = transcriptionSelection.model
        responseSettings.normalizeSelectionsAfterProfileChange()
        let speechSelection = responseSettings.selectedSpeech
        responseSettings.ttsModel = speechSelection?.model ?? ProviderSettings.defaultTTSModel
        if let speechProfileID = speechSelection?.profileID,
           let speechVoice = responseSettings.speechVoice(for: speechProfileID) {
            responseSettings.voice = speechVoice
        }
        let speechProfile = speechSelection.flatMap { responseSettings.profile(id: $0.profileID) }
        let speechAPIKey: String?
        if responseSettings.isAutoReadEnabled,
           let speechProfile,
           ProviderSettings.speechCapabilities(for: speechProfile) != nil {
            speechAPIKey = normalizedAPIKey(for: speechProfile.id)
        } else {
            speechAPIKey = nil
        }

        return WatchTurnConfiguration(
            transcriptionProfileID: transcriptionProfile.id,
            transcriptionModel: transcriptionSelection.model,
            transcriptionAPIKey: transcriptionAPIKey,
            responseProfileID: responseProfile.id,
            responseProfile: responseProfile,
            responseModel: responseSelection.model,
            responseAPIKey: responseAPIKey,
            speechProfileID: speechProfile?.id,
            speechModel: speechSelection?.model,
            speechAPIKey: speechAPIKey,
            responseSettings: responseSettings,
            responseContextProviderID: ProviderSettings.contextProviderID(for: responseSelection, profile: responseProfile)
        )
    }

    private func responseContextProviderID(in settings: ProviderSettings) -> String? {
        guard let selectedResponse = settings.selectedResponse else { return nil }
        return ProviderSettings.contextProviderID(
            for: selectedResponse,
            profile: settings.profile(id: selectedResponse.profileID)
        )
    }

    private func hasAPIKey(profileID: String) -> Bool {
        normalizedAPIKey(for: profileID) != nil
    }

    private func normalizedAPIKey(for profileID: String) -> String? {
        if let apiKeyOverride = openAITestMode.apiKeyOverride {
            return apiKeyOverride
        }

        let trimmed = apiKeys[profileID]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func applyLocalKeyStatuses(to settings: inout ProviderSettings) {
        for profile in settings.providerProfiles {
            settings.setAPIKeyStatus(hasAPIKey(profileID: profile.id), for: profile.id)
        }
    }

    private static func loadAPIKeys(
        for profiles: [ProviderProfile],
        configurationStore: WatchConfigurationStore,
        openAITestMode: WatchOpenAITestMode
    ) -> [String: String] {
        guard !openAITestMode.isEnabled else {
            return Dictionary(
                uniqueKeysWithValues: profiles
                    .filter { $0.type.supportsAPIKey }
                    .map { ($0.id, openAITestMode.apiKeyOverride ?? "__nadgar_mock_openai__") }
            )
        }

        var apiKeys: [String: String] = [:]
        for profile in profiles where profile.type.supportsAPIKey {
            guard let apiKey = try? configurationStore.loadAPIKey(for: profile.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !apiKey.isEmpty
            else {
                continue
            }
            apiKeys[profile.id] = apiKey
        }
        return apiKeys
    }
}

struct WatchOpenAITestMode: Equatable {
    var isEnabled: Bool
    var transcriptionFailuresBeforeSuccess: Int = 0
    var seedsCitationChat: Bool = false
    var seedsOverflowChat: Bool = false

    var apiKeyOverride: String? {
        isEnabled ? "__nadgar_mock_openai__" : nil
    }

    static let disabled = WatchOpenAITestMode(isEnabled: false)

    static var current: WatchOpenAITestMode {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        let isLaunchArgumentEnabled = processInfo.arguments.contains("-NadgarMockOpenAI") ||
            processInfo.arguments.contains("-WristAssistMockOpenAI")
        let isSeedChatLaunchArgumentEnabled = processInfo.arguments.contains("-NadgarMockCitationChat") ||
            processInfo.arguments.contains("-WristAssistMockCitationChat")
        let isOverflowChatLaunchArgumentEnabled = processInfo.arguments.contains("-NadgarMockOverflowChat") ||
            processInfo.arguments.contains("-WristAssistMockOverflowChat")
        let environmentValue = (processInfo.environment["NADGAR_MOCK_OPENAI"] ??
            processInfo.environment["WRISTASSIST_MOCK_OPENAI"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let seedChatEnvironmentValue = (processInfo.environment["NADGAR_MOCK_CITATION_CHAT"] ??
            processInfo.environment["WRISTASSIST_MOCK_CITATION_CHAT"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let overflowChatEnvironmentValue = (processInfo.environment["NADGAR_MOCK_OVERFLOW_CHAT"] ??
            processInfo.environment["WRISTASSIST_MOCK_OVERFLOW_CHAT"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isEnvironmentEnabled = ["1", "true", "yes", "on"].contains(environmentValue ?? "")
        let transcriptionFailuresBeforeSuccess = max(
            0,
            integerArgument(named: "-NadgarMockTranscriptionFailures", in: processInfo.arguments) ??
                integerEnvironmentValue(
                    named: "NADGAR_MOCK_TRANSCRIPTION_FAILURES",
                    in: processInfo.environment
                ) ??
                0
        )
        let isSeedChatEnvironmentEnabled = ["1", "true", "yes", "on"].contains(seedChatEnvironmentValue ?? "")
        let isOverflowChatEnvironmentEnabled = ["1", "true", "yes", "on"].contains(overflowChatEnvironmentValue ?? "")
        let seedsCitationChat = isSeedChatLaunchArgumentEnabled || isSeedChatEnvironmentEnabled
        let seedsOverflowChat = isOverflowChatLaunchArgumentEnabled || isOverflowChatEnvironmentEnabled

        return WatchOpenAITestMode(
            isEnabled: isLaunchArgumentEnabled ||
                isEnvironmentEnabled ||
                transcriptionFailuresBeforeSuccess > 0 ||
                seedsCitationChat ||
                seedsOverflowChat,
            transcriptionFailuresBeforeSuccess: transcriptionFailuresBeforeSuccess,
            seedsCitationChat: seedsCitationChat,
            seedsOverflowChat: seedsOverflowChat
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

    func assistantResponse(turnNumber: Int) -> OpenAIAssistantResponse {
        OpenAIMockResponses.richMarkdownCitationResponse(turnNumber: turnNumber)
    }

    func assistantResponseStream(turnNumber: Int) -> AsyncThrowingStream<OpenAIResponsesStreamUpdate, Error> {
        let response = assistantResponse(turnNumber: turnNumber)

        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in response.text.mockStreamChunks(maxLength: 42) {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(nanoseconds: 85_000_000)
                    continuation.yield(.textDelta(chunk))
                }

                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 120_000_000)
                continuation.yield(.completed(response))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func initialMessages() -> [ChatMessage] {
        if seedsOverflowChat {
            return overflowMessages()
        }

        guard seedsCitationChat else { return [] }

        let response = assistantResponse(turnNumber: 1)
        return [
            ChatMessage(
                role: .user,
                text: "Show the markdown and citation rendering fixture."
            ),
            ChatMessage(
                role: .assistant,
                text: response.text,
                citations: response.citations
            )
        ]
    }

    private func overflowMessages() -> [ChatMessage] {
        let baseDate = Date(timeIntervalSinceReferenceDate: 804_000_000)
        return (0..<60).map { index in
            let role: ChatMessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let text = role == .user
                ? "Seeded user message \(index + 1)"
                : "Seeded assistant message \(index + 1)"
            return ChatMessage(
                role: role,
                text: text,
                createdAt: baseDate.addingTimeInterval(TimeInterval(index * 60))
            )
        }
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

private extension String {
    func mockStreamChunks(maxLength: Int) -> [String] {
        guard count > maxLength else { return [self] }

        var chunks: [String] = []
        var start = startIndex

        while start < endIndex {
            let end = index(start, offsetBy: maxLength, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[start..<end]))
            start = end
        }

        return chunks
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
        return WatchConfiguration(settings: settings)
    }

    func saveSettings(_ settings: ProviderSettings) throws {
        let normalizedSettings = settingsWithKeyStatuses(settings)
        let data = try JSONEncoder().encode(normalizedSettings)
        defaults.set(data, forKey: settingsKey)
    }

    func saveAPIKey(_ apiKey: String, for profileID: String) throws {
        try apiKeyStore.saveAPIKey(apiKey, for: profileID)
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        try apiKeyStore.loadAPIKey(for: profileID)
    }

    func deleteAPIKey(for profileID: String) throws {
        try apiKeyStore.deleteAPIKey(for: profileID)
    }

    private func loadSettings() -> ProviderSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else {
            return settingsWithKeyStatuses(.default)
        }

        return settingsWithKeyStatuses(settings)
    }

    private func settingsWithKeyStatuses(_ settings: ProviderSettings) -> ProviderSettings {
        var normalizedSettings = settings
        for profile in normalizedSettings.providerProfiles {
            normalizedSettings.setAPIKeyStatus(apiKeyStore.hasAPIKey(for: profile.id), for: profile.id)
        }
        normalizedSettings.normalizeSelectionsAfterProfileChange()
        return normalizedSettings
    }
}

private struct WatchAPIKeyStore: APIKeyStore {
    private let profileScopedService = "app.nadgar.Nadgar.ProviderAPIKeys"
    private let legacyOpenAIService = "app.nadgar.Nadgar.OpenAI"
    private let legacyOpenAIAccount = "openai-api-key"

    func saveAPIKey(_ apiKey: String, for profileID: String) throws {
        let account = normalizedProfileID(profileID)
        try upsertAPIKey(apiKey, service: profileScopedService, account: account)

        if account == ProviderProfile.legacyOpenAIProfileID {
            try deleteAPIKey(ignoringMissing: true, service: legacyOpenAIService, account: legacyOpenAIAccount)
        }
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        let account = normalizedProfileID(profileID)
        if let apiKey = try loadAPIKey(service: profileScopedService, account: account) {
            return apiKey
        }

        guard account == ProviderProfile.legacyOpenAIProfileID,
              let legacyAPIKey = try loadAPIKey(service: legacyOpenAIService, account: legacyOpenAIAccount)
        else {
            return nil
        }

        try upsertAPIKey(legacyAPIKey, service: profileScopedService, account: account)
        if try loadAPIKey(service: profileScopedService, account: account) == legacyAPIKey {
            try deleteAPIKey(ignoringMissing: true, service: legacyOpenAIService, account: legacyOpenAIAccount)
        }
        return legacyAPIKey
    }

    func deleteAPIKey(for profileID: String) throws {
        let account = normalizedProfileID(profileID)
        try deleteAPIKey(ignoringMissing: false, service: profileScopedService, account: account)

        if account == ProviderProfile.legacyOpenAIProfileID {
            try deleteAPIKey(ignoringMissing: true, service: legacyOpenAIService, account: legacyOpenAIAccount)
        }
    }

    func hasAPIKey(for profileID: String) -> Bool {
        guard let apiKey = try? loadAPIKey(for: profileID) else {
            return false
        }

        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedProfileID(_ profileID: String) -> String {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProviderProfile.legacyOpenAIProfileID : trimmed
    }

    private func loadAPIKey(service: String, account: String) throws -> String? {
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

    private func upsertAPIKey(_ apiKey: String, service: String, account: String) throws {
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

    private func deleteAPIKey(ignoringMissing: Bool, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound && ignoringMissing {
            return
        }

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WatchAPIKeyStoreError.unhandledStatus(status)
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
            return "Keychain is unavailable: \(Self.statusDescription(status)) (status \(status))."
        }
    }

    private static func statusDescription(_ status: OSStatus) -> String {
        if status == errSecMissingEntitlement {
            return "this build is missing the Keychain entitlement."
        }

        if let message = SecCopyErrorMessageString(status, nil) {
            return message as String
        }

        return "Security framework returned an unknown error."
    }
}
