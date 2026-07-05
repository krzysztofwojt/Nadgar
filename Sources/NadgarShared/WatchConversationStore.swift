import Foundation

public struct WatchConversationRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let defaultConversationKey = "default"

    public var schemaVersion: Int
    public var conversationKey: String
    public var activeProviderID: String
    public var contextEpochID: UUID
    public var providerContexts: [String: ProviderContextState]
    public var humanSummary: String?
    public var summaryThroughMessageId: UUID?
    public var summaryContextEpochID: UUID?
    public var lastContextResetAt: Date?
    public var events: [ConversationEvent]
    public var messages: [ChatMessage]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        conversationKey: String = Self.defaultConversationKey,
        activeProviderID: String = AssistantProviderIDs.openAI,
        contextEpochID: UUID = UUID(),
        providerContexts: [String: ProviderContextState] = [:],
        humanSummary: String? = nil,
        summaryThroughMessageId: UUID? = nil,
        summaryContextEpochID: UUID? = nil,
        lastContextResetAt: Date? = nil,
        events: [ConversationEvent] = [],
        messages: [ChatMessage] = []
    ) {
        self.schemaVersion = schemaVersion
        self.conversationKey = conversationKey
        self.activeProviderID = activeProviderID
        self.contextEpochID = contextEpochID
        self.providerContexts = providerContexts
        self.humanSummary = humanSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.summaryThroughMessageId = summaryThroughMessageId
        self.summaryContextEpochID = humanSummary == nil && summaryThroughMessageId == nil
            ? nil
            : summaryContextEpochID ?? contextEpochID
        self.lastContextResetAt = lastContextResetAt
        self.events = events
        self.messages = Self.normalizedMessages(messages, defaultContextEpochID: contextEpochID)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case conversationKey
        case activeProviderID
        case contextEpochID
        case providerContexts
        case humanSummary
        case summaryThroughMessageId
        case summaryContextEpochID
        case lastContextResetAt
        case events
        case messages
        case lastResponseId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let conversationKey = try container.decodeIfPresent(String.self, forKey: .conversationKey) ?? Self.defaultConversationKey
        let activeProviderID = try container.decodeIfPresent(String.self, forKey: .activeProviderID) ?? AssistantProviderIDs.openAI
        let contextEpochID = try container.decodeIfPresent(UUID.self, forKey: .contextEpochID) ?? UUID()
        var providerContexts = try container.decodeIfPresent(
            [String: ProviderContextState].self,
            forKey: .providerContexts
        ) ?? [:]
        let legacyLastResponseId = try container.decodeIfPresent(String.self, forKey: .lastResponseId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if let legacyLastResponseId,
           providerContexts[AssistantProviderIDs.openAI] == nil {
            providerContexts[AssistantProviderIDs.openAI] = ProviderContextState(
                providerID: AssistantProviderIDs.openAI,
                lastRemoteTurnID: legacyLastResponseId
            )
        }

        self.init(
            schemaVersion: max(schemaVersion, Self.currentSchemaVersion),
            conversationKey: conversationKey,
            activeProviderID: activeProviderID,
            contextEpochID: contextEpochID,
            providerContexts: providerContexts,
            humanSummary: try container.decodeIfPresent(String.self, forKey: .humanSummary),
            summaryThroughMessageId: try container.decodeIfPresent(UUID.self, forKey: .summaryThroughMessageId),
            summaryContextEpochID: try container.decodeIfPresent(UUID.self, forKey: .summaryContextEpochID),
            lastContextResetAt: try container.decodeIfPresent(Date.self, forKey: .lastContextResetAt),
            events: try container.decodeIfPresent([ConversationEvent].self, forKey: .events) ?? [],
            messages: try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(conversationKey, forKey: .conversationKey)
        try container.encode(activeProviderID, forKey: .activeProviderID)
        try container.encode(contextEpochID, forKey: .contextEpochID)
        try container.encode(providerContexts, forKey: .providerContexts)
        try container.encodeIfPresent(humanSummary, forKey: .humanSummary)
        try container.encodeIfPresent(summaryThroughMessageId, forKey: .summaryThroughMessageId)
        try container.encodeIfPresent(summaryContextEpochID, forKey: .summaryContextEpochID)
        try container.encodeIfPresent(lastContextResetAt, forKey: .lastContextResetAt)
        try container.encode(events, forKey: .events)
        try container.encode(messages, forKey: .messages)
    }

    public var displayMessages: [ChatMessage] {
        Array(messages.suffix(StandalonePTTDefaults.visibleMessagesLimit))
    }

    public var rawRecoveryMessages: [ChatMessage] {
        Array(messages.suffix(StandalonePTTDefaults.rawRecoveryMessagesLimit))
    }

    public var currentEpochMessages: [ChatMessage] {
        messages.filter { $0.contextEpochID == contextEpochID }
    }

    public var currentEpochRawRecoveryMessages: [ChatMessage] {
        Array(currentEpochMessages.suffix(StandalonePTTDefaults.rawRecoveryMessagesLimit))
    }

    public var fallbackContextMessages: [ChatMessage] {
        rawRecoveryMessages
    }

    public var hasSummarizedEarlierContext: Bool {
        humanSummary != nil || summaryThroughMessageId != nil
    }

    public var humanSummaryForCurrentEpoch: String? {
        guard summaryContextEpochID == contextEpochID else { return nil }
        return humanSummary
    }

    public var summaryThroughMessageIdForCurrentEpoch: UUID? {
        guard summaryContextEpochID == contextEpochID else { return nil }
        return summaryThroughMessageId
    }

    public var activeProviderContext: ProviderContextState? {
        providerContexts[activeProviderID]
    }

    public mutating func appendMessage(_ message: ChatMessage) {
        guard !message.isPlaceholder else { return }
        var message = message
        message.contextEpochID = contextEpochID
        messages.removeAll { $0.id == message.id }
        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
    }

    public mutating func setProviderContext(_ providerContext: ProviderContextState?) {
        guard let providerContext else {
            providerContexts.removeValue(forKey: activeProviderID)
            return
        }

        providerContexts[providerContext.providerID] = providerContext
    }

    public mutating func markActiveProviderContextRequiresLocalHistoryBootstrap() {
        var providerContext = activeProviderContext ?? ProviderContextState(providerID: activeProviderID)
        providerContext.markRequiresLocalHistoryBootstrap()
        providerContexts[providerContext.providerID] = providerContext
    }

    public mutating func rotateModelContext(at date: Date = Date()) {
        contextEpochID = UUID()
        providerContexts[activeProviderID] = ProviderContextState(providerID: activeProviderID)
        lastContextResetAt = date
        events.append(ConversationEvent(
            kind: .contextReset,
            createdAt: date,
            providerID: activeProviderID,
            contextEpochID: contextEpochID
        ))
    }

    public mutating func clearHistory() {
        contextEpochID = UUID()
        providerContexts.removeAll()
        humanSummary = nil
        summaryThroughMessageId = nil
        summaryContextEpochID = nil
        lastContextResetAt = nil
        events.removeAll()
        messages.removeAll()
    }

    public mutating func markSummarized(summary: String, through messageId: UUID) {
        humanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        summaryThroughMessageId = messageId
        summaryContextEpochID = contextEpochID

        if let throughMessage = messages.first(where: { $0.id == messageId }),
           let summarizedEpochID = throughMessage.contextEpochID {
            messages.removeAll {
                $0.contextEpochID == summarizedEpochID &&
                    $0.createdAt <= throughMessage.createdAt
            }
        }

        pruneStoredMessagesToLimit()
    }

    public mutating func pruneStoredMessagesToLimit() {
        guard messages.count > StandalonePTTDefaults.rawRecoveryMessagesLimit else { return }
        messages = Array(messages.suffix(StandalonePTTDefaults.rawRecoveryMessagesLimit))
    }

    private static func normalizedMessages(
        _ messages: [ChatMessage],
        defaultContextEpochID: UUID
    ) -> [ChatMessage] {
        messages
            .filter { !$0.isPlaceholder }
            .map { message in
                var message = message
                if message.contextEpochID == nil {
                    message.contextEpochID = defaultContextEpochID
                }
                return message
            }
    }
}

public struct WatchConversationStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultStore() throws -> WatchConversationStore {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return WatchConversationStore(fileURL: supportDirectory.appendingPathComponent("watch-conversation.json"))
    }

    public func load() throws -> WatchConversationRecord {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return WatchConversationRecord()
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(WatchConversationRecord.self, from: data)
    }

    public func save(_ record: WatchConversationRecord) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var recordToSave = record
        var data = try JSONEncoder().encode(recordToSave)
        if data.count > StandalonePTTDefaults.conversationJSONHardCapBytes {
            recordToSave.pruneStoredMessagesToLimit()
            data = try JSONEncoder().encode(recordToSave)
        }
        guard data.count <= StandalonePTTDefaults.conversationJSONHardCapBytes else {
            throw WatchConversationStoreError.recordTooLarge(data.count)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public enum WatchConversationStoreError: LocalizedError, Equatable {
    case recordTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .recordTooLarge(let byteCount):
            return "Conversation history is too large to save (\(byteCount) bytes)."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
