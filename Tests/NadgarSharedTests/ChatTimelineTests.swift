import Foundation
import Testing
@testable import NadgarShared

struct ChatTimelineTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test func todayUserMessageGetsTimeWithoutDayDivider() throws {
        let formatter = ChatTimelineFormatter(calendar: calendar, locale: Locale(identifier: "en_US"))
        let now = Date(timeIntervalSince1970: 1_800)
        let message = ChatMessage(
            role: .user,
            text: "Now",
            createdAt: Date(timeIntervalSince1970: 1_200)
        )

        let items = formatter.items(
            for: [message],
            hasEarlierMessages: false,
            hasSummarizedEarlierContext: false,
            lastContextResetAt: nil,
            now: now
        )

        #expect(items.count == 1)
        guard case .message(let timelineMessage) = items[0] else {
            Issue.record("Expected message item.")
            return
        }
        #expect(timelineMessage.userTimestamp != nil)
    }

    @Test func yesterdayAndDayBeforeYesterdayUseRelativeDividers() throws {
        let formatter = ChatTimelineFormatter(calendar: calendar, locale: Locale(identifier: "pl_PL"))
        let now = Date(timeIntervalSince1970: 172_800)
        let yesterday = Date(timeIntervalSince1970: 86_400)
        let dayBeforeYesterday = Date(timeIntervalSince1970: 0)

        #expect(formatter.dayDividerTitle(for: yesterday, now: now) == "Wczoraj")
        #expect(formatter.dayDividerTitle(for: dayBeforeYesterday, now: now) == "Przedwczoraj")
    }

    @Test func historyMarkerHasStableIdentity() throws {
        let formatter = ChatTimelineFormatter(calendar: calendar, locale: Locale(identifier: "en_US"))
        let message = ChatMessage(
            role: .assistant,
            text: "After reset",
            createdAt: Date(timeIntervalSince1970: 20)
        )

        let items = formatter.items(
            for: [message],
            hasEarlierMessages: true,
            hasSummarizedEarlierContext: true,
            lastContextResetAt: nil,
            now: Date(timeIntervalSince1970: 20)
        )

        #expect(items.map(\.id).contains("notice-summarized-earlier-context"))
        if case .notice(let notice) = items[0] {
            #expect(notice.title == "Start of available history")
        } else {
            Issue.record("Expected first item to be the history marker.")
        }
        #expect(items.map(\.id).contains("message-\(message.id.uuidString)"))
    }

    @Test func resetEventAfterNewestMessageDoesNotEmitVisibleMarker() throws {
        let formatter = ChatTimelineFormatter(calendar: calendar, locale: Locale(identifier: "en_US"))
        let message = ChatMessage(
            role: .assistant,
            text: "Before reset",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let resetEvent = ConversationEvent(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            kind: .contextReset,
            createdAt: Date(timeIntervalSince1970: 20),
            providerID: AssistantProviderIDs.openAI,
            contextEpochID: UUID()
        )

        let items = formatter.items(
            for: [message],
            hasEarlierMessages: false,
            hasSummarizedEarlierContext: false,
            lastContextResetAt: nil,
            events: [resetEvent],
            now: Date(timeIntervalSince1970: 20)
        )

        #expect(items.map(\.id) == [
            "message-\(message.id.uuidString)"
        ])
    }

    @Test func resetEventBetweenMessagesDoesNotEmitVisibleMarker() throws {
        let formatter = ChatTimelineFormatter(calendar: calendar, locale: Locale(identifier: "en_US"))
        let before = ChatMessage(
            role: .user,
            text: "Before",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let after = ChatMessage(
            role: .assistant,
            text: "After",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let resetEvent = ConversationEvent(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            kind: .contextReset,
            createdAt: Date(timeIntervalSince1970: 20),
            providerID: AssistantProviderIDs.openAI,
            contextEpochID: UUID()
        )

        let items = formatter.items(
            for: [after, before],
            hasEarlierMessages: false,
            hasSummarizedEarlierContext: false,
            lastContextResetAt: nil,
            events: [resetEvent],
            now: Date(timeIntervalSince1970: 30)
        )

        #expect(items.map(\.id) == [
            "message-\(before.id.uuidString)",
            "message-\(after.id.uuidString)"
        ])
    }
}
