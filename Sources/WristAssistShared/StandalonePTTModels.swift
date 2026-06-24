import Foundation

public enum WatchPTTState: String, Codable, Equatable, Sendable {
    case ready
    case recording
    case transcribing
    case thinking
    case failed

    public var statusText: String {
        switch self {
        case .ready:
            return "Hold to talk"
        case .recording:
            return "Release to send"
        case .transcribing:
            return "Transcribing"
        case .thinking:
            return "Thinking"
        case .failed:
            return "Try again"
        }
    }
}

public enum ChatMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var role: ChatMessageRole
    public var text: String
    public var createdAt: Date
    public var isPlaceholder: Bool

    public init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        createdAt: Date = Date(),
        isPlaceholder: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isPlaceholder = isPlaceholder
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case isPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(ChatMessageRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
    }
}

public enum StandalonePTTDefaults {
    public static let assistantModel = "gpt-5.5"
    public static let transcriptionModel = "gpt-4o-mini-transcribe"
    public static let audioSampleRate = 24_000
}
