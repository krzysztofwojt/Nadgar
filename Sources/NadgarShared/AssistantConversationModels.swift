import Foundation

public enum AssistantProviderIDs {
    public static let openAI = "openai"

    public static func hermes(profileID: String, model: String) -> String {
        "hermes:\(profileID):\(model)"
    }
}

public struct ProviderContextState: Codable, Equatable, Sendable {
    public var providerID: String
    public var contextID: String?
    public var parentContextID: String?
    public var lastRemoteTurnID: String?
    public var metadata: [String: String]

    public init(
        providerID: String,
        contextID: String? = nil,
        parentContextID: String? = nil,
        lastRemoteTurnID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.contextID = contextID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.parentContextID = parentContextID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.lastRemoteTurnID = lastRemoteTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.metadata = metadata
    }
}

public extension ProviderContextState {
    var requiresLocalHistoryBootstrap: Bool {
        metadata[ProviderContextMetadataKeys.requiresLocalHistoryBootstrap] == "true"
    }

    mutating func markRequiresLocalHistoryBootstrap() {
        metadata[ProviderContextMetadataKeys.requiresLocalHistoryBootstrap] = "true"
    }

    mutating func clearLocalHistoryBootstrapRequirement() {
        metadata.removeValue(forKey: ProviderContextMetadataKeys.requiresLocalHistoryBootstrap)
    }
}

private enum ProviderContextMetadataKeys {
    static let requiresLocalHistoryBootstrap = "requiresLocalHistoryBootstrap"
}

public struct AssistantTurnRequest: Equatable, Sendable {
    public var conversationKey: String
    public var contextEpochID: UUID
    public var providerContext: ProviderContextState?
    public var userMessage: ChatMessage
    public var recentMessages: [ChatMessage]
    public var humanSummary: String?
    public var summaryThroughMessageId: UUID?
    public var settings: ProviderSettings

    public init(
        conversationKey: String,
        contextEpochID: UUID,
        providerContext: ProviderContextState?,
        userMessage: ChatMessage,
        recentMessages: [ChatMessage],
        humanSummary: String?,
        summaryThroughMessageId: UUID? = nil,
        settings: ProviderSettings
    ) {
        self.conversationKey = conversationKey
        self.contextEpochID = contextEpochID
        self.providerContext = providerContext
        self.userMessage = userMessage
        self.recentMessages = recentMessages.filter { !$0.isPlaceholder }
        self.humanSummary = humanSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.summaryThroughMessageId = summaryThroughMessageId
        self.settings = settings
    }
}

public struct AssistantTurnResult: Equatable, Sendable {
    public var response: OpenAIAssistantResponse
    public var providerContext: ProviderContextState?
    public var summaryUpdate: ConversationSummaryResult?

    public init(
        response: OpenAIAssistantResponse,
        providerContext: ProviderContextState?,
        summaryUpdate: ConversationSummaryResult? = nil
    ) {
        self.response = response
        self.providerContext = providerContext
        self.summaryUpdate = summaryUpdate
    }
}

public struct ConversationSummaryRequest: Equatable, Sendable {
    public var conversationKey: String
    public var contextEpochID: UUID
    public var providerContext: ProviderContextState?
    public var currentSummary: String?
    public var messages: [ChatMessage]
    public var throughMessageID: UUID
    public var settings: ProviderSettings

    public init(
        conversationKey: String,
        contextEpochID: UUID,
        providerContext: ProviderContextState?,
        currentSummary: String?,
        messages: [ChatMessage],
        throughMessageID: UUID,
        settings: ProviderSettings
    ) {
        self.conversationKey = conversationKey
        self.contextEpochID = contextEpochID
        self.providerContext = providerContext
        self.currentSummary = currentSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.messages = messages.filter { !$0.isPlaceholder }
        self.throughMessageID = throughMessageID
        self.settings = settings
    }
}

public struct ConversationSummaryResult: Equatable, Sendable {
    public var summary: String
    public var throughMessageID: UUID
    public var providerContext: ProviderContextState?

    public init(summary: String, throughMessageID: UUID, providerContext: ProviderContextState? = nil) {
        self.summary = summary
        self.throughMessageID = throughMessageID
        self.providerContext = providerContext
    }
}

public enum AssistantProviderError: LocalizedError, Equatable, Sendable {
    case invalidContextHandle
    case missingContextID
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .invalidContextHandle:
            return "The provider context is no longer valid."
        case .missingContextID:
            return "The provider did not return a context identifier."
        case .notConfigured:
            return "The assistant provider is not configured."
        }
    }
}

public struct ConversationEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case contextReset
    }

    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    public var providerID: String
    public var contextEpochID: UUID

    public init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = Date(),
        providerID: String,
        contextEpochID: UUID
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.providerID = providerID
        self.contextEpochID = contextEpochID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
