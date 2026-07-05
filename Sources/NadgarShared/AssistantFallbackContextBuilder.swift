import Foundation

public struct AssistantFallbackContext: Equatable, Sendable {
    public var summary: String?
    public var messages: [ChatMessage]
    public var userMessage: ChatMessage
    public var approxTokenCount: Int

    public init(
        summary: String?,
        messages: [ChatMessage],
        userMessage: ChatMessage,
        approxTokenCount: Int
    ) {
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.messages = messages.filter { !$0.isPlaceholder }
        self.userMessage = userMessage
        self.approxTokenCount = approxTokenCount
    }
}

public struct AssistantFallbackContextBuilder: Sendable {
    public var maxApproxTokens: Int
    public var maxMessages: Int
    public var summaryMaxApproxTokens: Int

    public init(
        maxApproxTokens: Int = StandalonePTTDefaults.fallbackContextMaxApproxTokens,
        maxMessages: Int = StandalonePTTDefaults.fallbackContextMaxMessages,
        summaryMaxApproxTokens: Int = StandalonePTTDefaults.fallbackSummaryMaxApproxTokens
    ) {
        self.maxApproxTokens = max(1, maxApproxTokens)
        self.maxMessages = max(0, maxMessages)
        self.summaryMaxApproxTokens = max(0, summaryMaxApproxTokens)
    }

    public func build(for request: AssistantTurnRequest) -> AssistantFallbackContext {
        build(
            userMessage: request.userMessage,
            recentMessages: request.recentMessages,
            humanSummary: request.humanSummary,
            summaryThroughMessageId: request.summaryThroughMessageId,
            contextEpochID: request.contextEpochID
        )
    }

    public func build(
        userMessage: ChatMessage,
        recentMessages: [ChatMessage],
        humanSummary: String?,
        summaryThroughMessageId: UUID? = nil,
        contextEpochID: UUID? = nil
    ) -> AssistantFallbackContext {
        let summaryBudget = min(summaryMaxApproxTokens, maxApproxTokens)
        let summary = boundedText(humanSummary, maxApproxTokens: summaryBudget)
        let summaryCost = summary.map { Self.approxTokens(for: $0) } ?? 0
        // The current user turn is sent intact. If it consumes the budget, raw tail selection drops to zero.
        let userCost = Self.approxTokens(for: userMessage.text)
        var remainingBudget = max(0, maxApproxTokens - summaryCost - userCost)

        let candidateMessages = recoveryCandidates(
            from: recentMessages,
            userMessage: userMessage,
            summaryThroughMessageId: summaryThroughMessageId,
            contextEpochID: contextEpochID
        )

        var selectedReversed: [ChatMessage] = []
        for message in candidateMessages.reversed() {
            guard selectedReversed.count < maxMessages else { break }

            let messageCost = Self.approxTokens(for: message.text)
            guard messageCost <= remainingBudget else { continue }

            selectedReversed.append(message)
            remainingBudget -= messageCost
        }

        let selectedMessages = selectedReversed.reversed()
        let totalCost = summaryCost +
            selectedMessages.reduce(0) { $0 + Self.approxTokens(for: $1.text) } +
            userCost

        return AssistantFallbackContext(
            summary: summary,
            messages: Array(selectedMessages),
            userMessage: userMessage,
            approxTokenCount: totalCost
        )
    }

    public static func approxTokens(for text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    private func recoveryCandidates(
        from messages: [ChatMessage],
        userMessage: ChatMessage,
        summaryThroughMessageId: UUID?,
        contextEpochID: UUID?
    ) -> [ChatMessage] {
        let sortedMessages = messages
            .filter { message in
                !message.isPlaceholder &&
                    message.id != userMessage.id &&
                    !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    message.createdAt <= userMessage.createdAt &&
                    isInCurrentEpoch(message, contextEpochID: contextEpochID)
            }
            .sorted { $0.createdAt < $1.createdAt }

        let postSummaryMessages: [ChatMessage]
        if let summaryThroughMessageId,
           let summaryIndex = sortedMessages.firstIndex(where: { $0.id == summaryThroughMessageId }) {
            postSummaryMessages = Array(sortedMessages.dropFirst(summaryIndex + 1))
        } else {
            postSummaryMessages = sortedMessages
        }

        return Array(postSummaryMessages.suffix(maxMessages))
    }

    private func isInCurrentEpoch(_ message: ChatMessage, contextEpochID: UUID?) -> Bool {
        guard let contextEpochID else { return true }
        return message.contextEpochID == nil || message.contextEpochID == contextEpochID
    }

    private func boundedText(_ text: String?, maxApproxTokens: Int) -> String? {
        guard maxApproxTokens > 0,
              let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return nil
        }

        guard Self.approxTokens(for: trimmed) > maxApproxTokens else {
            return trimmed
        }

        let maxCharacters = maxApproxTokens * 4
        guard maxCharacters > 0 else { return nil }
        if maxCharacters <= 3 {
            return String(trimmed.prefix(maxCharacters)).nilIfEmpty
        }

        let prefix = String(trimmed.prefix(maxCharacters - 3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)...".nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
