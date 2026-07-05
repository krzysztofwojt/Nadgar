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
    public var contextEpochID: UUID?

    public init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        createdAt: Date = Date(),
        isPlaceholder: Bool = false,
        citations: [ChatCitation] = [],
        contextEpochID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isPlaceholder = isPlaceholder
        self.citations = citations
        self.contextEpochID = contextEpochID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case isPlaceholder
        case citations
        case contextEpochID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(ChatMessageRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
        self.citations = try container.decodeIfPresent([ChatCitation].self, forKey: .citations) ?? []
        self.contextEpochID = try container.decodeIfPresent(UUID.self, forKey: .contextEpochID)
    }
}

public enum StandalonePTTDefaults {
    public static let assistantModel = "gpt-5.4-nano"
    public static let transcriptionModel = "gpt-4o-mini-transcribe"
    public static let speechModel = "gpt-4o-mini-tts"
    public static let audioSampleRate = 24_000
    public static let compactThreshold = 64_000

    /// Number of messages rendered on the watch timeline. This is a UI/RAM limit, not history retention.
    public static let visibleMessagesLimit = 40

    /// Full local message tail kept for fallback recovery, future compaction, and debugging.
    public static let rawRecoveryMessagesLimit = 80

    /// Approximate fallback prompt budget for recovery bootstraps when the remote provider chain is unavailable.
    /// This intentionally stays well below large model context windows to leave room for instructions, tools,
    /// response output, and request structure without running a tokenizer on Apple Watch.
    public static let fallbackContextMaxApproxTokens = 8_000

    /// Defensive message-count cap after budget selection; budget remains the primary limiter.
    public static let fallbackContextMaxMessages = rawRecoveryMessagesLimit

    /// Summary is helpful but lossy, so cap it before spending budget on raw recovery messages.
    public static let fallbackSummaryMaxApproxTokens = 2_000

    /// Soft diagnostic threshold for the local JSON snapshot. The hard cap below is the actual safety fuse.
    public static let conversationJSONSoftCapBytes = 1 * 1024 * 1024

    /// Hard safety fuse for the atomic local JSON snapshot, not a target storage size.
    public static let conversationJSONHardCapBytes = 2 * 1024 * 1024

    public static let displayWindowLimit = visibleMessagesLimit
    public static let storedFullMessageLimit = rawRecoveryMessagesLimit
    public static let conversationStoreSoftLimitBytes = conversationJSONSoftCapBytes
    public static let conversationStoreHardLimitBytes = conversationJSONHardCapBytes
}
