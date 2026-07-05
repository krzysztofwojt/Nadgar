import Foundation
import NadgarShared

@main
struct WristAssistSessionE2ETests {
    static func main() async {
        do {
            let configuration = try E2EConfiguration.fromEnvironment()
            let runner = E2ERunner(configuration: configuration)
            try await runner.run()
            print("PASS all E2E scenarios")
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct E2EConfiguration {
    var apiKey: String
    var model: String
    var endpoint: URL

    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> E2EConfiguration {
        let apiKey = try apiKey(from: environment)
        let model = environment["WRISTASSIST_E2E_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "gpt-5.4-nano"
        let endpoint = URL(string: environment["OPENAI_RESPONSES_URL"] ?? "https://api.openai.com/v1/responses")!

        return E2EConfiguration(apiKey: apiKey, model: model, endpoint: endpoint)
    }

    private static func apiKey(from environment: [String: String]) throws -> String {
        if let value = environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            return value
        }

        let keyFile = environment["OPENAI_API_KEY_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "/private/tmp/wristassist-openai-api-key"
        let fileURL = URL(fileURLWithPath: keyFile)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw E2EError.missingAPIKeyFile(fileURL.path)
        }

        let value = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw E2EError.emptyAPIKeyFile(fileURL.path)
        }

        return value
    }
}

private struct E2ERunner {
    var configuration: E2EConfiguration
    var client: LiveResponsesClient
    var fallbackBuilder: AssistantFallbackContextBuilder

    init(configuration: E2EConfiguration) {
        self.configuration = configuration
        self.client = LiveResponsesClient(endpoint: configuration.endpoint)
        self.fallbackBuilder = AssistantFallbackContextBuilder(maxApproxTokens: 900, summaryMaxApproxTokens: 120)
    }

    func run() async throws {
        print("Using model: \(configuration.model)")
        try await invalidContextFallbackAndChain()
        try await summaryRecovery()
        try await resetStartsCleanConversation()
    }

    private func invalidContextFallbackAndChain() async throws {
        let epochID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        var record = WatchConversationRecord(contextEpochID: epochID)
        for index in 0..<60 {
            record.appendMessage(ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "short e2e \(index)",
                createdAt: baseDate.addingTimeInterval(TimeInterval(index))
            ))
        }

        let userMessage = ChatMessage(
            role: .user,
            text: "E2E recovery check. Reply only: RECOVERY_OK",
            createdAt: baseDate.addingTimeInterval(100)
        )

        let invalidRequest = request(
            input: [OpenAIResponsesInputMessage(message: userMessage)],
            previousResponseId: "resp_wristassist_invalid_e2e_context",
            store: true
        )
        do {
            _ = try await client.send(apiKey: configuration.apiKey, request: invalidRequest)
            throw E2EError.invalidContextWasAccepted
        } catch let error as LiveResponsesError where error.isInvalidPreviousResponseID {
            print("PASS E2E-001a invalid previous_response_id rejected")
        }

        let turnRequest = AssistantTurnRequest(
            conversationKey: WatchConversationRecord.defaultConversationKey,
            contextEpochID: record.contextEpochID,
            providerContext: ProviderContextState(
                providerID: AssistantProviderIDs.openAI,
                lastRemoteTurnID: "resp_wristassist_invalid_e2e_context"
            ),
            userMessage: userMessage,
            recentMessages: record.currentEpochRawRecoveryMessages,
            humanSummary: nil,
            settings: ProviderSettings(hasAPIKey: true)
        )
        let fallback = fallbackBuilder.build(for: turnRequest)
        try require(fallback.messages.count > 24, "fallback should include more than 24 short raw messages")
        try require(fallback.messages.first?.text == "short e2e 0", "fallback should keep chronological order")
        try require(!fallback.messages.contains { $0.id == userMessage.id }, "fallback must not duplicate current user message")

        let recovery = try await client.send(
            apiKey: configuration.apiKey,
            request: request(input: fallbackInput(from: fallback), store: true)
        )
        try requireNonEmpty(recovery.id, "fallback response id")
        try requireNonEmpty(recovery.assistantText, "fallback response text")
        print("PASS E2E-001b fallback used \(fallback.messages.count) raw messages and returned \(shortID(recovery.id))")

        let followUp = ChatMessage(
            role: .user,
            text: "Reply only: CHAIN_OK",
            createdAt: baseDate.addingTimeInterval(101)
        )
        let chained = try await client.send(
            apiKey: configuration.apiKey,
            request: request(
                input: [OpenAIResponsesInputMessage(message: followUp)],
                previousResponseId: recovery.id,
                store: true
            )
        )
        try requireNonEmpty(chained.id, "chained response id")
        try requireNonEmpty(chained.assistantText, "chained response text")
        print("PASS E2E-001c chained request returned \(shortID(chained.id))")
    }

    private func summaryRecovery() async throws {
        let epochID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_800_010_000)
        var record = WatchConversationRecord(contextEpochID: epochID)
        for index in 0..<84 {
            record.appendMessage(ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "compact e2e \(index)",
                createdAt: baseDate.addingTimeInterval(TimeInterval(index))
            ))
        }

