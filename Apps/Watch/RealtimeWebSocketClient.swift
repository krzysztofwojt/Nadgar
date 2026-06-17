import Foundation
import WristAssistShared

actor RealtimeWebSocketClient {
    private static let startupTimeoutNanoseconds: UInt64 = 8_000_000_000

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (RealtimeServerEvent) -> Void)?
    private var audioHandler: (@Sendable (Data) -> Void)?
    private var didTimeoutDuringStartup = false

    func connect(
        token: String,
        settings: ProviderSettings,
        eventHandler: @escaping @Sendable (RealtimeServerEvent) -> Void,
        audioHandler: @escaping @Sendable (Data) -> Void
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

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        do {
            try await send(.sessionUpdate(RealtimeSession(settings: settings)))
            try await waitForSessionCreated()
        } catch {
            stop()
            throw error
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendInputAudio(base64PCM16: String) async throws {
        guard !base64PCM16.isEmpty else { return }
        try await send(.appendInputAudio(base64PCM16: base64PCM16))
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        eventHandler = nil
        audioHandler = nil
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
                    return
                case .error(let message):
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
        if case .audioDelta(let base64Audio) = event,
           let data = Data(base64Encoded: base64Audio) {
            audioHandler?(data)
        }

        eventHandler?(event)
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
