import Foundation

public enum RealtimeConnectionState: String, Codable, Equatable, Sendable {
    case idle
    case requestingToken
    case connecting
    case listening
    case speaking
    case stopping
    case failed

    public var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .requestingToken:
            return "Requesting token"
        case .connecting:
            return "Connecting"
        case .listening:
            return "Listening"
        case .speaking:
            return "Speaking"
        case .stopping:
            return "Stopping"
        case .failed:
            return "Failed"
        }
    }
}
