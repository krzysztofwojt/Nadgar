import Foundation
import Testing
@testable import WristAssistShared

struct ProviderSettingsTests {
    @Test func initializerForcesDefaultModelAndNormalizesVoice() {
        let settings = ProviderSettings(
            model: "legacy-model",
            voice: " CEDAR ",
            instructions: "Be concise."
        )

        #expect(settings.model == ProviderSettings.defaultModel)
        #expect(settings.voice == "cedar")
    }

    @Test func unsupportedVoiceFallsBackToDefaultVoice() {
        let settings = ProviderSettings(voice: "unknown")

        #expect(settings.voice == ProviderSettings.defaultVoice)
    }

    @Test func decodedSettingsAreNormalized() throws {
        let data = """
        {
          "selectedAuthMode": "openAIAPIKey",
          "hasAPIKey": true,
          "model": "legacy-model",
          "voice": " MARIN ",
          "instructions": "Answer briefly."
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ProviderSettings.self, from: data)

        #expect(settings.model == ProviderSettings.defaultModel)
        #expect(settings.voice == "marin")
        #expect(settings.instructions == "Answer briefly.")
    }

    @Test func supportedVoicesExposeCapitalizedDisplayNamesAndLowercaseAPIValues() {
        #expect(ProviderSettings.supportedVoices.map(\.displayName).contains("Marin"))
        #expect(!ProviderSettings.supportedVoices.map(\.displayName).contains("marin"))
        #expect(ProviderSettings.supportedVoices.map(\.apiValue).contains("marin"))
        #expect(!ProviderSettings.supportedVoices.map(\.apiValue).contains("Marin"))
    }
}
