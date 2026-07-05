import Foundation
import Testing
@testable import NadgarShared

struct WatchConversationStoreTests {
    @Test func missingFileLoadsEmptyConversation() throws {
        let store = WatchConversationStore(fileURL: temporaryFileURL())

        let record = try store.load()

        #expect(record.conversationKey == WatchConversationRecord.defaultConversationKey)
        #expect(record.schemaVersion == WatchConversationRecord.currentSchemaVersion)
        #expect(record.activeProviderID == AssistantProviderIDs.openAI)
        #expect(record.providerContexts.isEmpty)
        #expect(record.events.isEmpty)
        #expect(record.messages.isEmpty)
    }

    @Test func saveLoadPreservesConversationState() throws {
        let store = WatchConversationStore(fileURL: temporaryFileURL())
        let contextEpochID = UUID()
        let message = ChatMessage(
            id: UUID(),
            role: .user,
            text: "Cześć",
            createdAt: Date(timeIntervalSince1970: 10),
            contextEpochID: contextEpochID
        )
        let providerContext = ProviderContextState(
            providerID: AssistantProviderIDs.openAI,
            lastRemoteTurnID: "resp_123"
        )
        let resetEvent = ConversationEvent(
            id: UUID(),
            kind: .contextReset,
            createdAt: Date(timeIntervalSince1970: 20),
            providerID: AssistantProviderIDs.openAI,
            contextEpochID: contextEpochID
        )
        let record = WatchConversationRecord(
            contextEpochID: contextEpochID,
            providerContexts: [AssistantProviderIDs.openAI: providerContext],
            humanSummary: "Earlier summary",
            summaryThroughMessageId: message.id,
            lastContextResetAt: Date(timeIntervalSince1970: 20),
            events: [resetEvent],
            messages: [message]
        )

        try store.save(record)
        let loaded = try store.load()

        #expect(loaded == record)
    }

    @Test func legacyLastResponseIdMigratesIntoOpenAIProviderContext() throws {
        let data = """
        {
          "conversationKey": "default",
          "lastResponseId": "resp_legacy",
          "messages": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WatchConversationRecord.self, from: data)

        #expect(decoded.schemaVersion == WatchConversationRecord.currentSchemaVersion)
        #expect(decoded.providerContexts[AssistantProviderIDs.openAI]?.lastRemoteTurnID == "resp_legacy")

        let reencoded = try JSONEncoder().encode(decoded)
        let reencodedString = try #require(String(data: reencoded, encoding: .utf8))
        #expect(!reencodedString.contains("lastResponseId"))
    }

    @Test func legacyMessagesWithoutEpochAdoptCurrentEpoch() throws {
        let messageID = UUID()
        let data = """
        {
          "conversationKey": "default",
          "contextEpochID": "11111111-1111-1111-1111-111111111111",
          "messages": [
            {
              "id": "\(messageID.uuidString)",
              "role": "user",
              "text": "Legacy",
              "createdAt": 10,
              "isPlaceholder": false,
              "citations": []
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WatchConversationRecord.self, from: data)

        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0].contextEpochID == decoded.contextEpochID)
        #expect(decoded.currentEpochRawRecoveryMessages.map(\.id) == [messageID])
    }

    @Test func displayWindowAndRawRecoveryTailUseSeparateLimits() throws {
        let messages = makeMessages(count: 100)
        let record = WatchConversationRecord(messages: messages)

        #expect(record.displayMessages.count == StandalonePTTDefaults.visibleMessagesLimit)
        #expect(record.rawRecoveryMessages.count == StandalonePTTDefaults.rawRecoveryMessagesLimit)
        #expect(record.displayMessages.first?.text == "Message 60")
        #expect(record.rawRecoveryMessages.first?.text == "Message 20")
    }

    @Test func appendMessageAssignsCurrentEpochAndRotateStartsEmptyCurrentEpochTail() throws {
        var record = WatchConversationRecord()
        let originalEpoch = record.contextEpochID
        record.appendMessage(ChatMessage(role: .user, text: "Before reset", createdAt: Date(timeIntervalSince1970: 1)))

        record.rotateModelContext(at: Date(timeIntervalSince1970: 2))
        let rotatedEpoch = record.contextEpochID
        record.appendMessage(ChatMessage(role: .user, text: "After reset", createdAt: Date(timeIntervalSince1970: 3)))

        #expect(originalEpoch != rotatedEpoch)
        #expect(record.messages.map(\.text) == ["Before reset", "After reset"])
        #expect(record.messages.first?.contextEpochID == originalEpoch)
        #expect(record.messages.last?.contextEpochID == rotatedEpoch)
        #expect(record.currentEpochRawRecoveryMessages.map(\.text) == ["After reset"])
    }

