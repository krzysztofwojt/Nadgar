import Testing
@testable import WristAssistShared

struct RealtimeTokenModelsTests {
    @Test func decodesDirectClientSecretValue() throws {
        let data = #"{"value":"direct","expires_at":123}"#.data(using: .utf8)!
        let decoded = try RealtimeJSON.decoder.decode(RealtimeClientSecretResponse.self, from: data)

        #expect(decoded == RealtimeClientSecretResponse(value: "direct", expiresAt: 123))
    }

    @Test func decodesNestedClientSecretValue() throws {
        let data = #"{"client_secret":{"value":"nested","expires_at":456}}"#.data(using: .utf8)!
        let decoded = try RealtimeJSON.decoder.decode(RealtimeClientSecretResponse.self, from: data)

        #expect(decoded == RealtimeClientSecretResponse(value: "nested", expiresAt: 456))
    }
}
