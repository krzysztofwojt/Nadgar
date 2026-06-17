import Foundation
import Security
import WristAssistShared

@MainActor
final class WatchVoiceViewModel: ObservableObject {
    @Published private(set) var state: RealtimeConnectionState
    @Published private(set) var settings: ProviderSettings
    @Published private(set) var errorMessage: String?

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

    private let connectivity: WatchConnectivityClient
    private let configurationStore: WatchConfigurationStore
    private var realtimeClient: RealtimeWebSocketClient?
    private var audioPipeline: WatchAudioPipeline?
    private var apiKey: String?

    init() {
        let configurationStore = WatchConfigurationStore()
        let localConfiguration = configurationStore.loadConfiguration()

        self.configurationStore = configurationStore
        self.connectivity = WatchConnectivityClient()
        self.state = .idle
        self.settings = localConfiguration.settings
        self.apiKey = localConfiguration.apiKey

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

    private func start() async {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .idle
            errorMessage = nil
            return
        }

        do {
            errorMessage = nil
            state = .connecting
            try? await connectivity.reportState(state)

            let client = RealtimeWebSocketClient()
            let pipeline = WatchAudioPipeline()

            try await client.connect(
                token: apiKey,
                settings: settings,
                eventHandler: { [weak self] event in
                    Task { @MainActor in
                        self?.handle(event)
                    }
                },
                audioHandler: { data in
                    Task { @MainActor in
                        pipeline.enqueueOutputAudio(data)
                    }
                }
            )

            try await pipeline.start { base64Audio in
                Task {
                    try? await client.sendInputAudio(base64PCM16: base64Audio)
                }
            }

            realtimeClient = client
            audioPipeline = pipeline
            state = .listening
            try? await connectivity.reportState(state)
        } catch {
            await stop()
            state = .failed
            errorMessage = error.localizedDescription
            try? await connectivity.reportState(state)
        }
    }

    private func stop() async {
        state = .stopping
        audioPipeline?.stop()
        audioPipeline = nil
        await realtimeClient?.stop()
        realtimeClient = nil
        state = .idle
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
        switch event {
        case .sessionCreated:
            state = .listening
        case .inputSpeechStarted:
            state = .listening
        case .inputSpeechStopped:
            break
        case .responseCreated:
            state = .speaking
        case .responseDone, .audioDone:
            state = .listening
        case .audioDelta:
            state = .speaking
        case .error(let message):
            state = .failed
            errorMessage = message
        case .unknown:
            break
        }
    }
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
