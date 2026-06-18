import Foundation
import os
import WristAssistShared

actor RealtimeWebSocketClient {
    private static let startupTimeoutNanoseconds: UInt64 = 8_000_000_000
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
        category: "RealtimeWebSocket"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (RealtimeServerEvent) -> Void)?
    private var audioHandler: (@Sendable (RealtimeOutputAudioDelta, Data) -> Void)?
    private var didTimeoutDuringStartup = false
    private var sentInputAudioChunkCount = 0
    private var receivedAudioDeltaCount = 0

    func connect(
        token: String,
        settings: ProviderSettings,
        mode: RealtimeConversationMode,
        eventHandler: @escaping @Sendable (RealtimeServerEvent) -> Void,
        audioHandler: @escaping @Sendable (RealtimeOutputAudioDelta, Data) -> Void
    ) async throws {
        self.eventHandler = eventHandler
        self.audioHandler = audioHandler

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [
            URLQueryItem(name: "model", value: settings.model)
        ]

        guard let url = components.url else {
            throw RealtimeWebSocketError.invalidURL
        }

        Self.logger.info("connect start model=\(settings.model, privacy: .public) voice=\(settings.voice, privacy: .public) mode=\(mode.rawValue, privacy: .public)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        do {
            try await send(.sessionUpdate(RealtimeSession(settings: settings, mode: mode)))
            try await waitForSessionCreated()
        } catch {
            Self.logger.error("connect failed error=\(error.localizedDescription, privacy: .public)")
            stop()
            throw error
        }

        Self.logger.info("connect ready")
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendInputAudio(base64PCM16: String) async throws {
        guard !base64PCM16.isEmpty else { return }
        sentInputAudioChunkCount += 1
        if sentInputAudioChunkCount == 1 || sentInputAudioChunkCount.isMultiple(of: 25) {
            Self.logger.debug("client -> input_audio_buffer.append count=\(self.sentInputAudioChunkCount, privacy: .public) bytes64=\(base64PCM16.count, privacy: .public)")
        }
        try await send(.appendInputAudio(base64PCM16: base64PCM16))
    }

    func clearInputAudio() async throws {
        Self.logger.info("client -> input_audio_buffer.clear")
        try await send(.clearInputAudio)
    }

    func commitInputAudio() async throws {
        Self.logger.info("client -> input_audio_buffer.commit")
        try await send(.commitInputAudio)
    }

    func createResponse() async throws {
        Self.logger.info("client -> response.create")
        try await send(.createResponse)
    }

    func cancelResponse(responseID: String?) async throws {
        Self.logger.info("client -> response.cancel responseID=\(responseID ?? "nil", privacy: .public)")
        try await send(.cancelResponse(responseID: responseID))
    }

    func truncateConversationItem(
        itemID: String,
        contentIndex: Int,
        audioEndMilliseconds: Int
    ) async throws {
        Self.logger.info("client -> conversation.item.truncate itemID=\(itemID, privacy: .public) contentIndex=\(contentIndex, privacy: .public) audioEndMs=\(audioEndMilliseconds, privacy: .public)")
        try await send(
            .truncateConversationItem(
                itemID: itemID,
                contentIndex: contentIndex,
                audioEndMilliseconds: audioEndMilliseconds
            )
        )
    }

    func stop() {
        Self.logger.info("stop websocket")
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        eventHandler = nil
        audioHandler = nil
        sentInputAudioChunkCount = 0
        receivedAudioDeltaCount = 0
    }

    private func send(_ event: RealtimeClientEvent) async throws {
        guard let webSocketTask else {
            throw RealtimeWebSocketError.notConnected
        }

        let data = try event.encodedData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw RealtimeWebSocketError.invalidEventEncoding
        }

        try await webSocketTask.send(.string(string))
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                dispatch(try await receiveEvent())
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error("receiveLoop failed error=\(error.localizedDescription, privacy: .public)")
                dispatch(.error(error.localizedDescription))
                return
            }
        }
    }

    private func waitForSessionCreated() async throws {
        didTimeoutDuringStartup = false
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.startupTimeoutNanoseconds)
                await self?.markStartupTimedOut()
            } catch {
                return
            }
        }
        defer {
            timeoutTask.cancel()
            didTimeoutDuringStartup = false
        }

        while !Task.isCancelled {
            do {
                let event = try await receiveEvent()
                switch event {
                case .sessionCreated:
                    Self.logger.info("server -> session.created")
                    return
                case .error(let message):
                    Self.logger.error("server -> error during startup message=\(message, privacy: .public)")
                    throw RealtimeWebSocketError.serverError(message)
                case .unknown:
                    continue
                default:
                    dispatch(event)
                }
            } catch {
                if didTimeoutDuringStartup {
                    throw RealtimeWebSocketError.connectionTimedOut
                }
                throw error
            }
        }

        throw RealtimeWebSocketError.notConnected
    }

    private func receiveEvent() async throws -> RealtimeServerEvent {
        guard let webSocketTask else {
            throw RealtimeWebSocketError.notConnected
        }

        let message = try await webSocketTask.receive()
        let data: Data

        switch message {
        case .data(let messageData):
            data = messageData
        case .string(let string):
            data = Data(string.utf8)
        @unknown default:
            return .unknown("unknown")
        }

        return try RealtimeServerEvent(data: data)
    }

    private func markStartupTimedOut() {
        didTimeoutDuringStartup = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func dispatch(_ event: RealtimeServerEvent) {
        if case .audioDelta(let audioDelta) = event,
           let data = Data(base64Encoded: audioDelta.base64Audio) {
            receivedAudioDeltaCount += 1
            if receivedAudioDeltaCount == 1 || receivedAudioDeltaCount.isMultiple(of: 20) {
                Self.logger.debug("server -> audio.delta count=\(self.receivedAudioDeltaCount, privacy: .public) responseID=\(audioDelta.metadata.responseID ?? "nil", privacy: .public) itemID=\(audioDelta.metadata.itemID ?? "nil", privacy: .public) bytes=\(data.count, privacy: .public)")
            }
            audioHandler?(audioDelta, data)
        } else {
            logServerEvent(event)
        }

        eventHandler?(event)
    }

    private func logServerEvent(_ event: RealtimeServerEvent) {
        switch event {
        case .sessionCreated:
            Self.logger.info("server -> session.created")
        case .inputSpeechStarted:
            Self.logger.info("server -> input_audio_buffer.speech_started")
        case .inputSpeechStopped:
            Self.logger.info("server -> input_audio_buffer.speech_stopped")
        case .responseCreated:
            Self.logger.info("server -> response.created")
        case .responseDone:
            Self.logger.info("server -> response.done")
        case .audioDone(let metadata):
            Self.logger.info("server -> audio.done responseID=\(metadata.responseID ?? "nil", privacy: .public) itemID=\(metadata.itemID ?? "nil", privacy: .public)")
        case .audioDelta:
            break
        case .error(let message):
            Self.logger.error("server -> error message=\(message, privacy: .public)")
        case .unknown(let type):
            guard type != "response.output_audio_transcript.delta" else {
                return
            }
            Self.logger.debug("server -> unknown type=\(type, privacy: .public)")
        }
    }
}

enum RealtimeWebSocketError: LocalizedError, Equatable {
    case invalidURL
    case notConnected
    case invalidEventEncoding
    case connectionTimedOut
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Realtime URL could not be built."
        case .notConnected:
            return "Realtime WebSocket is not connected."
        case .invalidEventEncoding:
            return "Realtime event could not be encoded."
        case .connectionTimedOut:
            return "Realtime connection timed out before the session was ready."
        case .serverError(let message):
            return message
        }
    }
}
