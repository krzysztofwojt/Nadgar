import Foundation
import Security
import NadgarShared

struct KeychainCredentialStore: APIKeyStore {
    private let profileScopedService = "app.nadgar.Nadgar.ProviderAPIKeys"
    private let legacyOpenAIService = "app.nadgar.Nadgar.OpenAI"
    private let legacyOpenAIAccount = "openai-api-key"

    func saveAPIKey(_ apiKey: String, for profileID: String) throws {
        let account = normalizedProfileID(profileID)
        try upsertAPIKey(apiKey, service: profileScopedService, account: account)

        if account == ProviderProfile.legacyOpenAIProfileID {
            try deleteAPIKey(ignoringMissing: true, service: legacyOpenAIService, account: legacyOpenAIAccount)
        }
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        let account = normalizedProfileID(profileID)
        if let apiKey = try loadAPIKey(service: profileScopedService, account: account) {
            return apiKey
        }

        guard account == ProviderProfile.legacyOpenAIProfileID,
              let legacyAPIKey = try loadAPIKey(service: legacyOpenAIService, account: legacyOpenAIAccount)
        else {
            return nil
        }

        try upsertAPIKey(legacyAPIKey, service: profileScopedService, account: account)
        if try loadAPIKey(service: profileScopedService, account: account) == legacyAPIKey {
            try deleteAPIKey(ignoringMissing: true, service: legacyOpenAIService, account: legacyOpenAIAccount)
        }
        return legacyAPIKey
    }

    func deleteAPIKey(for profileID: String) throws {
        let account = normalizedProfileID(profileID)
        try deleteAPIKey(ignoringMissing: false, service: profileScopedService, account: account)

        if account == ProviderProfile.legacyOpenAIProfileID {
            try deleteAPIKey(ignoringMissing: true, service: legacyOpenAIService, account: legacyOpenAIAccount)
        }
    }

    func hasAPIKey(for profileID: String) -> Bool {
        guard let apiKey = try? loadAPIKey(for: profileID) else {
            return false
        }

        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedProfileID(_ profileID: String) -> String {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProviderProfile.legacyOpenAIProfileID : trimmed
    }

    private func loadAPIKey(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }

        guard let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidData
        }

        return apiKey
    }

    private func upsertAPIKey(_ apiKey: String, service: String, account: String) throws {
        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    private func deleteAPIKey(ignoringMissing: Bool, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound && ignoringMissing {
            return
        }

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}

enum KeychainError: LocalizedError, Equatable {
    case invalidData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The saved API key could not be decoded."
        case .unhandledStatus(let status):
            return "Keychain is unavailable: \(Self.statusDescription(status)) (status \(status))."
        }
    }

    private static func statusDescription(_ status: OSStatus) -> String {
        if status == errSecMissingEntitlement {
            return "this build is missing the Keychain entitlement."
        }

        if let message = SecCopyErrorMessageString(status, nil) {
            return message as String
        }

        return "Security framework returned an unknown error."
    }
}
