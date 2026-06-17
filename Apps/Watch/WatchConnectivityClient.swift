import Foundation
import WatchConnectivity
import WristAssistShared

final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    var onConfigurationChanged: ((WatchConfiguration) -> Void)?
    var onSettingsChanged: ((ProviderSettings) -> Void)?

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
            return WatchConfiguration(settings: settings, apiKey: nil)
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
        case .configurationChanged, .settingsChanged:
            throw WatchConnectivityClientError.unexpectedReply
        }
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

    private func handleIncoming(_ message: [String: Any]) {
        guard let envelope = try? MessageEnvelope(dictionary: message),
              let decoded = try? PhoneToWatchMessage(envelope: envelope)
        else {
            return
        }

        switch decoded {
        case .configurationChanged(let configuration):
            onConfigurationChanged?(configuration)
        case .settingsChanged(let settings):
            onSettingsChanged?(settings)
        case .tokenResponse, .authUnavailable, .error:
            break
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
