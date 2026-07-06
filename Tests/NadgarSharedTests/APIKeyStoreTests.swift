import Testing
@testable import NadgarShared

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

    @Test func fakeStoreScopesAPIKeysByProfileID() throws {
        let store = FakeAPIKeyStore()

        try store.saveAPIKey("sk-one", for: "profile-1")
        try store.saveAPIKey("sk-two", for: "profile-2")

        #expect(try store.loadAPIKey(for: "profile-1") == "sk-one")
        #expect(try store.loadAPIKey(for: "profile-2") == "sk-two")

        try store.deleteAPIKey(for: "profile-1")

        #expect(try store.loadAPIKey(for: "profile-1") == nil)
        #expect(try store.loadAPIKey(for: "profile-2") == "sk-two")
    }
}

private final class FakeAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var apiKeys: [String: String] = [:]

    func saveAPIKey(_ apiKey: String, for profileID: String) throws {
        apiKeys[profileID] = apiKey
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        apiKeys[profileID]
    }

    func deleteAPIKey(for profileID: String) throws {
        apiKeys.removeValue(forKey: profileID)
    }

    func hasAPIKey(for profileID: String) -> Bool {
        apiKeys[profileID]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
