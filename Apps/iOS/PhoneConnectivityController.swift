import Foundation
import UIKit
import WatchConnectivity
import NadgarShared

final class PhoneConnectivityController: NSObject, WCSessionDelegate {
    private let settingsProvider: @MainActor () -> ProviderSettings
    private let apiKeyProvider: () throws -> String?
    private let pendingWatchKeyDeletionProvider: @MainActor () -> Bool
    private let statusHandler: @MainActor (String) -> Void
    private let errorHandler: @MainActor (String) -> Void
    private let watchKeyStatusHandler: @MainActor (Bool) -> Void

    init(
        settingsProvider: @escaping @MainActor () -> ProviderSettings,
        apiKeyProvider: @escaping () throws -> String?,
        pendingWatchKeyDeletionProvider: @escaping @MainActor () -> Bool,
        statusHandler: @escaping @MainActor (String) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void,
        watchKeyStatusHandler: @escaping @MainActor (Bool) -> Void
    ) {
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
        self.pendingWatchKeyDeletionProvider = pendingWatchKeyDeletionProvider
        self.statusHandler = statusHandler
        self.errorHandler = errorHandler
        self.watchKeyStatusHandler = watchKeyStatusHandler
    }

    func activate() {
        guard WCSession.isSupported() else {
            Task { @MainActor in statusHandler("WatchConnectivity unavailable") }
            return
        }

        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendSettings(_ settings: ProviderSettings) {
        sendConfiguration(WatchConfiguration(settings: settings))
    }

    func sendConfiguration(_ configuration: WatchConfiguration) {
        guard WCSession.isSupported() else { return }
        guard let dictionary = try? PhoneToWatchMessage.configurationChanged(configuration).envelope().dictionary() else { return }

        let session = WCSession.default
        guard session.activationState == .activated else { return }

        do {
            try session.updateApplicationContext(dictionary)
        } catch {
            Task { @MainActor in
                errorHandler(error.localizedDescription)
            }
        }

        if session.isReachable {
            session.sendMessage(
                dictionary,
                replyHandler: nil,
                errorHandler: { [errorHandler] error in
                    Task { @MainActor in
                        errorHandler(error.localizedDescription)
                    }
                }
            )
        }
    }

    @discardableResult
    func syncAPIKeyToWatch(_ apiKey: String) -> Bool {
        sendMessageToReachableWatch(
            .syncAPIKey(apiKey),
            unavailableStatus: "API key saved on iPhone. Open Nadgar on Apple Watch to sync."
        )
    }

    @discardableResult
    func sendDeleteAPIKeyToWatch() -> Bool {
        sendMessageToReachableWatch(
            .deleteAPIKey,
            unavailableStatus: "Open Nadgar on Apple Watch to finish deleting the key there."
        )
    }

    @discardableResult
    func sendMissingAPIKeyStatusToWatch() -> Bool {
        sendMessageToReachableWatch(
            .keyStatusResponse(hasKey: false),
            unavailableStatus: "Open Nadgar on Apple Watch to refresh API key status."
        )
    }

    @discardableResult
    func sendClearConversationHistoryToWatch() -> Bool {
        sendMessageToReachableWatch(
            .clearConversationHistory,
            unavailableStatus: "Open WristAssist on Apple Watch to clear conversation history."
        )
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                errorHandler(error.localizedDescription)
            }
            statusHandler(activationState == .activated ? "Activated" : "Not activated")
        }

