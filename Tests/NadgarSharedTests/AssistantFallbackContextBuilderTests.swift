import Foundation
import Testing
@testable import NadgarShared

struct AssistantFallbackContextBuilderTests {
    @Test func shortFallbackCanUseMoreThanTwentyFourMessages() throws {
        let messages = makeMessages(count: 70, text: "short")
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: "current",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let builder = AssistantFallbackContextBuilder(maxApproxTokens: 500, maxMessages: 80)

        let context = builder.build(
            userMessage: userMessage,
            recentMessages: messages + [userMessage],
            humanSummary: nil
        )

        #expect(context.messages.count > 24)
        #expect(context.messages.count == 70)
        #expect(context.messages.first?.text == "short 0")
        #expect(context.messages.last?.text == "short 69")
        #expect(context.userMessage.id == userMessage.id)
    }

    @Test func longFallbackUsesFewerMessagesWhenBudgetIsSpent() throws {
        let messages = makeMessages(count: 30, text: String(repeating: "x", count: 120))
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: "current",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let builder = AssistantFallbackContextBuilder(maxApproxTokens: 220, maxMessages: 80)

        let context = builder.build(
            userMessage: userMessage,
            recentMessages: messages + [userMessage],
            humanSummary: nil
        )

        #expect(context.messages.count < 24)
        #expect(context.messages.map(\.text) == Array(messages.suffix(context.messages.count)).map(\.text))
        #expect(context.approxTokenCount <= 220)
    }