    @Test func summaryForCurrentEpochIsHiddenAfterContextRotate() throws {
        var record = WatchConversationRecord()
        let message = ChatMessage(role: .user, text: "Before", createdAt: Date(timeIntervalSince1970: 1))
        record.appendMessage(message)
        record.markSummarized(summary: "Old summary", through: message.id)

        #expect(record.humanSummaryForCurrentEpoch == "Old summary")

        record.rotateModelContext(at: Date(timeIntervalSince1970: 2))

        #expect(record.humanSummary == "Old summary")
        #expect(record.humanSummaryForCurrentEpoch == nil)
        #expect(record.summaryThroughMessageIdForCurrentEpoch == nil)
    }

    @Test func markSummarizedPrunesMessagesToStoredLimit() throws {
        let messages = makeMessages(count: 100)
        let throughID = messages[19].id
        var record = WatchConversationRecord(messages: messages)

        record.markSummarized(summary: "Summary", through: throughID)

        #expect(record.humanSummary == "Summary")
        #expect(record.summaryThroughMessageId == throughID)
        #expect(record.messages.count == StandalonePTTDefaults.rawRecoveryMessagesLimit)
        #expect(record.messages.first?.text == "Message 20")
    }

    @Test func markSummarizedRemovesOnlySummarizedEpochMessages() throws {
        let oldEpoch = UUID()
        let newEpoch = UUID()
        let oldMessage = ChatMessage(
            role: .user,
            text: "Old epoch",
            createdAt: Date(timeIntervalSince1970: 1),
            contextEpochID: oldEpoch
        )
        let newMessage1 = ChatMessage(
            role: .user,
            text: "New 1",
            createdAt: Date(timeIntervalSince1970: 2),
            contextEpochID: newEpoch
        )
        let newMessage2 = ChatMessage(
            role: .assistant,
            text: "New 2",
            createdAt: Date(timeIntervalSince1970: 3),
            contextEpochID: newEpoch
        )
        var record = WatchConversationRecord(
            contextEpochID: newEpoch,
            messages: [oldMessage, newMessage1, newMessage2]
        )

        record.markSummarized(summary: "Summary", through: newMessage1.id)

        #expect(record.messages.map(\.text) == ["Old epoch", "New 2"])
        #expect(record.summaryContextEpochID == newEpoch)
        #expect(record.humanSummaryForCurrentEpoch == "Summary")
    }

    @Test func clearHistoryRemovesMessagesSummaryProviderContextAndChangesEpoch() throws {
        let originalEpoch = UUID()
        let providerContext = ProviderContextState(
            providerID: AssistantProviderIDs.openAI,
            lastRemoteTurnID: "resp_old"
        )
        let message = ChatMessage(
            role: .user,
            text: "Before clear",
            contextEpochID: originalEpoch
        )
        var record = WatchConversationRecord(
            contextEpochID: originalEpoch,
            providerContexts: [AssistantProviderIDs.openAI: providerContext],
            humanSummary: "Old summary",
            summaryThroughMessageId: message.id,
            summaryContextEpochID: originalEpoch,
            lastContextResetAt: Date(timeIntervalSince1970: 1),
            events: [
                ConversationEvent(
                    kind: .contextReset,
                    createdAt: Date(timeIntervalSince1970: 1),
                    providerID: AssistantProviderIDs.openAI,
                    contextEpochID: originalEpoch
                )
            ],
            messages: [message]
        )

        record.clearHistory()

        #expect(record.contextEpochID != originalEpoch)
        #expect(record.messages.isEmpty)
        #expect(record.humanSummary == nil)
        #expect(record.humanSummaryForCurrentEpoch == nil)
        #expect(record.summaryThroughMessageId == nil)
        #expect(record.summaryContextEpochID == nil)
        #expect(record.providerContexts.isEmpty)
        #expect(record.events.isEmpty)
        #expect(record.lastContextResetAt == nil)
    }

    @Test func invalidJSONThrowsInsteadOfLoadingEmptyConversation() throws {
        let fileURL = temporaryFileURL()
        try Data("not json".utf8).write(to: fileURL)
        let store = WatchConversationStore(fileURL: fileURL)

        do {
            _ = try store.load()
            Issue.record("Expected invalid JSON load to throw.")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test func hardLimitFailureDoesNotOverwriteExistingSnapshot() throws {
        let store = WatchConversationStore(fileURL: temporaryFileURL())
        let validRecord = WatchConversationRecord(messages: [
            ChatMessage(role: .user, text: "Keep me")
        ])
        try store.save(validRecord)

        let tooLargeRecord = WatchConversationRecord(messages: [
            ChatMessage(
                role: .user,
                text: String(
                    repeating: "x",
                    count: StandalonePTTDefaults.conversationJSONHardCapBytes + 1
                )
            )
        ])

        do {
            try store.save(tooLargeRecord)
            Issue.record("Expected oversized record save to throw.")
        } catch let error as WatchConversationStoreError {
            if case .recordTooLarge = error {
                // Expected path.
            } else {
                Issue.record("Unexpected store error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try store.load() == validRecord)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    private func makeMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: UUID(),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "Message \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }
}
