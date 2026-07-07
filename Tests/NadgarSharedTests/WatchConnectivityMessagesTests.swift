import Foundation
import Testing
@testable import NadgarShared

struct WatchConnectivityMessagesTests {
    @Test func phoneConfigurationRoundTripsWithoutAPIKeyPayload() throws {
        let settings = ProviderSettings(
            hasAPIKey: false,
            model: "gpt-5.4-mini",
            transcriptionModel: "gpt-4o-transcribe",
            voice: "marin"
        )
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
        #expect(payloadString.contains("gpt-5.4-mini"))
        #expect(payloadString.contains("gpt-4o-transcribe"))
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
        let original = PhoneToWatchMessage.syncAPIKey(profileID: "provider-1", apiKey: "sk-test")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phoneDeleteAPIKeyRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.deleteAPIKey(profileID: "provider-1")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phoneClearConversationHistoryRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.clearConversationHistory

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phoneKeyStatusResponseRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.keyStatusResponse(profileID: "provider-1", hasKey: true)

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phoneOpenURLResultRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.openURLResult(success: false, message: "Could not open.")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try PhoneToWatchMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func phonePendingOpenURLRequestRoundTripsThroughDictionaryEnvelope() throws {
        let original = PhoneToWatchMessage.requestPendingOpenURL

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
        let original = WatchToPhoneMessage.keyStatusRequest(profileID: "provider-1")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchKeyStatusResponseRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.keyStatusResponse(profileID: "provider-1", hasKey: false)

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchStateReportRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.reportConnectionState(.listening)

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchOpenURLRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.openURL("https://openai.com/news")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchConversationHistoryClearedRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.conversationHistoryCleared

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchNoPendingOpenURLRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.noPendingOpenURL

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func watchErrorRoundTripsThroughDictionaryEnvelope() throws {
        let original = WatchToPhoneMessage.error("Could not clear history.")

        let envelope = try MessageEnvelope(dictionary: original.envelope().dictionary())
        let decoded = try WatchToPhoneMessage(envelope: envelope)

        #expect(decoded == original)
    }

    @Test func missingPayloadThrowsTypedError() throws {
        let envelope = MessageEnvelope(type: "authUnavailable")

        do {
            _ = try PhoneToWatchMessage(envelope: envelope)
            Issue.record("Expected missing payload error.")
        } catch let error as MessageCodingError {
            #expect(error == .missingPayload("authUnavailable"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
