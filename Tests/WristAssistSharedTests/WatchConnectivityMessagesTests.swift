import Testing
@testable import WristAssistShared

struct WatchConnectivityMessagesTests {
    @Test func phoneConfigurationWithAPIKeyRoundTripsThroughDictionaryEnvelope() throws {
        let settings = ProviderSettings(hasAPIKey: false, model: "gpt-realtime-2", voice: "marin")
        let configuration = WatchConfiguration(settings: settings, apiKey: "sk-test")
        let original = PhoneToWatchMessage.configurationChanged(configuration)

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
        #expect(configuration.settings.hasAPIKey)
    }

    @Test func phoneConfigurationWithoutAPIKeyRoundTripsThroughDictionaryEnvelope() throws {
        let settings = ProviderSettings(hasAPIKey: true)
        let configuration = WatchConfiguration(settings: settings, apiKey: nil)
        let original = PhoneToWatchMessage.configurationChanged(configuration)

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
        #expect(!configuration.settings.hasAPIKey)
    }

    @Test func watchConfigurationRequestRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.requestConfiguration

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchTokenRequestRoundTripsThroughDictionaryEnvelope() throws {
        let settings = ProviderSettings(hasAPIKey: true)
        let original = WatchToPhoneMessage.requestRealtimeToken(settings)

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phoneTokenResponseRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.tokenResponse("ephemeral-token")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func missingPayloadThrowsTypedError() throws {
        let envelope = MessageEnvelope(type: "tokenResponse")

        do {
            _ = try PhoneToWatchMessage(envelope: envelope)
            Issue.record("Expected missing payload error.")
        } catch let error as MessageCodingError {
            #expect(error == .missingPayload("tokenResponse"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
