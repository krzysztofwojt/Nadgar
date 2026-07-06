import Foundation

public enum ChatTimelineItem: Equatable, Identifiable, Sendable {
    case notice(ChatTimelineNotice)
    case dayDivider(ChatTimelineDayDivider)
    case message(ChatTimelineMessage)

    public var id: String {
        switch self {
        case .notice(let notice):
            return notice.id
        case .dayDivider(let divider):
            return divider.id
        case .message(let message):
            return message.id
        }
    }
}

public struct ChatTimelineNotice: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ChatTimelineDayDivider: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ChatTimelineMessage: Equatable, Identifiable, Sendable {
    public var id: String
    public var message: ChatMessage
    public var userTimestamp: String?

    public init(message: ChatMessage, userTimestamp: String?) {
        self.id = "message-\(message.id.uuidString)"
        self.message = message
        self.userTimestamp = userTimestamp
    }
}

public struct ChatTimelineFormatter: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    public func items(
        for messages: [ChatMessage],
        hasEarlierMessages: Bool,
        hasSummarizedEarlierContext: Bool,
        lastContextResetAt _: Date?,
        events _: [ConversationEvent] = [],
        now: Date = Date()
    ) -> [ChatTimelineItem] {
        let sortedMessages = messages.sorted { $0.createdAt < $1.createdAt }
        var items: [ChatTimelineItem] = []

        if hasSummarizedEarlierContext {
            items.append(.notice(ChatTimelineNotice(
                id: "notice-summarized-earlier-context",
                title: "Start of available history"
            )))
        } else if hasEarlierMessages {
            items.append(.notice(ChatTimelineNotice(
                id: "notice-earlier-messages-not-shown",
                title: "Start of available history"
            )))
        }

        var emittedDayStarts = Set<Date>()

        for message in sortedMessages {
            let dayStart = calendar.startOfDay(for: message.createdAt)
            if !emittedDayStarts.contains(dayStart) {
                emittedDayStarts.insert(dayStart)
                if let title = dayDividerTitle(for: message.createdAt, now: now) {
                    items.append(.dayDivider(ChatTimelineDayDivider(
                        id: "day-\(Int(dayStart.timeIntervalSince1970))",
                        title: title
                    )))
                }
            }

            items.append(.message(ChatTimelineMessage(
                message: message,
                userTimestamp: message.role == .user ? timeString(for: message.createdAt) : nil
            )))
        }

        return items
    }

    public func dayDividerTitle(for date: Date, now: Date = Date()) -> String? {
        if calendar.isDate(date, inSameDayAs: now) {
            return nil
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return localized("Yesterday", polish: "Wczoraj")
        }

        if let dayBeforeYesterday = calendar.date(byAdding: .day, value: -2, to: now),
           calendar.isDate(date, inSameDayAs: dayBeforeYesterday)
        {
            return localized("Day before yesterday", polish: "Przedwczoraj")
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "d MMMM" : "d MMMM yyyy"
        )
        return formatter.string(from: date)
    }

    public func timeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func localized(_ english: String, polish: String) -> String {
        locale.identifier.lowercased().hasPrefix("pl") ? polish : english
    }
}
