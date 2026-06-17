import Foundation

public struct RealtimeClientSecretResponse: Decodable, Equatable, Sendable {
    public let value: String
    public let expiresAt: Int?

    public init(value: String, expiresAt: Int? = nil) {
        self.value = value
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let directValue = try container.decodeIfPresent(String.self, forKey: .value) {
            value = directValue
            expiresAt = try container.decodeIfPresent(Int.self, forKey: .expiresAt)
            return
        }

        if let nested = try container.decodeIfPresent(NestedClientSecret.self, forKey: .clientSecret) {
            value = nested.value
            expiresAt = nested.expiresAt
            return
        }

        throw DecodingError.keyNotFound(
            CodingKeys.value,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected value or client_secret.value in Realtime client secret response."
            )
        )
    }

    enum CodingKeys: String, CodingKey {
        case value
        case expiresAt = "expires_at"
        case clientSecret = "client_secret"
    }

    struct NestedClientSecret: Decodable {
        let value: String
        let expiresAt: Int?

        enum CodingKeys: String, CodingKey {
            case value
            case expiresAt = "expires_at"
        }
    }
}
