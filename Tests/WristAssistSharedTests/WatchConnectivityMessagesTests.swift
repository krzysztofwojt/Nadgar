import Foundation
import Testing
@testable import WristAssistShared

struct WatchConnectivityMessagesTests {
    @Test func phoneConfigurationRoundTripsWithoutAPIKeyPayload() throws {
        let settings = ProviderSettings(hasAPIKey: false, model: "gpt-realtime-2", voice: "marin")
        let configuration = WatchConfiguration(settings: settings, hasAPIKey: true)
        let original = PhoneToWatchMessage.configurationChanged(configuration)

        let dictionary = try original.envelope().dictionary()
        let envelope = try MessageEnvelope(dictionary: dictionary)
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
        #expect(configuration.settings.hasAPIKey)
        let payload = try #require(dictionary["payload"] as? Data)
        let payloadString = try #require(String(data: payload, encoding: .utf8))
        #expect(!payloadString.contains("apiKey"))
        #expect(!payloadString.contains("sk-"))
    }

    @Test func phoneSettingsRoundTripsWithoutAPIKeyPayload() throws {
        let settings = ProviderSettings(hasAPIKey: true)
        let original = PhoneToWatchMessage.settingsChanged(settings)

        let dictionary = try original.envelope().dictionary()
        let envelope = try MessageEnvelope(dictionary: dictionary)
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
        let payload = try #require(dictionary["payload"] as? Data)
        let payloadString = try #require(String(data: payload, encoding: .utf8))
        #expect(!payloadString.contains("apiKey"))
        #expect(!payloadString.contains("sk-"))
    }

    @Test func phoneSyncAPIKeyRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.syncAPIKey("sk-test")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phoneDeleteAPIKeyRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.deleteAPIKey

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phoneKeyStatusResponseRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.keyStatusResponse(hasKey: true)

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchConfigurationRequestRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.requestConfiguration

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchKeyStatusRequestRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.keyStatusRequest

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchKeyStatusResponseRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.keyStatusResponse(hasKey: false)

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
