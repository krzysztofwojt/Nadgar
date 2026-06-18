import Foundation
import os
import Security
import WristAssistShared

@MainActor
final class WatchVoiceViewModel: ObservableObject {
    private static let localBargeInGuardMilliseconds = 350
    private static let localBargeInMinimumSpeechMilliseconds = 180
    private static let localBargeInMinimumInputRMS: Float = 0.014
    private static let localBargeInOutputRelativeThreshold: Float = 0.25
    private static let minimumPushToTalkCommitMilliseconds = 100
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
        category: "WatchVoiceViewModel"
    )

    @Published private(set) var state: RealtimeConnectionState
    @Published private(set) var settings: ProviderSettings
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedConversationMode: RealtimeConversationMode
    @Published private(set) var isPushToTalkRecording = false

    var hasAPIKey: Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isIdle: Bool {
        state == .idle
    }

    var isRunning: Bool {
        switch state {
        case .idle, .failed:
            return false
        case .requestingToken, .connecting, .listening, .speaking, .stopping:
            return true
        }
    }

    var canChangeConversationMode: Bool {
        !isRunning
    }

    var isPushToTalkSession: Bool {
        activeConversationMode == .pushToTalk
    }

    private let connectivity: WatchConnectivityClient
    private let configurationStore: WatchConfigurationStore
    private let conversationModeStore: WatchConversationModeStore
    private var realtimeClient: RealtimeWebSocketClient?
    private var audioPipeline: WatchAudioPipeline?
    private var apiKey: String?
    private var activeConversationMode: RealtimeConversationMode?
    private var isAssistantResponseActive = false
    private var hasPendingAssistantPlayback = false
    private var activeAssistantOutput: ActiveAssistantOutput?
    private var interruptedAssistantOutputs = Set<ActiveAssistantOutput>()
    private var localBargeInSpeechMilliseconds = 0
    private var suppressedInputChunkCount = 0
    private var isPushToTalkHoldActive = false
    private var isPushToTalkStartPending = false
    private var shouldFinishPushToTalkAfterStart = false
    private var pushToTalkForwardedChunkCount = 0
    private var pushToTalkForwardedMilliseconds = 0

    init() {
        let configurationStore = WatchConfigurationStore()
        let localConfiguration = configurationStore.loadConfiguration()
        let conversationModeStore = WatchConversationModeStore()

        self.configurationStore = configurationStore
        self.conversationModeStore = conversationModeStore
        self.connectivity = WatchConnectivityClient()
        self.state = .idle
        self.settings = localConfiguration.settings
        self.apiKey = localConfiguration.apiKey
        self.selectedConversationMode = conversationModeStore.loadMode()

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
        connectivity.activate()
    }

    func requestInitialSettings() async {
        do {
            applyConfiguration(try await connectivity.requestConfiguration())
        } catch {
            errorMessage = nil
        }
    }

    func startOrStop() {
        Task {
            if isRunning {
                await stop()
            } else {
                await start()
            }
        }
    }

    func selectConversationMode(_ mode: RealtimeConversationMode) {
        guard canChangeConversationMode else {
            Self.logger.info("conversation mode change ignored state=\(self.state.rawValue, privacy: .public)")
            return
        }

        selectedConversationMode = mode
        conversationModeStore.saveMode(mode)
        Self.logger.info("conversation mode selected mode=\(mode.rawValue, privacy: .public)")
    }

    func beginPushToTalkRecording() {
        isPushToTalkHoldActive = true
        Task {
            await beginPushToTalkRecordingIfNeeded()
        }
    }

    func endPushToTalkRecording() {
        isPushToTalkHoldActive = false
        if isPushToTalkStartPending {
            shouldFinishPushToTalkAfterStart = true
        }
        Task {
            await finishPushToTalkRecordingIfNeeded()
        }
    }

    private func start() async {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .idle
            errorMessage = nil
            Self.logger.info("start ignored reason=missing_api_key")
            return
        }

        do {
            errorMessage = nil
            let mode = selectedConversationMode
            activeConversationMode = mode
            state = .connecting
            Self.logger.info("conversation start state=connecting model=\(self.settings.model, privacy: .public) voice=\(self.settings.voice, privacy: .public) mode=\(mode.rawValue, privacy: .public)")
            try? await connectivity.reportState(state)

            let client = RealtimeWebSocketClient()
            let pipeline = WatchAudioPipeline()
            resetAssistantOutputState()

            try await client.connect(
                token: apiKey,
                settings: settings,
                mode: mode,
                eventHandler: { [weak self] event in
                    Task { @MainActor in
                        self?.handle(event)
                    }
                },
                audioHandler: { [weak self] audioDelta, data in
                    Task { @MainActor in
                        self?.handleOutputAudio(audioDelta, data: data, pipeline: pipeline)
                    }
                }
            )

            try await pipeline.start(
                onInputAudio: { [weak self] chunk in
                    Task { @MainActor in
                        await self?.handleInputAudio(chunk, client: client)
                    }
                },
                onOutputPlaybackDrained: { [weak self] in
                    Task { @MainActor in
                        self?.handleOutputPlaybackDrained()
                    }
                }
            )

            realtimeClient = client
            audioPipeline = pipeline
            state = .listening
            Self.logger.info("conversation ready state=listening")
            try? await connectivity.reportState(state)
        } catch {
            await stop()
            state = .failed
            errorMessage = error.localizedDescription
            Self.logger.error("conversation failed error=\(error.localizedDescription, privacy: .public)")
            try? await connectivity.reportState(state)
        }
    }

    private func stop() async {
        Self.logger.info("conversation stop requested state=\(self.state.rawValue, privacy: .public)")
        state = .stopping
        resetAssistantOutputState()
        resetPushToTalkState()
        audioPipeline?.stop()
        audioPipeline = nil
        await realtimeClient?.stop()
        realtimeClient = nil
        activeConversationMode = nil
        state = .idle
        Self.logger.info("conversation stopped state=idle")
        try? await connectivity.reportState(state)
    }

    private func applyConfiguration(_ configuration: WatchConfiguration) {
        let shouldStop = configuration.apiKey == nil && isRunning

        do {
            try configurationStore.saveConfiguration(configuration)
            apiKey = configuration.apiKey
            settings = configuration.settings
            errorMessage = nil

            if shouldStop {
                Task {
                    await stop()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applySettingsOnly(_ incomingSettings: ProviderSettings) {
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

    private func handle(_ event: RealtimeServerEvent) {
        let stateBefore = state
        logEvent(event, state: stateBefore)

        switch event {
        case .sessionCreated:
            state = .listening
        case .inputSpeechStarted:
            if isAssistantResponseActive || hasPendingAssistantPlayback {
                Self.logger.info("decision=clear_server_speech_started_during_assistant activeResponse=\(self.isAssistantResponseActive, privacy: .public) pendingPlayback=\(self.hasPendingAssistantPlayback, privacy: .public)")
                clearLikelyEchoInput()
                state = .speaking
            } else {
                state = .listening
            }
        case .inputSpeechStopped:
            break
        case .responseCreated:
            isAssistantResponseActive = true
            state = .speaking
        case .responseDone:
            isAssistantResponseActive = false
            finishAssistantOutputIfReady()
        case .audioDone:
            finishAssistantOutputIfReady()
        case .audioDelta:
            isAssistantResponseActive = true
            hasPendingAssistantPlayback = true
            state = .speaking
        case .error(let message):
            guard !isRecoverableRealtimeError(message) else {
                Self.logger.info("server recoverable_error ignored message=\(message, privacy: .public)")
                return
            }
            state = .failed
            errorMessage = message
        case .unknown:
            break
        }

        if state != stateBefore {
            Self.logger.info("state transition \(stateBefore.rawValue, privacy: .public) -> \(self.state.rawValue, privacy: .public) after=\(self.eventName(event), privacy: .public)")
        }
    }

    private func handleInputAudio(
        _ chunk: WatchInputAudioChunk,
        client: RealtimeWebSocketClient
    ) async {
        if activeConversationMode == .pushToTalk {
            await handlePushToTalkInputAudio(chunk, client: client)
            return
        }

        if shouldForwardInputAudioToRealtime {
            resetLocalInputRoutingState()
            try? await client.sendInputAudio(base64PCM16: chunk.base64PCM16)
            return
        }

        suppressedInputChunkCount += 1
        if suppressedInputChunkCount == 1 || suppressedInputChunkCount.isMultiple(of: 25) {
            Self.logger.debug("suppress input during assistant count=\(self.suppressedInputChunkCount, privacy: .public) inputRMS=\(chunk.inputRMS, privacy: .public) outputRMS=\(chunk.outputRMS, privacy: .public) outputPlayedMs=\(chunk.outputPlayedMilliseconds, privacy: .public)")
        }

        guard shouldTriggerLocalBargeIn(with: chunk) else {
            return
        }

        Self.logger.info("decision=local_barge_in inputRMS=\(chunk.inputRMS, privacy: .public) outputRMS=\(chunk.outputRMS, privacy: .public) speechMs=\(self.localBargeInSpeechMilliseconds, privacy: .public) outputPlayedMs=\(chunk.outputPlayedMilliseconds, privacy: .public)")
        await handleBargeIn(client: client, firstInputChunk: chunk)
    }

    private func handlePushToTalkInputAudio(
        _ chunk: WatchInputAudioChunk,
        client: RealtimeWebSocketClient
    ) async {
        guard isPushToTalkRecording else {
            suppressedInputChunkCount += 1
            if suppressedInputChunkCount == 1 || suppressedInputChunkCount.isMultiple(of: 25) {
                Self.logger.debug("suppress input ptt_idle count=\(self.suppressedInputChunkCount, privacy: .public) inputRMS=\(chunk.inputRMS, privacy: .public) outputRMS=\(chunk.outputRMS, privacy: .public) outputPlayedMs=\(chunk.outputPlayedMilliseconds, privacy: .public)")
            }
            return
        }

        resetLocalInputRoutingState()
        pushToTalkForwardedChunkCount += 1
        pushToTalkForwardedMilliseconds += max(chunk.durationMilliseconds, 0)
        try? await client.sendInputAudio(base64PCM16: chunk.base64PCM16)
    }

    private func handleOutputAudio(
        _ audioDelta: RealtimeOutputAudioDelta,
        data: Data,
        pipeline: WatchAudioPipeline
    ) {
        guard !isInterruptedOutput(audioDelta.metadata) else {
            return
        }

        updateActiveAssistantOutput(with: audioDelta, pipeline: pipeline)
        isAssistantResponseActive = true
        hasPendingAssistantPlayback = true
        state = .speaking
        Self.logger.debug("enqueue output audio responseID=\(audioDelta.metadata.responseID ?? "nil", privacy: .public) itemID=\(audioDelta.metadata.itemID ?? "nil", privacy: .public) bytes=\(data.count, privacy: .public)")
        pipeline.enqueueOutputAudio(data)
    }

    private func handleOutputPlaybackDrained() {
        Self.logger.info("output playback drained activeResponse=\(self.isAssistantResponseActive, privacy: .public)")
        hasPendingAssistantPlayback = false
        finishAssistantOutputIfReady()
    }

    private func handleBargeIn(
        client: RealtimeWebSocketClient,
        firstInputChunk: WatchInputAudioChunk
    ) async {
        await interruptAssistantOutput(client: client, reason: "barge_in")
        try? await client.sendInputAudio(base64PCM16: firstInputChunk.base64PCM16)
    }

    private func interruptAssistantOutput(
        client: RealtimeWebSocketClient,
        reason: String,
        clearInputBuffer: Bool = true
    ) async {
        let interruptedOutput = activeAssistantOutput
        let shouldCancelResponse = isAssistantResponseActive
        let audioEndMilliseconds = audioPipeline?.stopOutputPlaybackAndClearQueue() ?? 0

        Self.logger.info("assistant interrupt reason=\(reason, privacy: .public) responseID=\(interruptedOutput?.responseID ?? "nil", privacy: .public) itemID=\(interruptedOutput?.itemID ?? "nil", privacy: .public) shouldCancel=\(shouldCancelResponse, privacy: .public) audioEndMs=\(audioEndMilliseconds, privacy: .public)")

        if let interruptedOutput {
            interruptedAssistantOutputs.insert(interruptedOutput)
        }

        isAssistantResponseActive = false
        hasPendingAssistantPlayback = false
        activeAssistantOutput = nil
        resetLocalInputRoutingState()
        state = .listening

        if clearInputBuffer {
            try? await client.clearInputAudio()
        }

        if shouldCancelResponse {
            try? await client.cancelResponse(responseID: interruptedOutput?.responseID)
        }

        if let interruptedOutput {
            try? await client.truncateConversationItem(
                itemID: interruptedOutput.itemID,
                contentIndex: interruptedOutput.contentIndex,
                audioEndMilliseconds: audioEndMilliseconds
            )
        }
    }

    private func beginPushToTalkRecordingIfNeeded() async {
        guard activeConversationMode == .pushToTalk,
              isPushToTalkHoldActive,
              !isPushToTalkRecording,
              !isPushToTalkStartPending,
              state != .idle,
              state != .failed,
              state != .stopping,
              let realtimeClient
        else {
            return
        }

        isPushToTalkStartPending = true
        shouldFinishPushToTalkAfterStart = false
        pushToTalkForwardedChunkCount = 0
        pushToTalkForwardedMilliseconds = 0
        isPushToTalkRecording = true
        state = .listening
        resetLocalInputRoutingState()

        Self.logger.info("ptt recording begin requested state=\(self.state.rawValue, privacy: .public) activeResponse=\(self.isAssistantResponseActive, privacy: .public) pendingPlayback=\(self.hasPendingAssistantPlayback, privacy: .public)")

        if isAssistantResponseActive || hasPendingAssistantPlayback {
            await interruptAssistantOutput(
                client: realtimeClient,
                reason: "ptt_begin",
                clearInputBuffer: false
            )
        } else {
            resetLocalInputRoutingState()
        }

        isPushToTalkStartPending = false
        Self.logger.info("ptt recording started")

        if shouldFinishPushToTalkAfterStart || !isPushToTalkHoldActive {
            shouldFinishPushToTalkAfterStart = false
            await finishPushToTalkRecordingIfNeeded()
        }
    }

    private func finishPushToTalkRecordingIfNeeded() async {
        guard activeConversationMode == .pushToTalk,
              isPushToTalkRecording,
              let realtimeClient
        else {
            return
        }

        guard !isPushToTalkStartPending else {
            shouldFinishPushToTalkAfterStart = true
            return
        }

        isPushToTalkRecording = false
        shouldFinishPushToTalkAfterStart = false
        let chunkCount = pushToTalkForwardedChunkCount
        let durationMilliseconds = pushToTalkForwardedMilliseconds
        pushToTalkForwardedChunkCount = 0
        pushToTalkForwardedMilliseconds = 0

        guard chunkCount > 0 else {
            Self.logger.info("ptt recording discarded reason=no_audio")
            try? await realtimeClient.clearInputAudio()
            return
        }

        guard durationMilliseconds >= Self.minimumPushToTalkCommitMilliseconds else {
            Self.logger.info("ptt recording discarded reason=too_short chunks=\(chunkCount, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) minDurationMs=\(Self.minimumPushToTalkCommitMilliseconds, privacy: .public)")
            try? await realtimeClient.clearInputAudio()
            return
        }

        do {
            Self.logger.info("ptt recording commit chunks=\(chunkCount, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public)")
            try await realtimeClient.commitInputAudio()
            guard isCurrentRealtimeClient(realtimeClient) else {
                Self.logger.info("ptt commit completion ignored reason=stale_client step=commit")
                return
            }

            try await realtimeClient.createResponse()
            guard isCurrentRealtimeClient(realtimeClient) else {
                Self.logger.info("ptt commit completion ignored reason=stale_client step=create_response")
                return
            }

            state = .speaking
        } catch {
            guard isCurrentRealtimeClient(realtimeClient) else {
                Self.logger.info("ptt commit error ignored reason=stale_client error=\(error.localizedDescription, privacy: .public)")
                return
            }

            state = .failed
            errorMessage = error.localizedDescription
            Self.logger.error("ptt commit failed error=\(error.localizedDescription, privacy: .public)")
            try? await connectivity.reportState(state)
        }
    }

    private func isCurrentRealtimeClient(_ client: RealtimeWebSocketClient) -> Bool {
        guard state != .stopping else {
            return false
        }

        guard let currentClient = realtimeClient else {
            return false
        }

        return client === currentClient
    }

    private func clearLikelyEchoInput() {
        guard let realtimeClient else { return }
        Self.logger.info("clear likely echo input")
        Task {
            try? await realtimeClient.clearInputAudio()
        }
    }

    private func updateActiveAssistantOutput(
        with audioDelta: RealtimeOutputAudioDelta,
        pipeline: WatchAudioPipeline
    ) {
        guard let itemID = audioDelta.metadata.itemID else {
            return
        }

        let nextOutput = ActiveAssistantOutput(
            itemID: itemID,
            responseID: audioDelta.metadata.responseID,
            contentIndex: audioDelta.metadata.contentIndex
        )

        if nextOutput != activeAssistantOutput {
            Self.logger.info("active output changed itemID=\(nextOutput.itemID, privacy: .public) responseID=\(nextOutput.responseID ?? "nil", privacy: .public) contentIndex=\(nextOutput.contentIndex, privacy: .public)")
            activeAssistantOutput = nextOutput
            pipeline.resetOutputPlaybackTracking()
        }
    }

    private func finishAssistantOutputIfReady() {
        if isAssistantResponseActive || hasPendingAssistantPlayback {
            state = .speaking
            Self.logger.info("finish output deferred activeResponse=\(self.isAssistantResponseActive, privacy: .public) pendingPlayback=\(self.hasPendingAssistantPlayback, privacy: .public)")
        } else if state != .failed && state != .idle && state != .stopping {
            state = .listening
            Self.logger.info("finish output complete state=listening")
            activeAssistantOutput = nil
        }
    }

    private func resetAssistantOutputState() {
        isAssistantResponseActive = false
        hasPendingAssistantPlayback = false
        activeAssistantOutput = nil
        interruptedAssistantOutputs.removeAll()
        resetLocalInputRoutingState()
    }

    private func resetPushToTalkState() {
        isPushToTalkHoldActive = false
        isPushToTalkStartPending = false
        shouldFinishPushToTalkAfterStart = false
        isPushToTalkRecording = false
        pushToTalkForwardedChunkCount = 0
        pushToTalkForwardedMilliseconds = 0
    }

    private func isInterruptedOutput(_ metadata: RealtimeOutputAudioMetadata) -> Bool {
        guard let itemID = metadata.itemID else {
            return false
        }

        return interruptedAssistantOutputs.contains(
            ActiveAssistantOutput(
                itemID: itemID,
                responseID: metadata.responseID,
                contentIndex: metadata.contentIndex
            )
        )
    }

    private func isRecoverableRealtimeError(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("cancellation failed")
            && normalizedMessage.contains("no active response found")
    }

    private var shouldForwardInputAudioToRealtime: Bool {
        !isAssistantResponseActive && !hasPendingAssistantPlayback
    }

    private func shouldTriggerLocalBargeIn(with chunk: WatchInputAudioChunk) -> Bool {
        guard isAssistantResponseActive || hasPendingAssistantPlayback else {
            resetLocalInputRoutingState()
            return false
        }

        if chunk.isOutputPlaybackActive && chunk.outputPlayedMilliseconds < Self.localBargeInGuardMilliseconds {
            localBargeInSpeechMilliseconds = 0
            return false
        }

        let threshold = max(
            Self.localBargeInMinimumInputRMS,
            chunk.outputRMS * Self.localBargeInOutputRelativeThreshold
        )

        guard chunk.inputRMS >= threshold else {
            localBargeInSpeechMilliseconds = 0
            return false
        }

        localBargeInSpeechMilliseconds += max(chunk.durationMilliseconds, 0)
        return localBargeInSpeechMilliseconds >= Self.localBargeInMinimumSpeechMilliseconds
    }

    private func resetLocalInputRoutingState() {
        localBargeInSpeechMilliseconds = 0
        suppressedInputChunkCount = 0
    }

    private func logEvent(_ event: RealtimeServerEvent, state: RealtimeConnectionState) {
        if case .audioDelta = event {
            return
        }

        if case .unknown(let type) = event,
           type == "response.output_audio_transcript.delta" {
            return
        }

        Self.logger.info("handle event=\(self.eventName(event), privacy: .public) state=\(state.rawValue, privacy: .public) activeResponse=\(self.isAssistantResponseActive, privacy: .public) pendingPlayback=\(self.hasPendingAssistantPlayback, privacy: .public)")
    }

    private func eventName(_ event: RealtimeServerEvent) -> String {
        switch event {
        case .sessionCreated:
            return "session.created"
        case .inputSpeechStarted:
            return "input_audio_buffer.speech_started"
        case .inputSpeechStopped:
            return "input_audio_buffer.speech_stopped"
        case .responseCreated:
            return "response.created"
        case .responseDone:
            return "response.done"
        case .audioDelta:
            return "response.output_audio.delta"
        case .audioDone:
            return "response.output_audio.done"
        case .error:
            return "error"
        case .unknown(let type):
            return type
        }
    }
}

private struct ActiveAssistantOutput: Hashable {
    var itemID: String
    var responseID: String?
    var contentIndex: Int
}

private struct WatchConfigurationStore {
    private let defaults = UserDefaults.standard
    private let settingsKey = "WatchProviderSettings"
    private let apiKeyStore = WatchAPIKeyStore()

    func loadConfiguration() -> WatchConfiguration {
        let settings = loadSettings()
        let apiKey = try? apiKeyStore.loadAPIKey()
        return WatchConfiguration(settings: settings, apiKey: apiKey)
    }

    func saveConfiguration(_ configuration: WatchConfiguration) throws {
        if let apiKey = configuration.apiKey {
            try apiKeyStore.saveAPIKey(apiKey)
        } else {
            try apiKeyStore.deleteAPIKey()
        }

        try saveSettings(configuration.settings)
    }

    func saveSettings(_ settings: ProviderSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: settingsKey)
    }

    private func loadSettings() -> ProviderSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else {
            return .default
        }

        return settings
    }
}

private struct WatchConversationModeStore {
    private let defaults = UserDefaults.standard
    private let modeKey = "WatchConversationMode"

    func loadMode() -> RealtimeConversationMode {
        guard let rawValue = defaults.string(forKey: modeKey),
              let mode = RealtimeConversationMode(rawValue: rawValue)
        else {
            return .auto
        }

        return mode
    }

    func saveMode(_ mode: RealtimeConversationMode) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}

private struct WatchAPIKeyStore {
    private let service = "com.kwojt.WristAssist.watch.openai"
    private let account = "openai-api-key"

    func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        try deleteAPIKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WatchAPIKeyStoreError.unhandledStatus(status)
        }
    }

    func loadAPIKey() throws -> String? {
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

    func deleteAPIKey() throws {
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