        let messagesToSummarize = Array(record.currentEpochMessages.prefix(12))
        guard let throughMessageID = messagesToSummarize.last?.id else {
            throw E2EError.assertionFailed("summary fixture should have messages")
        }

        let summaryResponse = try await client.send(
            apiKey: configuration.apiKey,
            request: request(
                instructions: nil,
                input: summaryInput(messages: messagesToSummarize),
                store: false,
                enablesCompaction: false
            )
        )
        let summary = try requireNonEmpty(summaryResponse.assistantText, "summary text")
        record.markSummarized(summary: summary, through: throughMessageID)

        let userMessage = ChatMessage(
            role: .user,
            text: "E2E summary recovery check. Reply only: SUMMARY_OK",
            createdAt: baseDate.addingTimeInterval(100)
        )
        let turnRequest = AssistantTurnRequest(
            conversationKey: WatchConversationRecord.defaultConversationKey,
            contextEpochID: record.contextEpochID,
            providerContext: nil,
            userMessage: userMessage,
            recentMessages: record.currentEpochRawRecoveryMessages,
            humanSummary: record.humanSummaryForCurrentEpoch,
            summaryThroughMessageId: record.summaryThroughMessageIdForCurrentEpoch,
            settings: ProviderSettings(hasAPIKey: true)
        )
        let fallback = fallbackBuilder.build(for: turnRequest)
        try require(fallback.summary != nil, "fallback should include summary after compaction")
        try require(!fallback.messages.contains { messagesToSummarize.map(\.id).contains($0.id) }, "fallback should not duplicate summarized messages")

