import Foundation

public enum RealtimeClientEvent: Equatable, Sendable {
    case sessionUpdate(RealtimeSession)
    case appendInputAudio(base64PCM16: String)
    case commitInputAudio
    case createResponse
    case cancelResponse

    public func encodedData() throws -> Data {
        let object = try jsonObject()
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    public func jsonObject() throws -> [String: Any] {
        switch self {
        case .sessionUpdate(let session):
            let data = try RealtimeJSON.encoder.encode(session)
            let sessionObject = try JSONSerialization.jsonObject(with: data, options: [])
            return [
                "type": "session.update",
                "session": sessionObject
            ]

        case .appendInputAudio(let base64PCM16):
            return [
                "type": "input_audio_buffer.append",
                "audio": base64PCM16
            ]

        case .commitInputAudio:
            return ["type": "input_audio_buffer.commit"]

        case .createResponse:
            return ["type": "response.create"]

        case .cancelResponse:
            return ["type": "response.cancel"]
        }
    }
}

public enum RealtimeJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()
}
