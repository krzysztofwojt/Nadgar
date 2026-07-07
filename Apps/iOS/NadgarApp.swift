import Foundation
import SwiftUI
import NadgarShared

@main
struct NadgarApp: App {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var didRunResponseTest = false

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.start()
                    runResponseTestIfRequested()
                }
        }
    }

    private func runResponseTestIfRequested() {
        guard !didRunResponseTest else { return }
        didRunResponseTest = true

        guard let request = ResponseTestLaunchRequest.current else { return }

        Task {
            await ResponseTestLaunchRunner().run(request: request)
        }
    }
}

private struct ResponseTestLaunchRequest {
    static let defaultPrompt = "Reply with exactly: Nadgar response test OK."

    var profileID: String?
    var model: String?
    var prompt: String
    var instructions: String?

    static var current: ResponseTestLaunchRequest? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-NadgarResponseTest") else { return nil }

        return ResponseTestLaunchRequest(
            profileID: value(after: "-NadgarResponseTestProfileID", in: arguments),
            model: value(after: "-NadgarResponseTestModel", in: arguments),
            prompt: value(after: "-NadgarResponseTestPrompt", in: arguments) ?? defaultPrompt,
            instructions: value(after: "-NadgarResponseTestInstructions", in: arguments)
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index))
        else {
            return nil
        }

        let value = arguments[arguments.index(after: index)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct ResponseTestLaunchRunner {
    private let settingsStore: UserDefaults
    private let credentialStore: any APIKeyStore
    private let responseTester: ProviderResponseTesting

    init(
        settingsStore: UserDefaults = .standard,
        credentialStore: any APIKeyStore = KeychainCredentialStore(),
        responseTester: ProviderResponseTesting = ProviderResponseTestService()
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.responseTester = responseTester
    }

    func run(request: ResponseTestLaunchRequest) async {
        do {
            let settings = loadSettings()
            guard let profile = selectProfile(settings: settings, requestedProfileID: request.profileID) else {
                throw ProviderResponseTestError.providerError("No response-capable provider is configured.")
            }

            let apiKey = try credentialStore.loadAPIKey(for: profile.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !apiKey.isEmpty else {
                throw ProviderResponseTestError.providerError("No API key is saved for profile \(profile.id).")
            }

            guard let model = selectModel(profile: profile, settings: settings, request: request) else {
                throw ProviderResponseTestError.providerError("No response model is configured for profile \(profile.id).")
            }

            let instructions = request.instructions ?? settings.instructions
            print("NADGAR_RESPONSE_TEST_STARTED profileID=\(profile.id) type=\(profile.type.rawValue) model=\(model)")
            let output = try await responseTester.testResponse(
                apiKey: apiKey,
                profile: profile,
                model: model,
                instructions: instructions,
                prompt: request.prompt
            )
            print("NADGAR_RESPONSE_TEST_OK profileID=\(profile.id) model=\(model) text=\(output)")
        } catch {
            print("NADGAR_RESPONSE_TEST_FAILED error=\(error.localizedDescription)")
        }
    }

    private func loadSettings() -> ProviderSettings {
        guard let data = settingsStore.data(forKey: "ProviderSettings"),
              var settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else {
            return .default
        }

        if settings.selectedAuthMode == .chatGPTCodexUnavailable {
            settings.selectedAuthMode = .openAIAPIKey
        }
        return settings
    }

    private func selectProfile(settings: ProviderSettings, requestedProfileID: String?) -> ProviderProfile? {
        if let requestedProfileID {
            return settings.providerProfiles.first {
                $0.id == requestedProfileID && $0.type.supportsResponses
            }
        }

        if let selectedResponse = settings.selectedResponse,
           let profile = settings.profile(id: selectedResponse.profileID),
           profile.type.supportsResponses {
            return profile
        }

        return settings.providerProfiles.first { $0.type.supportsResponses }
    }

    private func selectModel(
        profile: ProviderProfile,
        settings: ProviderSettings,
        request: ResponseTestLaunchRequest
    ) -> String? {
        if let model = request.model {
            return model
        }

        if settings.selectedResponse?.profileID == profile.id {
            return settings.selectedResponse?.model
        }

        switch profile.type {
        case .openAI:
            return ProviderSettings.defaultModel
        case .hermes:
            let model = profile.hermesResponseModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : model
        case .custom:
            return nil
        }
    }
}
