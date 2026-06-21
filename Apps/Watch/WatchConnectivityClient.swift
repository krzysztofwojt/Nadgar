import Foundation
import WatchConnectivity
import WristAssistShared

final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    var onConfigurationChanged: (@MainActor (WatchConfiguration) -> Void)?
    var onSettingsChanged: (@MainActor (ProviderSettings) -> Void)?
    var onSyncAPIKey: (@MainActor (String) -> Bool)?
    var onDeleteAPIKey: (@MainActor () -> Bool)?
    var hasLocalAPIKey: (@MainActor () -> Bool)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func requestSettings() async throws -> ProviderSettings {
        let reply = try await send(.requestSettings)
        switch reply {
        case .configurationChanged(let configuration):
            return configuration.settings
        case .settingsChanged(let settings):
            return settings
        case .syncAPIKey, .deleteAPIKey, .keyStatusResponse:
            _ = await handlePhoneMessage(reply)
            return .default
        case .error(let message), .authUnavailable(let message):
            throw WatchConnectivityClientError.remote(message)
        case .tokenResponse:
            throw WatchConnectivityClientError.unexpectedReply
        }
    }

    func requestConfiguration() async throws -> WatchConfiguration {
        let reply = try await send(.requestConfiguration)
        switch reply {
        case .configurationChanged(let configuration):
            return configuration
        case .settingsChanged(let settings):
            let hasKey = await MainActor.run {
                hasLocalAPIKey?() ?? settings.hasAPIKey
            }
            return WatchConfiguration(settings: settings, hasAPIKey: hasKey)
        case .syncAPIKey, .deleteAPIKey, .keyStatusResponse:
            _ = await handlePhoneMessage(reply)
            let hasKey = await MainActor.run {
                hasLocalAPIKey?() ?? false
            }
            return WatchConfiguration(settings: .default, hasAPIKey: hasKey)
        case .error(let message), .authUnavailable(let message):
            throw WatchConnectivityClientError.remote(message)
        case .tokenResponse:
            throw WatchConnectivityClientError.unexpectedReply
        }
    }

    func requestRealtimeToken(settings: ProviderSettings) async throws -> String {
        let reply = try await send(.requestRealtimeToken(settings))
        switch reply {
        case .tokenResponse(let token):
            return token
        case .authUnavailable(let message), .error(let message):
            throw WatchConnectivityClientError.remote(message)
        case .configurationChanged, .settingsChanged, .syncAPIKey, .deleteAPIKey, .keyStatusResponse:
            throw WatchConnectivityClientError.unexpectedReply
        }
    }

    func requestKeyStatus() async throws {
        let reply = try await send(.keyStatusRequest)
        _ = await handlePhoneMessage(reply)
    }

    func reportState(_ state: RealtimeConnectionState) async throws {
        _ = try await send(.reportConnectionState(state), expectsReply: false)
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        handleIncoming(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            let reply = await handleIncomingWithReply(message)
            replyHandler(reply)
        }
    }

    private func handleIncoming(_ message: [String: Any]) {
        guard let envelope = try? MessageEnvelope(dictionary: message),
              let decoded = try? PhoneToWatchMessage(envelope: envelope)
        else {
            return
        }

        Task { @MainActor in
            _ = await handlePhoneMessage(decoded)
        }
    }

    @MainActor
    private func handleIncomingWithReply(_ message: [String: Any]) async -> [String: Any] {
        guard let envelope = try? MessageEnvelope(dictionary: message),
              let decoded = try? PhoneToWatchMessage(envelope: envelope)
        else {
            return [:]
        }

        guard let reply = await handlePhoneMessage(decoded) else {
            return [:]
        }

        return (try? reply.envelope().dictionary()) ?? [:]
    }

    @MainActor
    @discardableResult
    private func handlePhoneMessage(_ message: PhoneToWatchMessage) async -> WatchToPhoneMessage? {
        switch message {
        case .configurationChanged(let configuration):
            onConfigurationChanged?(configuration)
            return nil
        case .settingsChanged(let settings):
            onSettingsChanged?(settings)
            return nil
        case .syncAPIKey(let apiKey):
            let hasKey = onSyncAPIKey?(apiKey) ?? false
            return .keyStatusResponse(hasKey: hasKey)
        case .deleteAPIKey:
            let hasKey = onDeleteAPIKey?() ?? (hasLocalAPIKey?() ?? false)
            return .keyStatusResponse(hasKey: hasKey)
        case .keyStatusResponse, .tokenResponse, .authUnavailable, .error:
            return nil
        }
    }

    private func send(_ message: WatchToPhoneMessage, expectsReply: Bool = true) async throws -> PhoneToWatchMessage {
        guard WCSession.isSupported() else {
            throw WatchConnectivityClientError.unsupported
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            throw WatchConnectivityClientError.notActivated
        }

        guard session.isReachable else {
            throw WatchConnectivityClientError.phoneUnreachable
        }

        let dictionary = try message.envelope().dictionary()

        if !expectsReply {
            session.sendMessage(dictionary, replyHandler: nil)
            return .settingsChanged(.default)
        }

        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(
                dictionary,
                replyHandler: { reply in
                    do {
                        let envelope = try MessageEnvelope(dictionary: reply)
                        continuation.resume(returning: try PhoneToWatchMessage(envelope: envelope))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                },
                errorHandler: { error in
                    continuation.resume(throwing: error)
                }
            )
        }
    }
}

enum WatchConnectivityClientError: LocalizedError, Equatable {
    case unsupported
    case notActivated
    case phoneUnreachable
    case unexpectedReply
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "WatchConnectivity is unavailable."
        case .notActivated:
            return "Connection to iPhone is not active yet."
        case .phoneUnreachable:
            return "Open WristAssist on iPhone and keep it nearby."
        case .unexpectedReply:
            return "iPhone returned an unexpected message."
        case .remote(let message):
            return message
        }
    }
}
