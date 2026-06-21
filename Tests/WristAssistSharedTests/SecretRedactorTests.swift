import Testing
@testable import WristAssistShared

struct SecretRedactorTests {
    @Test func redactsOpenAIAPIKeysAndBearerTokens() {
        let value = "key sk-test1234 project sk-proj-abc123 Bearer token.value-123"
        let redacted = SecretRedactor.redact(value)

        #expect(!redacted.contains("sk-test1234"))
        #expect(!redacted.contains("sk-proj-abc123"))
        #expect(!redacted.contains("token.value-123"))
        #expect(redacted.contains("[redacted-api-key]"))
        #expect(redacted.contains("Bearer [redacted-token]"))
    }
}
