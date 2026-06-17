import Foundation

public enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated
    case inputSpeechStarted
    case inputSpeechStopped
    case responseCreated
    case responseDone
    case audioDelta(String)
    case audioDone
    case error(String)
    case unknown(String)

    public init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Realtime server event must be a JSON object with a type field."
                )
            )
        }

        switch type {
        case "session.created":
            self = .sessionCreated
        case "input_audio_buffer.speech_started":
            self = .inputSpeechStarted
        case "input_audio_buffer.speech_stopped":
            self = .inputSpeechStopped
        case "response.created":
            self = .responseCreated
        case "response.done":
            self = .responseDone
        case "response.audio.delta", "response.output_audio.delta":
            self = .audioDelta((dictionary["delta"] as? String) ?? (dictionary["audio"] as? String) ?? "")
        case "response.audio.done", "response.output_audio.done":
            self = .audioDone
        case "error":
            self = .error(Self.errorMessage(from: dictionary))
        default:
            self = .unknown(type)
        }
    }

    private static func errorMessage(from dictionary: [String: Any]) -> String {
        if let message = dictionary["message"] as? String {
            return message
        }

        if let error = dictionary["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return "Realtime API returned an error."
    }
}
