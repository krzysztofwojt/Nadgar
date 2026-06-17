import Foundation

public struct MessageEnvelope: Codable, Equatable, Sendable {
    public var type: String
    public var payload: Data?

    public init(type: String, payload: Data? = nil) {
        self.type = type
        self.payload = payload
    }

    public func dictionary() -> [String: Any] {
        var dictionary: [String: Any] = ["type": type]
        if let payload {
            dictionary["payload"] = payload
        }
        return dictionary
    }

    public init(dictionary: [String: Any]) throws {
        guard let type = dictionary["type"] as? String else {
            throw MessageCodingError.missingType
        }

        self.type = type
        self.payload = dictionary["payload"] as? Data
    }
}

public struct WatchConfiguration: Codable, Equatable, Sendable {
    public var settings: ProviderSettings
    public var apiKey: String?

    public init(settings: ProviderSettings, apiKey: String?) {
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAPIKey = normalizedAPIKey?.isEmpty == false

        var normalizedSettings = settings
        normalizedSettings.hasAPIKey = hasAPIKey

        self.settings = normalizedSettings
        self.apiKey = hasAPIKey ? normalizedAPIKey : nil
    }
}

public enum PhoneToWatchMessage: Equatable, Sendable {
    case configurationChanged(WatchConfiguration)
    case settingsChanged(ProviderSettings)
    case tokenResponse(String)
    case authUnavailable(String)
    case error(String)

    public func envelope() throws -> MessageEnvelope {
        switch self {
        case .configurationChanged(let configuration):
            return try MessageEnvelope(type: "configurationChanged", payload: encode(configuration))
        case .settingsChanged(let settings):
            return try MessageEnvelope(type: "settingsChanged", payload: encode(settings))
        case .tokenResponse(let token):
            return try MessageEnvelope(type: "tokenResponse", payload: encode(TokenPayload(value: token)))
        case .authUnavailable(let message):
            return try MessageEnvelope(type: "authUnavailable", payload: encode(MessagePayload(message: message)))
        case .error(let message):
            return try MessageEnvelope(type: "error", payload: encode(MessagePayload(message: message)))
        }
    }

    public init(envelope: MessageEnvelope) throws {
        switch envelope.type {
        case "configurationChanged":
            self = .configurationChanged(try decodePayload(WatchConfiguration.self, from: envelope))
        case "settingsChanged":
            self = .settingsChanged(try decodePayload(ProviderSettings.self, from: envelope))
        case "tokenResponse":
            self = .tokenResponse(try decodePayload(TokenPayload.self, from: envelope).value)
        case "authUnavailable":
            self = .authUnavailable(try decodePayload(MessagePayload.self, from: envelope).message)
        case "error":
            self = .error(try decodePayload(MessagePayload.self, from: envelope).message)
        default:
            throw MessageCodingError.unknownType(envelope.type)
        }
    }
}

public enum WatchToPhoneMessage: Equatable, Sendable {
    case requestConfiguration
    case requestSettings
    case requestRealtimeToken(ProviderSettings)
    case reportConnectionState(RealtimeConnectionState)

    public func envelope() throws -> MessageEnvelope {
        switch self {
        case .requestConfiguration:
            return MessageEnvelope(type: "requestConfiguration")
        case .requestSettings:
            return MessageEnvelope(type: "requestSettings")
        case .requestRealtimeToken(let settings):
            return try MessageEnvelope(type: "requestRealtimeToken", payload: encode(settings))
        case .reportConnectionState(let state):
            return try MessageEnvelope(type: "reportConnectionState", payload: encode(StatePayload(state: state)))
        }
    }

    public init(envelope: MessageEnvelope) throws {
        switch envelope.type {
        case "requestConfiguration":
            self = .requestConfiguration
        case "requestSettings":
            self = .requestSettings
        case "requestRealtimeToken":
            self = .requestRealtimeToken(try decodePayload(ProviderSettings.self, from: envelope))
        case "reportConnectionState":
            self = .reportConnectionState(try decodePayload(StatePayload.self, from: envelope).state)
        default:
            throw MessageCodingError.unknownType(envelope.type)
        }
    }
}

public enum MessageCodingError: LocalizedError, Equatable {
    case missingType
    case missingPayload(String)
    case unknownType(String)

    public var errorDescription: String? {
        switch self {
        case .missingType:
            return "Message is missing a type."
        case .missingPayload(let type):
            return "Message \(type) is missing a payload."
        case .unknownType(let type):
            return "Unknown message type: \(type)."
        }
    }
}

private struct TokenPayload: Codable, Equatable {
    let value: String
}

private struct MessagePayload: Codable, Equatable {
    let message: String
}

private struct StatePayload: Codable, Equatable {
    let state: RealtimeConnectionState
}

private func encode<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
}

private func decodePayload<T: Decodable>(_ type: T.Type, from envelope: MessageEnvelope) throws -> T {
    guard let payload = envelope.payload else {
        throw MessageCodingError.missingPayload(envelope.type)
    }

    return try JSONDecoder().decode(type, from: payload)
}
