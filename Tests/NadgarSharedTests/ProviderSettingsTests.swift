import Foundation
import Testing
@testable import NadgarShared

struct ProviderSettingsTests {
    @Test func initializerNormalizesSupportedModelsAndVoice() {
        let settings = ProviderSettings(
            model: " GPT-5.4-MINI ",
            transcriptionModel: " GPT-4O-TRANSCRIBE ",
            voice: " CEDAR ",
            instructions: "Be concise."
        )

        #expect(settings.model == "gpt-5.4-mini")
        #expect(settings.transcriptionModel == "gpt-4o-transcribe")
        #expect(settings.voice == "cedar")
    }

    @Test func unsupportedModelsFallBackToDefaults() {
        let settings = ProviderSettings(model: "legacy-model", transcriptionModel: "legacy-transcribe")

        #expect(settings.model == ProviderSettings.defaultModel)
        #expect(settings.transcriptionModel == ProviderSettings.defaultTranscriptionModel)
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
          "model": " GPT-5.4 ",
          "transcriptionModel": " GPT-4O-TRANSCRIBE ",
          "voice": " MARIN ",
          "instructions": "Answer briefly."
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ProviderSettings.self, from: data)

        #expect(settings.model == "gpt-5.4")
        #expect(settings.transcriptionModel == "gpt-4o-transcribe")
        #expect(settings.voice == "marin")
        #expect(settings.instructions == "Answer briefly.")
        #expect(!settings.isAutoReadEnabled)
        #expect(!settings.shouldIgnoreSilentModeForAutoRead)
        #expect(settings.ttsModel == ProviderSettings.defaultTTSModel)
    }

    @Test func initializerStoresAutoReadSilentModeOverrideAndNormalizesTTSModel() {
        let settings = ProviderSettings(
            voice: "NOVA",
            isAutoReadEnabled: true,
            shouldIgnoreSilentModeForAutoRead: true,
            ttsModel: "legacy-tts"
        )

        #expect(settings.voice == "nova")
        #expect(settings.isAutoReadEnabled)
        #expect(settings.shouldIgnoreSilentModeForAutoRead)
        #expect(settings.ttsModel == ProviderSettings.defaultTTSModel)
    }

    @Test func decodedSettingsDefaultMissingTranscriptionModel() throws {
        let data = """
        {
          "selectedAuthMode": "openAIAPIKey",
          "hasAPIKey": true,
          "model": "gpt-5.4-mini",
          "voice": "marin",
          "instructions": "Answer briefly."
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ProviderSettings.self, from: data)

        #expect(settings.model == "gpt-5.4-mini")
        #expect(settings.transcriptionModel == ProviderSettings.defaultTranscriptionModel)
    }

    @Test func legacySettingsDecodeToDeterministicOpenAIProfileAndSelections() throws {
        let data = """
        {
          "selectedAuthMode": "openAIAPIKey",
          "hasAPIKey": true,
          "model": "gpt-5.5",
          "transcriptionModel": "gpt-4o-transcribe"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ProviderSettings.self, from: data)

        #expect(settings.providerProfiles.count == 1)
        #expect(settings.providerProfiles.first?.id == ProviderProfile.legacyOpenAIProfileID)
        #expect(settings.providerProfiles.first?.name == "OpenAI API")
        #expect(settings.selectedResponse == TaskModelSelection(
            profileID: ProviderProfile.legacyOpenAIProfileID,
            model: "gpt-5.5"
        ))
        #expect(settings.selectedTranscription == TaskModelSelection(
            profileID: ProviderProfile.legacyOpenAIProfileID,
            model: "gpt-4o-transcribe"
        ))
        #expect(settings.selectedSpeech == TaskModelSelection(
            profileID: ProviderProfile.legacyOpenAIProfileID,
            model: ProviderSettings.defaultTTSModel
        ))
    }

    @Test func newSettingsCanPersistZeroProvidersWithoutRecreatingOpenAI() throws {
        let data = """
        {
          "selectedAuthMode": "openAIAPIKey",
          "hasAPIKey": false,
          "providerProfiles": [],
          "selectedResponse": null,
          "selectedTranscription": null,
          "configurationVersion": 3
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ProviderSettings.self, from: data)

        #expect(settings.providerProfiles.isEmpty)
        #expect(settings.selectedResponse == nil)
        #expect(settings.selectedTranscription == nil)
        #expect(settings.selectedSpeech == nil)
        #expect(settings.configurationVersion == 3)
    }

    @Test func hermesProfileNormalizesURLModelAndDefaultName() throws {
        let profile = ProviderProfile(
            type: .hermes,
            name: " ",
            hermesBaseURL: " https://hermes.example.com/nadgar/ ",
            hermesResponseModel: " Hermes-Agent ",
            hermesResponseModels: [" Hermes-Agent ", "gpt-oss", "GPT-OSS", " "]
        )

        #expect(profile.name == "Hermes Agent")
        #expect(profile.hermesBaseURL == "https://hermes.example.com/nadgar")
        #expect(profile.hermesResponseModel == "hermes-agent")
        #expect(profile.hermesResponseModels == ["hermes-agent", "gpt-oss"])
        #expect(profile.hermesV1BaseURL?.absoluteString == "https://hermes.example.com/nadgar/v1")
    }

    @Test func decodedLegacyHermesProfileKeepsSelectedModelWithoutCachedModels() throws {
        let data = """
        {
          "id": "hermes-1",
          "type": "hermes",
          "name": "Hermes API",
          "hasAPIKey": true,
          "hermesBaseURL": "https://hermes.example.com/v1",
          "hermesResponseModel": "custom-hermes-model"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ProviderProfile.self, from: data)

        #expect(profile.hermesResponseModel == "custom-hermes-model")
        #expect(profile.hermesResponseModels.isEmpty)
    }

    @Test func hermesBaseURLRequiresHTTPS() {
        #expect(ProviderProfile.hermesV1BaseURL(from: "http://hermes.example.com/v1") == nil)
        #expect(ProviderProfile.hermesV1BaseURL(from: "https://hermes.example.com/v1")?.absoluteString == "https://hermes.example.com/v1")
    }

    @Test func hermesCanBeSelectedForResponsesButNotTranscription() {
        let hermes = ProviderProfile(
            id: "hermes-1",
            type: .hermes,
            hasAPIKey: true,
            hermesBaseURL: "https://hermes.example.com/v1",
            hermesResponseModel: "hermes-agent",
            hermesResponseModels: ["hermes-agent", "gpt-oss"]
        )
        let settings = ProviderSettings(
            providerProfiles: [hermes],
            selectedResponse: TaskModelSelection(profileID: "hermes-1", model: "gpt-oss"),
            selectedTranscription: TaskModelSelection(profileID: "hermes-1", model: "hermes-agent"),
            selectedSpeech: TaskModelSelection(profileID: "hermes-1", model: "hermes-agent")
        )

        #expect(settings.selectedResponse == TaskModelSelection(profileID: "hermes-1", model: "gpt-oss"))
        #expect(settings.selectedTranscription == nil)
        #expect(settings.selectedSpeech == nil)
        #expect(settings.selectedResponseContextProviderID == "hermes:hermes-1:gpt-oss")
    }

    @Test func currentUnavailableHermesModelIsPreservedWhenItMatchesProfileSelection() {
        let hermes = ProviderProfile(
            id: "hermes-1",
            type: .hermes,
            hasAPIKey: true,
            hermesBaseURL: "https://hermes.example.com/v1",
            hermesResponseModel: "legacy-model",
            hermesResponseModels: ["new-model"]
        )
        let settings = ProviderSettings(
            providerProfiles: [hermes],
            selectedResponse: TaskModelSelection(profileID: "hermes-1", model: "legacy-model")
        )

        #expect(settings.selectedResponse == TaskModelSelection(profileID: "hermes-1", model: "legacy-model"))
    }

    @Test func responseAndSpeechCanUseDifferentProviders() {
        let openAI = ProviderProfile(id: "openai-1", type: .openAI, name: "OpenAI Speech", hasAPIKey: true)
        let hermes = ProviderProfile(
            id: "hermes-1",
            type: .hermes,
            name: "Hermes api",
            hasAPIKey: true,
            hermesBaseURL: "https://hermes.example.com/v1",
            hermesResponseModel: "hermes-agent"
        )

        let settings = ProviderSettings(
            providerProfiles: [openAI, hermes],
            selectedResponse: TaskModelSelection(profileID: "hermes-1", model: "hermes-agent"),
            selectedTranscription: TaskModelSelection(profileID: "openai-1", model: ProviderSettings.defaultTranscriptionModel),
            selectedSpeech: TaskModelSelection(profileID: "openai-1", model: ProviderSettings.defaultTTSModel)
        )

        #expect(settings.selectedResponse == TaskModelSelection(profileID: "hermes-1", model: "hermes-agent"))
        #expect(settings.selectedTranscription == TaskModelSelection(
            profileID: "openai-1",
            model: ProviderSettings.defaultTranscriptionModel
        ))
        #expect(settings.selectedSpeech == TaskModelSelection(
            profileID: "openai-1",
            model: ProviderSettings.defaultTTSModel
        ))
        #expect(settings.ttsModel == ProviderSettings.defaultTTSModel)
    }

    @Test func supportedModelOptionsExposeDisplayNamesAndAPIValues() {
        #expect(ProviderSettings.supportedAssistantModels.map(\.displayName).contains("GPT-5.4 nano"))
        #expect(ProviderSettings.supportedAssistantModels.map(\.apiValue).contains("gpt-5.4-nano"))
        #expect(ProviderSettings.supportedTranscriptionModels.map(\.displayName).contains("GPT-4o mini Transcribe"))
        #expect(ProviderSettings.supportedTranscriptionModels.map(\.apiValue).contains("gpt-4o-mini-transcribe"))
        #expect(ProviderSettings.supportedSpeechModels.map(\.displayName).contains("GPT-4o mini TTS"))
        #expect(ProviderSettings.supportedSpeechModels.map(\.apiValue).contains(ProviderSettings.defaultTTSModel))
    }

    @Test func supportedVoicesExposeCapitalizedDisplayNamesAndLowercaseAPIValues() {
        let voiceNames = ProviderSettings.supportedVoices.map(\.displayName)
        let apiValues = ProviderSettings.supportedVoices.map(\.apiValue)

        #expect(voiceNames.contains("Marin"))
        #expect(voiceNames.contains("Fable"))
        #expect(voiceNames.contains("Nova"))
        #expect(voiceNames.contains("Onyx"))
        #expect(!ProviderSettings.supportedVoices.map(\.displayName).contains("marin"))
        #expect(apiValues == [
            "alloy",
            "ash",
            "ballad",
            "coral",
            "echo",
            "fable",
            "nova",
            "onyx",
            "sage",
            "shimmer",
            "verse",
            "marin",
            "cedar"
        ])
        #expect(!apiValues.contains("Marin"))
    }
}
