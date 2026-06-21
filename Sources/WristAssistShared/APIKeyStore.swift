public protocol APIKeyStore: Sendable {
    func saveAPIKey(_ apiKey: String) throws
    func loadAPIKey() throws -> String?
    func deleteAPIKey() throws
    func hasAPIKey() -> Bool
}
