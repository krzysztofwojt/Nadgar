public protocol APIKeyStore: Sendable {
    func saveAPIKey(_ apiKey: String, for profileID: String) throws
    func loadAPIKey(for profileID: String) throws -> String?
    func deleteAPIKey(for profileID: String) throws
    func hasAPIKey(for profileID: String) -> Bool
}

public extension APIKeyStore {
    func saveAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, for: ProviderProfile.legacyOpenAIProfileID)
    }

    func loadAPIKey() throws -> String? {
        try loadAPIKey(for: ProviderProfile.legacyOpenAIProfileID)
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(for: ProviderProfile.legacyOpenAIProfileID)
    }

    func hasAPIKey() -> Bool {
        hasAPIKey(for: ProviderProfile.legacyOpenAIProfileID)
    }
}