    @Test func fallbackPreservesChronologicalOrderAndDoesNotDuplicateCurrentUser() throws {
        let older = ChatMessage(
            id: UUID(),
            role: .user,
            text: "older",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let newer = ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "newer",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: "current",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let builder = AssistantFallbackContextBuilder(maxApproxTokens: 100, maxMessages: 80)

        let context = builder.build(
            userMessage: userMessage,
            recentMessages: [newer, userMessage, older],
            humanSummary: "Summary"
        )

        #expect(context.summary == "Summary")
        #expect(context.messages.map(\.id) == [older.id, newer.id])
        #expect(!context.messages.contains { $0.id == userMessage.id })
        #expect(context.userMessage.id == userMessage.id)
    }

    @Test func fallbackWorksWithoutSummaryAndSkipsSummarizedRangeWhenAvailable() throws {
        let messages = makeMessages(count: 10, text: "message")
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: "current",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let builder = AssistantFallbackContextBuilder(maxApproxTokens: 100, maxMessages: 80)

        let context = builder.build(
            userMessage: userMessage,
            recentMessages: messages + [userMessage],
            humanSummary: " ",
            summaryThroughMessageId: messages[4].id
        )

        #expect(context.summary == nil)
        #expect(context.messages.map(\.text) == messages[5...].map(\.text))
        #expect(context.userMessage.text == "current")
    }

    @Test func fallbackFiltersMessagesOutsideCurrentEpoch() throws {
        let oldEpoch = UUID()
        let currentEpoch = UUID()
        let oldMessage = ChatMessage(
            role: .user,
            text: "old epoch",
            createdAt: Date(timeIntervalSince1970: 1),
            contextEpochID: oldEpoch
        )
        let currentMessage = ChatMessage(
            role: .assistant,
            text: "current epoch",
            createdAt: Date(timeIntervalSince1970: 2),
            contextEpochID: currentEpoch
        )
        let userMessage = ChatMessage(
            role: .user,
            text: "current",
            createdAt: Date(timeIntervalSince1970: 3),
            contextEpochID: currentEpoch
        )
        let request = AssistantTurnRequest(
            conversationKey: "default",
            contextEpochID: currentEpoch,
            providerContext: nil,
            userMessage: userMessage,
            recentMessages: [oldMessage, currentMessage, userMessage],
            humanSummary: "Current summary",
            settings: .default
        )

        let context = AssistantFallbackContextBuilder(maxApproxTokens: 100).build(for: request)

        #expect(context.summary == "Current summary")
        #expect(context.messages.map(\.text) == ["current epoch"])
        #expect(context.userMessage.text == "current")
    }

    @Test func fallbackIgnoresPlaceholdersAndPreservesRoles() throws {
        let realUser = ChatMessage(
            role: .user,
            text: "real user",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let placeholder = ChatMessage(
            role: .assistant,
            text: "Writing...",
            createdAt: Date(timeIntervalSince1970: 2),
            isPlaceholder: true
        )
        let realAssistant = ChatMessage(
            role: .assistant,
            text: "real assistant",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let userMessage = ChatMessage(
            role: .user,
            text: "current",
            createdAt: Date(timeIntervalSince1970: 4)
        )

        let context = AssistantFallbackContextBuilder(maxApproxTokens: 100).build(
            userMessage: userMessage,
            recentMessages: [realAssistant, placeholder, realUser, userMessage],
            humanSummary: nil
        )

        #expect(context.messages.map(\.text) == ["real user", "real assistant"])
        #expect(context.messages.map(\.role) == [.user, .assistant])
    }

    @Test func fallbackWorksWithoutLocalHistory() throws {
        let userMessage = ChatMessage(role: .user, text: "current")

        let context = AssistantFallbackContextBuilder(maxApproxTokens: 10).build(
            userMessage: userMessage,
            recentMessages: [],
            humanSummary: nil
        )

        #expect(context.summary == nil)
        #expect(context.messages.isEmpty)
        #expect(context.userMessage == userMessage)
    }

    @Test func fallbackWorksWithOnlySummaryAndCurrentMessage() throws {
        let userMessage = ChatMessage(role: .user, text: "current")

        let context = AssistantFallbackContextBuilder(maxApproxTokens: 20).build(
            userMessage: userMessage,
            recentMessages: [],
            humanSummary: "Only summary"
        )

        #expect(context.summary == "Only summary")
        #expect(context.messages.isEmpty)
        #expect(context.userMessage == userMessage)
    }

    @Test func longSummaryIsTrimmedBeforeSelectingRawMessages() throws {
        let messages = makeMessages(count: 20, text: "tail")
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: "current",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let builder = AssistantFallbackContextBuilder(
            maxApproxTokens: 20,
            maxMessages: 80,
            summaryMaxApproxTokens: 8
        )

        let context = builder.build(
            userMessage: userMessage,
            recentMessages: messages + [userMessage],
            humanSummary: String(repeating: "s", count: 200)
        )

        #expect(context.summary != nil)
        #expect(context.summary?.hasSuffix("...") == true)
        #expect(context.approxTokenCount <= 20)
    }

    @Test func budgetIncludesMessageOnBoundaryAndSkipsWhenOverBoundary() throws {
        let includedMessage = ChatMessage(
            role: .assistant,
            text: String(repeating: "a", count: 16),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let userMessage = ChatMessage(
            role: .user,
            text: String(repeating: "u", count: 8),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        var builder = AssistantFallbackContextBuilder(maxApproxTokens: 6, maxMessages: 80)

        var context = builder.build(
            userMessage: userMessage,
            recentMessages: [includedMessage, userMessage],
            humanSummary: nil
        )

        #expect(context.messages.map(\.id) == [includedMessage.id])
        #expect(context.approxTokenCount == 6)

        let overBoundaryMessage = ChatMessage(
            role: .assistant,
            text: String(repeating: "a", count: 17),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        builder = AssistantFallbackContextBuilder(maxApproxTokens: 6, maxMessages: 80)
        context = builder.build(
            userMessage: userMessage,
            recentMessages: [overBoundaryMessage, userMessage],
            humanSummary: nil
        )

        #expect(context.messages.isEmpty)
    }

    @Test func currentUserMessageCanConsumeRawHistoryBudgetWithoutDroppingSummary() throws {
        let messages = makeMessages(count: 10, text: "tail")
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: String(repeating: "u", count: 80),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let builder = AssistantFallbackContextBuilder(
            maxApproxTokens: 20,
            maxMessages: 80,
            summaryMaxApproxTokens: 4
        )

        let context = builder.build(
            userMessage: userMessage,
            recentMessages: messages + [userMessage],
            humanSummary: "Memo"
        )

        #expect(context.summary == "Memo")
        #expect(context.messages.isEmpty)
        #expect(context.userMessage.text == userMessage.text)
    }

    private func makeMessages(count: Int, text: String) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: UUID(),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "\(text) \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }
}