        if activationState == .activated {
            Task {
                await requestPendingOpenURLIfPossible()

                do {
                    sendConfiguration(try await currentConfiguration())
                    sendCurrentKeyStateToReachableWatch()
                } catch {
                    await MainActor.run {
                        errorHandler(error.localizedDescription)
                    }
                }
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }

        Task {
            await requestPendingOpenURLIfPossible()

            do {
                sendConfiguration(try await currentConfiguration())
                sendCurrentKeyStateToReachableWatch()
            } catch {
                await MainActor.run {
                    errorHandler(error.localizedDescription)
                }
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in statusHandler("Inactive") }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task {
            let reply = await handleMessage(message)
            replyHandler(reply)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task {
            _ = await handleMessage(message)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task {
            _ = await handleTransferredMessage(userInfo)
        }
    }

    private func handleMessage(_ message: [String: Any]) async -> [String: Any] {
        do {
            let envelope = try MessageEnvelope(dictionary: message)
            let decoded = try WatchToPhoneMessage(envelope: envelope)

            switch decoded {
            case .requestConfiguration:
                return reply(.configurationChanged(try await currentConfiguration()))

            case .requestSettings:
                let settings = await MainActor.run { settingsProvider() }
                return reply(.settingsChanged(settings))

            case .keyStatusRequest:
                if let apiKey = try apiKeyProvider(),
                   !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return reply(.syncAPIKey(apiKey))
                }

                let hasPendingWatchDeletion = await MainActor.run {
                    pendingWatchKeyDeletionProvider()
                }
                if hasPendingWatchDeletion {
                    return reply(.deleteAPIKey)
                }

                return reply(.keyStatusResponse(hasKey: false))

            case .keyStatusResponse(let hasKey):
                await MainActor.run {
                    watchKeyStatusHandler(hasKey)
                }
                return [:]

            case .conversationHistoryCleared:
                await MainActor.run {
                    statusHandler("Watch: conversation history cleared")
                }
                return [:]

            case .error(let message):
                await MainActor.run {
                    errorHandler(message)
                }
                return [:]

            case .reportConnectionState(let state):
                await MainActor.run {
                    statusHandler("Watch: \(state.displayName)")
                }
                return [:]

            case .openURL(let urlString):
                return reply(await openURL(urlString))

            case .noPendingOpenURL:
                return [:]
            }
        } catch {
            await MainActor.run {
                errorHandler(error.localizedDescription)
            }
            return reply(.error(error.localizedDescription))
        }
    }

    private func handleTransferredMessage(_ message: [String: Any]) async -> PhoneToWatchMessage? {
        guard let envelope = try? MessageEnvelope(dictionary: message),
              let decoded = try? WatchToPhoneMessage(envelope: envelope)
        else {
            return nil
        }

        switch decoded {
        case .openURL(let urlString):
            return await openURL(urlString)
        case .requestConfiguration, .requestSettings, .keyStatusRequest, .keyStatusResponse,
                .reportConnectionState, .noPendingOpenURL, .conversationHistoryCleared, .error:
            return nil
        }
    }

    private func requestPendingOpenURLIfPossible() async {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        guard let dictionary = try? PhoneToWatchMessage.requestPendingOpenURL.envelope().dictionary() else { return }

        session.sendMessage(
            dictionary,
            replyHandler: { [weak self] reply in
                Task {
                    await self?.handlePendingOpenURLReply(reply)
                }
            },
            errorHandler: nil
        )
    }

    private func handlePendingOpenURLReply(_ reply: [String: Any]) async {
        guard let envelope = try? MessageEnvelope(dictionary: reply),
              let decoded = try? WatchToPhoneMessage(envelope: envelope)
        else {
            return
        }

        switch decoded {
        case .openURL(let urlString):
            _ = await openURL(urlString)
        case .noPendingOpenURL:
            return
        case .requestConfiguration, .requestSettings, .keyStatusRequest, .keyStatusResponse,
                .reportConnectionState, .conversationHistoryCleared, .error:
            return
        }
    }

    private func reply(_ message: PhoneToWatchMessage) -> [String: Any] {
        (try? message.envelope().dictionary()) ?? [:]
    }

    private func openURL(_ urlString: String) async -> PhoneToWatchMessage {
        guard let url = URL(string: urlString) else {
            return .openURLResult(success: false, message: "Source URL is invalid.")
        }

        guard Self.isWebURL(url) else {
            return .openURLResult(success: false, message: "Only web source URLs can be opened.")
        }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                UIApplication.shared.open(url, options: [:]) { success in
                    continuation.resume(
                        returning: .openURLResult(
                            success: success,
                            message: success ? nil : "iPhone could not open this source."
                        )
                    )
                }
            }
        }
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func currentConfiguration() async throws -> WatchConfiguration {
        let settings = await MainActor.run { settingsProvider() }
        let hasAPIKey = try apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return WatchConfiguration(settings: settings, hasAPIKey: hasAPIKey)
    }

    func sendCurrentKeyStateToReachableWatch() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        Task {
            do {
                if let apiKey = try apiKeyProvider(),
                   !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    syncAPIKeyToWatch(apiKey)
                    return
                }

                let hasPendingWatchDeletion = await MainActor.run {
                    pendingWatchKeyDeletionProvider()
                }
                if hasPendingWatchDeletion {
                    sendDeleteAPIKeyToWatch()
                    return
                }

                sendMissingAPIKeyStatusToWatch()
            } catch {
                await MainActor.run {
                    errorHandler(error.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    private func sendMessageToReachableWatch(
        _ message: PhoneToWatchMessage,
        unavailableStatus: String
    ) -> Bool {
        guard WCSession.isSupported() else {
            Task { @MainActor in statusHandler("WatchConnectivity unavailable") }
            return false
        }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            Task { @MainActor in statusHandler(unavailableStatus) }
            return false
        }

        guard let dictionary = try? message.envelope().dictionary() else {
            Task { @MainActor in errorHandler("Could not encode WatchConnectivity message.") }
            return false
        }

        session.sendMessage(
            dictionary,
            replyHandler: { [errorHandler, statusHandler, watchKeyStatusHandler] reply in
                do {
                    let envelope = try MessageEnvelope(dictionary: reply)
                    let decoded = try WatchToPhoneMessage(envelope: envelope)

                    switch decoded {
                    case .keyStatusResponse(let hasKey):
                        Task { @MainActor in
                            watchKeyStatusHandler(hasKey)
                            statusHandler(hasKey ? "Watch: API key synced" : "Watch: API key deleted")
                        }
                    case .conversationHistoryCleared:
                        Task { @MainActor in
                            statusHandler("Watch: conversation history cleared")
                        }
                    case .error(let message):
                        Task { @MainActor in
                            errorHandler(message)
                        }
                    case .keyStatusRequest, .requestConfiguration, .requestSettings, .reportConnectionState,
                            .openURL, .noPendingOpenURL:
                        Task { @MainActor in
                            errorHandler("Apple Watch returned an unexpected reply.")
                        }
                    }
                } catch {
                    Task { @MainActor in
                        errorHandler(error.localizedDescription)
                    }
                }
            },
            errorHandler: { [errorHandler] error in
                Task { @MainActor in
                    errorHandler(error.localizedDescription)
                }
            }
        )

        return true
    }
}
