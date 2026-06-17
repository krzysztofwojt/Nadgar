import Foundation
import WatchConnectivity
import WristAssistShared

final class PhoneConnectivityController: NSObject, WCSessionDelegate {
    private let settingsProvider: @MainActor () -> ProviderSettings
    private let apiKeyProvider: () throws -> String?
    private let tokenService: OpenAIRealtimeTokenServing
    private let safetyIdentifierStore = SafetyIdentifierStore()
    private let statusHandler: @MainActor (String) -> Void
    private let errorHandler: @MainActor (String) -> Void

    init(
        settingsProvider: @escaping @MainActor () -> ProviderSettings,
        apiKeyProvider: @escaping () throws -> String?,
        tokenService: OpenAIRealtimeTokenServing,
        statusHandler: @escaping @MainActor (String) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void
    ) {
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
        self.tokenService = tokenService
        self.statusHandler = statusHandler
        self.errorHandler = errorHandler
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
        let apiKey = try? apiKeyProvider()
        sendConfiguration(WatchConfiguration(settings: settings, apiKey: apiKey))
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
                do {
                    sendConfiguration(try await currentConfiguration())
                } catch {
                    await MainActor.run {
                        errorHandler(error.localizedDescription)
                    }
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

            case .requestRealtimeToken(let requestedSettings):
                guard requestedSettings.selectedAuthMode == .openAIAPIKey else {
                    return reply(.authUnavailable("ChatGPT/Codex credentials cannot authorize Realtime API sessions."))
                }

                guard let apiKey = try apiKeyProvider(), !apiKey.isEmpty else {
                    return reply(.authUnavailable("Save an OpenAI API key on iPhone before starting from Apple Watch."))
                }

                let token = try await tokenService.createClientSecret(
                    apiKey: apiKey,
                    settings: requestedSettings,
                    safetyIdentifier: safetyIdentifierStore.identifier()
                )
                return reply(.tokenResponse(token))

            case .reportConnectionState(let state):
                await MainActor.run {
                    statusHandler("Watch: \(state.displayName)")
                }
                return [:]
            }
        } catch {
            await MainActor.run {
                errorHandler(error.localizedDescription)
            }
            return reply(.error(error.localizedDescription))
        }
    }

    private func reply(_ message: PhoneToWatchMessage) -> [String: Any] {
        (try? message.envelope().dictionary()) ?? [:]
    }

    private func currentConfiguration() async throws -> WatchConfiguration {
        let settings = await MainActor.run { settingsProvider() }
        return WatchConfiguration(settings: settings, apiKey: try apiKeyProvider())
    }
}
