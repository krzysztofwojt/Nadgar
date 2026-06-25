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

public struct ChatCitation: Codable, Equatable, Identifiable, Sendable {
    public var id: String {
        "\(startIndex)-\(endIndex)-\(url)"
    }

    public var startIndex: Int
    public var endIndex: Int
    public var url: String
    public var title: String

    public init(
        startIndex: Int,
        endIndex: Int,
        url: String,
        title: String
    ) {
        self.startIndex = max(0, startIndex)
        self.endIndex = max(self.startIndex, endIndex)
        self.url = url
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var displayTitle: String {
        if !title.isEmpty {
            return title
        }

        return host ?? url
    }

    public var host: String? {
        URL(string: url)?.host()
    }
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var role: ChatMessageRole
    public var text: String
    public var createdAt: Date
    public var isPlaceholder: Bool
    public var citations: [ChatCitation]

    public init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        createdAt: Date = Date(),
        isPlaceholder: Bool = false,
        citations: [ChatCitation] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isPlaceholder = isPlaceholder
        self.citations = citations
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case isPlaceholder
        case citations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(ChatMessageRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
        self.citations = try container.decodeIfPresent([ChatCitation].self, forKey: .citations) ?? []
    }
}

public enum StandalonePTTDefaults {
    public static let assistantModel = "gpt-5.4-nano"
    public static let transcriptionModel = "gpt-4o-mini-transcribe"
    public static let audioSampleRate = 24_000
}
