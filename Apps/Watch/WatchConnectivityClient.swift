import Foundation
import WatchConnectivity
import WristAssistShared

final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    var onConfigurationChanged: (@MainActor (WatchConfiguration) -> Void)?
    var onSettingsChanged: (@MainActor (ProviderSettings) -> Void)?
    var onSyncAPIKey: (@MainActor (String) -> Bool)?
    var onDeleteAPIKey: (@MainActor () -> Bool)?
    var hasLocalAPIKey: (@MainActor () -> Bool)?
    private let pendingOpenURLLock = NSLock()
    private var pendingOpenURLString: String?

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
        case .syncAPIKey, .deleteAPIKey, .keyStatusResponse, .requestPendingOpenURL, .openURLResult:
            _ = await handlePhoneMessage(reply)
            return .default
        case .error(let message), .authUnavailable(let message):
            throw WatchConnectivityClientError.remote(message)
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
        case .syncAPIKey, .deleteAPIKey, .keyStatusResponse, .requestPendingOpenURL, .openURLResult:
            _ = await handlePhoneMessage(reply)
            let hasKey = await MainActor.run {
                hasLocalAPIKey?() ?? false
            }
            return WatchConfiguration(settings: .default, hasAPIKey: hasKey)
        case .error(let message), .authUnavailable(let message):
            throw WatchConnectivityClientError.remote(message)
        }
    }

    func requestKeyStatus() async throws {
        let reply = try await send(.keyStatusRequest)
        guard let statusReply = await handlePhoneMessage(reply) else { return }

        _ = try await send(statusReply, expectsReply: false)
    }

    func reportState(_ state: RealtimeConnectionState) async throws {
        _ = try await send(.reportConnectionState(state), expectsReply: false)
    }

    func openURLOnPhone(_ url: URL) async throws {
        do {
            let reply = try await send(.openURL(url.absoluteString))
            switch reply {
            case .openURLResult(let success, let message):
                guard success else {
                    throw WatchConnectivityClientError.remote(message ?? "iPhone could not open this source.")
                }
            case .configurationChanged, .settingsChanged, .syncAPIKey, .deleteAPIKey, .keyStatusResponse, .requestPendingOpenURL:
                _ = await handlePhoneMessage(reply)
                throw WatchConnectivityClientError.unexpectedReply
            case .error(let message), .authUnavailable(let message):
                throw WatchConnectivityClientError.remote(message)
            }
        } catch {
            guard Self.shouldQueuePendingOpenURL(for: error) else {
                throw error
            }

            enqueuePendingOpenURL(url)
        }
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
        case .keyStatusResponse(let hasKey):
            guard !hasKey else { return nil }
            let remainingKey = onDeleteAPIKey?() ?? (hasLocalAPIKey?() ?? false)
            return .keyStatusResponse(hasKey: remainingKey)
        case .requestPendingOpenURL:
            guard let pendingURL = dequeuePendingOpenURL() else {
                return .noPendingOpenURL
            }
            return .openURL(pendingURL)
        case .openURLResult:
            return nil
        case .authUnavailable, .error:
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

    private func enqueuePendingOpenURL(_ url: URL) {
        if transferPendingOpenURL(url) {
            return
        }

        pendingOpenURLLock.lock()
        pendingOpenURLString = url.absoluteString
        pendingOpenURLLock.unlock()
    }

    private func transferPendingOpenURL(_ url: URL) -> Bool {
        guard WCSession.isSupported() else { return false }

        let session = WCSession.default
        guard session.activationState == .activated else { return false }
        guard let dictionary = try? WatchToPhoneMessage.openURL(url.absoluteString).envelope().dictionary() else {
            return false
        }

        session.transferUserInfo(dictionary)
        return true
    }

    private func dequeuePendingOpenURL() -> String? {
        pendingOpenURLLock.lock()
        let urlString = pendingOpenURLString
        pendingOpenURLString = nil
        pendingOpenURLLock.unlock()
        return urlString
    }

    private static func shouldQueuePendingOpenURL(for error: Error) -> Bool {
        if case WatchConnectivityClientError.phoneUnreachable = error {
            return true
        }

        if case WatchConnectivityClientError.remote(let message) = error {
            return message == "Companion app is not installed."
        }

        let nsError = error as NSError
        return nsError.domain == WCErrorDomain &&
            nsError.code == 7018
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
