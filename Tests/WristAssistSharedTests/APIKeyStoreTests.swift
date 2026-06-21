import Testing
@testable import WristAssistShared

struct APIKeyStoreTests {
    @Test func fakeStoreSavesLoadsAndDeletesAPIKey() throws {
        let store = FakeAPIKeyStore()

        #expect(!store.hasAPIKey())
        try store.saveAPIKey("sk-test")

        #expect(try store.loadAPIKey() == "sk-test")
        #expect(store.hasAPIKey())

        try store.deleteAPIKey()
        #expect(try store.loadAPIKey() == nil)
        #expect(!store.hasAPIKey())
    }
}

private final class FakeAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var apiKey: String?

    func saveAPIKey(_ apiKey: String) throws {
        self.apiKey = apiKey
    }

    func loadAPIKey() throws -> String? {
        apiKey
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }

    func hasAPIKey() -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