        let response = try await client.send(
            apiKey: configuration.apiKey,
            request: request(input: fallbackInput(from: fallback), store: true)
        )
        try requireNonEmpty(response.id, "summary recovery response id")
        try requireNonEmpty(response.assistantText, "summary recovery response text")
        print("PASS E2E-002 summary plus \(fallback.messages.count) raw messages returned \(shortID(response.id))")
    }

    private func resetStartsCleanConversation() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_020_000)
        var record = WatchConversationRecord(
            providerContexts: [
                AssistantProviderIDs.openAI: ProviderContextState(
                    providerID: AssistantProviderIDs.openAI,
                    lastRemoteTurnID: "resp_old_context"
                )
            ],
            humanSummary: "Old summary that must not leak.",
            messages: [
                ChatMessage(role: .user, text: "old user", createdAt: baseDate),
                ChatMessage(role: .assistant, text: "old assistant", createdAt: baseDate.addingTimeInterval(1))
            ]
        )
        record.clearHistory()
        try require(record.messages.isEmpty, "clear history should remove messages")
        try require(record.humanSummary == nil, "clear history should remove summary")
        try require(record.providerContexts.isEmpty, "clear history should remove provider contexts")
        try require(record.events.isEmpty, "clear history should remove reset events")

        let userMessage = ChatMessage(
            role: .user,
            text: "Fresh E2E after reset. Reply only: RESET_OK",
            createdAt: baseDate.addingTimeInterval(10)
        )
        let turnRequest = AssistantTurnRequest(
            conversationKey: WatchConversationRecord.defaultConversationKey,
            contextEpochID: record.contextEpochID,
            providerContext: nil,
            userMessage: userMessage,
            recentMessages: record.currentEpochRawRecoveryMessages,
            humanSummary: record.humanSummaryForCurrentEpoch,
            settings: ProviderSettings(hasAPIKey: true)
        )
        let fallback = fallbackBuilder.build(for: turnRequest)
        try require(fallback.summary == nil, "reset fallback should not include old summary")
        try require(fallback.messages.isEmpty, "reset fallback should not include old raw messages")

        let response = try await client.send(
            apiKey: configuration.apiKey,
            request: request(input: fallbackInput(from: fallback), store: true)
        )
        try requireNonEmpty(response.id, "reset response id")
        try requireNonEmpty(response.assistantText, "reset response text")
        print("PASS E2E-003 reset starts clean conversation and returned \(shortID(response.id))")
    }

    private func summaryInput(messages: [ChatMessage]) -> [OpenAIResponsesInputMessage] {
        [
            OpenAIResponsesInputMessage(
                role: "system",
                content: "Summarize this WristAssist test conversation in one short sentence."
            )
        ] + messages.map(OpenAIResponsesInputMessage.init(message:))
    }

    private func fallbackInput(from context: AssistantFallbackContext) -> [OpenAIResponsesInputMessage] {
        var input: [OpenAIResponsesInputMessage] = []
        if let summary = context.summary {
            input.append(OpenAIResponsesInputMessage(
                role: "system",
                content: "Earlier conversation summary:\n\(summary)"
            ))
        }
        input.append(contentsOf: context.messages.map(OpenAIResponsesInputMessage.init(message:)))
        input.append(OpenAIResponsesInputMessage(message: context.userMessage))
        return input
    }

    private func request(
        instructions: String? = "You are a low-cost WristAssist E2E test responder. Follow the requested exact output and keep every answer under 8 words.",
        input: [OpenAIResponsesInputMessage],
        previousResponseId: String? = nil,
        store: Bool,
        enablesCompaction: Bool = true
    ) -> OpenAIResponsesRequest {
        OpenAIResponsesRequest(
            model: configuration.model,
            instructions: instructions,
            input: input,
            previousResponseId: previousResponseId,
            store: store,
            contextManagement: enablesCompaction ? [OpenAIResponsesContextManagement()] : nil,
            tools: [],
            toolChoice: "none"
        )
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw E2EError.assertionFailed(message) }
    }

    @discardableResult
    private func requireNonEmpty(_ value: String?, _ label: String) throws -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw E2EError.assertionFailed("\(label) should not be empty") }
        return trimmed
    }

    private func shortID(_ id: String?) -> String {
        guard let id, id.count > 12 else { return id ?? "<nil>" }
        return "\(id.prefix(12))..."
    }
}

private struct LiveResponsesClient {
    var endpoint: URL
    var session: URLSession = .shared

    func send(apiKey: String, request body: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveResponsesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LiveResponsesError.openAIError(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data, statusCode: httpResponse.statusCode)
            )
        }

        return try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let decoded = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            return decoded.error.message
        }

        return String(data: data, encoding: .utf8) ?? "OpenAI returned HTTP \(statusCode)."
    }
}

private enum LiveResponsesError: LocalizedError, Equatable {
    case invalidResponse
    case openAIError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case .openAIError(let statusCode, let message):
            return "OpenAI returned HTTP \(statusCode): \(message)"
        }
    }

    var isInvalidPreviousResponseID: Bool {
        guard case .openAIError(_, let message) = self else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("previous_response_id") ||
            (lowercased.contains("previous response") && (
                lowercased.contains("invalid") ||
                    lowercased.contains("not found") ||
                    lowercased.contains("could not")
            ))
    }
}

private enum E2EError: LocalizedError, Equatable {
    case missingAPIKeyFile(String)
    case emptyAPIKeyFile(String)
    case invalidContextWasAccepted
    case assertionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKeyFile(let path):
            return "Missing API key. Set OPENAI_API_KEY or write the key to \(path)."
        case .emptyAPIKeyFile(let path):
            return "API key file is empty: \(path)."
        case .invalidContextWasAccepted:
            return "Invalid previous_response_id was unexpectedly accepted."
        case .assertionFailed(let message):
            return message
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
