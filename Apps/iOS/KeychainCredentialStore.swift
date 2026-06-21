import Foundation
import Security
import WristAssistShared

struct KeychainCredentialStore: APIKeyStore {
    private let service = "com.kwojt.WristAssist.OpenAI"
    private let legacyServices = ["com.kwojt.WristAssist.openai"]
    private let account = "openai-api-key"

    func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        try deleteAPIKey(ignoringMissing: true, services: allServices)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    func loadAPIKey() throws -> String? {
        if let apiKey = try loadAPIKey(from: service) {
            return apiKey
        }

        for legacyService in legacyServices {
            if let apiKey = try loadAPIKey(from: legacyService) {
                try saveAPIKey(apiKey)
                return apiKey
            }
        }

        return nil
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(ignoringMissing: false, services: allServices)
    }

    func hasAPIKey() -> Bool {
        guard let apiKey = try? loadAPIKey() else {
            return false
        }

        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var allServices: [String] {
        [service] + legacyServices
    }

    private func loadAPIKey(from service: String) throws -> String? {
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

    private func deleteAPIKey(ignoringMissing: Bool, services: [String]) throws {
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound && ignoringMissing {
                continue
            }

            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unhandledStatus(status)
            }
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
            return "Keychain failed with status \(status)."
        }
    }
}
