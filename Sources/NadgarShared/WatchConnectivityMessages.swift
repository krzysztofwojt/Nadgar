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

    public init(settings: ProviderSettings, hasAPIKey: Bool? = nil) {
        var normalizedSettings = settings
        if let hasAPIKey {
            if let profileID = normalizedSettings.firstOpenAIProfile()?.id {
                normalizedSettings.setAPIKeyStatus(hasAPIKey, for: profileID)
            } else {
                normalizedSettings.hasAPIKey = hasAPIKey
            }
        }

        self.settings = normalizedSettings
    }
}

public enum PhoneToWatchMessage: Equatable, Sendable {
    case configurationChanged(WatchConfiguration)
    case settingsChanged(ProviderSettings)
    case syncAPIKey(profileID: String, apiKey: String)
    case deleteAPIKey(profileID: String)
    case clearConversationHistory
    case keyStatusResponse(profileID: String?, hasKey: Bool)
    case requestPendingOpenURL
    case openURLResult(success: Bool, message: String?)
    case authUnavailable(String)
    case error(String)

    public func envelope() throws -> MessageEnvelope {
        switch self {
        case .configurationChanged(let configuration):
            return try MessageEnvelope(type: "configurationChanged", payload: encode(configuration))
        case .settingsChanged(let settings):
            return try MessageEnvelope(type: "settingsChanged", payload: encode(settings))
        case .syncAPIKey(let profileID, let apiKey):
            return try MessageEnvelope(
                type: "syncAPIKey",
                payload: encode(APIKeyPayload(profileID: profileID, apiKey: apiKey))
            )
        case .deleteAPIKey(let profileID):
            return try MessageEnvelope(type: "deleteAPIKey", payload: encode(ProfileIDPayload(profileID: profileID)))
        case .clearConversationHistory:
            return MessageEnvelope(type: "clearConversationHistory")
        case .keyStatusResponse(let profileID, let hasKey):
            return try MessageEnvelope(
                type: "keyStatusResponse",
                payload: encode(KeyStatusPayload(profileID: profileID, hasKey: hasKey))
            )
        case .requestPendingOpenURL:
            return MessageEnvelope(type: "requestPendingOpenURL")
        case .openURLResult(let success, let message):
            return try MessageEnvelope(
                type: "openURLResult",
                payload: encode(OpenURLResultPayload(success: success, message: message))
            )
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
        case "syncAPIKey":
            let payload = try decodePayload(APIKeyPayload.self, from: envelope)
            self = .syncAPIKey(profileID: payload.normalizedProfileID, apiKey: payload.apiKey)
        case "deleteAPIKey":
            let payload = try decodeOptionalPayload(ProfileIDPayload.self, from: envelope)
            self = .deleteAPIKey(profileID: payload?.normalizedProfileID ?? ProviderProfile.legacyOpenAIProfileID)
        case "clearConversationHistory":
            self = .clearConversationHistory
        case "keyStatusResponse":
            let payload = try decodePayload(KeyStatusPayload.self, from: envelope)
            self = .keyStatusResponse(profileID: payload.profileID, hasKey: payload.hasKey)
        case "requestPendingOpenURL":
            self = .requestPendingOpenURL
        case "openURLResult":
            let payload = try decodePayload(OpenURLResultPayload.self, from: envelope)
            self = .openURLResult(success: payload.success, message: payload.message)
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
    case keyStatusRequest(profileID: String?)
    case keyStatusResponse(profileID: String?, hasKey: Bool)
    case reportConnectionState(RealtimeConnectionState)
    case openURL(String)
    case noPendingOpenURL
    case conversationHistoryCleared
    case error(String)

    public func envelope() throws -> MessageEnvelope {
        switch self {
        case .requestConfiguration:
            return MessageEnvelope(type: "requestConfiguration")
        case .requestSettings:
            return MessageEnvelope(type: "requestSettings")
        case .keyStatusRequest(let profileID):
            if let profileID {
                return try MessageEnvelope(type: "keyStatusRequest", payload: encode(ProfileIDPayload(profileID: profileID)))
            }
            return MessageEnvelope(type: "keyStatusRequest")
        case .keyStatusResponse(let profileID, let hasKey):
            return try MessageEnvelope(
                type: "keyStatusResponse",
                payload: encode(KeyStatusPayload(profileID: profileID, hasKey: hasKey))
            )
        case .reportConnectionState(let state):
            return try MessageEnvelope(type: "reportConnectionState", payload: encode(StatePayload(state: state)))
        case .openURL(let url):
            return try MessageEnvelope(type: "openURL", payload: encode(URLPayload(url: url)))
        case .noPendingOpenURL:
            return MessageEnvelope(type: "noPendingOpenURL")
        case .conversationHistoryCleared:
            return MessageEnvelope(type: "conversationHistoryCleared")
        case .error(let message):
            return try MessageEnvelope(type: "error", payload: encode(MessagePayload(message: message)))
        }
    }

    public init(envelope: MessageEnvelope) throws {
        switch envelope.type {
        case "requestConfiguration":
            self = .requestConfiguration
        case "requestSettings":
            self = .requestSettings
        case "keyStatusRequest":
            let payload = try decodeOptionalPayload(ProfileIDPayload.self, from: envelope)
            self = .keyStatusRequest(profileID: payload?.profileID)
        case "keyStatusResponse":
            let payload = try decodePayload(KeyStatusPayload.self, from: envelope)
            self = .keyStatusResponse(profileID: payload.profileID, hasKey: payload.hasKey)
        case "reportConnectionState":
            self = .reportConnectionState(try decodePayload(StatePayload.self, from: envelope).state)
        case "openURL":
            self = .openURL(try decodePayload(URLPayload.self, from: envelope).url)
        case "noPendingOpenURL":
            self = .noPendingOpenURL
        case "conversationHistoryCleared":
            self = .conversationHistoryCleared
        case "error":
            self = .error(try decodePayload(MessagePayload.self, from: envelope).message)
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

private struct APIKeyPayload: Codable, Equatable {
    var profileID: String?
    var apiKey: String

    var normalizedProfileID: String {
        profileID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
            ProviderProfile.legacyOpenAIProfileID
    }
}

private struct ProfileIDPayload: Codable, Equatable {
    var profileID: String?

    var normalizedProfileID: String {
        profileID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
            ProviderProfile.legacyOpenAIProfileID
    }
}

private struct KeyStatusPayload: Codable, Equatable {
    var profileID: String?
    var hasKey: Bool
}

private struct MessagePayload: Codable, Equatable {
    let message: String
}

private struct URLPayload: Codable, Equatable {
    let url: String
}

private struct OpenURLResultPayload: Codable, Equatable {
    let success: Bool
    let message: String?
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

private func decodeOptionalPayload<T: Decodable>(_ type: T.Type, from envelope: MessageEnvelope) throws -> T? {
    guard let payload = envelope.payload else {
        return nil
    }

    return try JSONDecoder().decode(type, from: payload)
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
