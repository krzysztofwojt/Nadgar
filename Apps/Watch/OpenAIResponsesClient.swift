import Foundation
import os
import NadgarShared

struct OpenAIResponsesClient: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.nadgar.Nadgar.watchkitapp",
        category: "OpenAIResponsesClient"
    )

    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(
        apiKey: String,
        settings: ProviderSettings,
        input: [OpenAIResponsesInputMessage],
        previousResponseId: String?,
        store: Bool,
        enablesCompaction: Bool = true
    ) async throws -> OpenAIResponsesResult {
        try await send(
            apiKey: apiKey,
            body: OpenAIResponsesRequest(
                model: settings.model,
                instructions: settings.instructions,
                input: input,
                previousResponseId: previousResponseId,
                store: store,
                contextManagement: enablesCompaction ? [OpenAIResponsesContextManagement()] : nil
            )
        )
    }

    func summaryText(
        apiKey: String,
        settings: ProviderSettings,
        currentSummary: String?,
        messages: [ChatMessage]
    ) async throws -> String {
        var input: [OpenAIResponsesInputMessage] = [
            OpenAIResponsesInputMessage(
                role: "system",
                content: """
                Summarize the earlier WristAssist conversation for future context. Keep stable facts, user preferences, unresolved requests, and important decisions. Be concise and do not add new information.
                """
            )
        ]

        if let currentSummary = currentSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentSummary.isEmpty {
            input.append(OpenAIResponsesInputMessage(
                role: "system",
                content: "Existing summary to update:\n\(currentSummary)"
            ))
        }

        input.append(contentsOf: messages.map(OpenAIResponsesInputMessage.init(message:)))

        return try await send(
            apiKey: apiKey,
            body: OpenAIResponsesRequest(
                model: settings.model,
                instructions: nil,
                input: input,
                store: false,
                tools: [],
                toolChoice: "none"
            )
        ).text
    }

    private func send(
        apiKey: String,
        body: OpenAIResponsesRequest
    ) async throws -> OpenAIResponsesResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchOpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WatchOpenAIClientError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        var assistantResponse = decoded.assistantResponse
        let trimmedText = assistantResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw WatchOpenAIClientError.emptyResponse
        }

        if assistantResponse.citations.isEmpty {
            assistantResponse.text = trimmedText
        }

        return OpenAIResponsesResult(response: assistantResponse, responseId: decoded.id)
    }

    func response(
        apiKey: String,
        settings: ProviderSettings,
        messages: [ChatMessage]
    ) async throws -> OpenAIAssistantResponse {
        try await response(
            apiKey: apiKey,
            settings: settings,
            input: messages
                .filter { !$0.isPlaceholder }
                .map(OpenAIResponsesInputMessage.init(message:)),
            previousResponseId: nil,
            store: false,
            enablesCompaction: false
        ).response
    }

    func streamedResponse(
        apiKey: String,
        settings: ProviderSettings,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<OpenAIResponsesStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.request(
                        apiKey: apiKey,
                        settings: settings,
                        messages: messages,
                        stream: true
                    )
                    Self.logger.info("openai response stream request model=\(settings.model, privacy: .public) messageCount=\(messages.filter { !$0.isPlaceholder }.count, privacy: .public)")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw WatchOpenAIClientError.invalidResponse
                    }
                    Self.logger.info("openai response stream httpStatus=\(httpResponse.statusCode, privacy: .public)")

                    guard (200..<300).contains(httpResponse.statusCode) else {
                        let data = try await Self.data(from: bytes)
                        Self.logger.error("openai response stream httpError status=\(httpResponse.statusCode, privacy: .public) responseBytes=\(data.count, privacy: .public)")
                        throw WatchOpenAIClientError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
                    }

                    var parser = OpenAIResponsesSSEParser { summary in
                        Self.logStreamEvent(summary)
                    }
                    for try await line in bytes.lines {
                        for update in try parser.parse(line: line) {
                            continuation.yield(try Self.normalizedStreamingUpdate(update))
                        }
                    }

                    for update in try parser.finish() {
                        continuation.yield(try Self.normalizedStreamingUpdate(update))
                    }
                    Self.logger.info("openai response stream finished")
                    continuation.finish()
                } catch {
                    Self.logger.error("openai response stream failed error=\(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: Self.streamingError(error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func responseText(
        apiKey: String,
        settings: ProviderSettings,
        messages: [ChatMessage]
    ) async throws -> String {
        try await response(apiKey: apiKey, settings: settings, messages: messages).text
    }

    private func request(
        apiKey: String,
        settings: ProviderSettings,
        messages: [ChatMessage],
        stream: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        let body = OpenAIResponsesRequest(
            model: settings.model,
            instructions: settings.instructions,
            messages: messages,
            stream: stream
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func data(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private static func normalizedStreamingUpdate(_ update: OpenAIResponsesStreamUpdate) throws -> OpenAIResponsesStreamUpdate {
        switch update {
        case .textDelta:
            return update
        case .completed(var response):
            let trimmedText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if response.citations.isEmpty {
                response.text = trimmedText
            }
            return .completed(response)
        }
    }

    private static func streamingError(_ error: Error) -> Error {
        if let clientError = error as? WatchOpenAIClientError {
            return clientError
        }

        if let streamError = error as? OpenAIResponsesStreamError {
            switch streamError {
            case .invalidEvent(let message):
                return WatchOpenAIClientError.openAIError(message)
            case .openAIError(let message):
                return WatchOpenAIClientError.openAIError(message)
            }
        }

        return error
    }

    private static func logStreamEvent(_ summary: OpenAIResponsesStreamEventSummary) {
        let responseStatus = summary.responseStatus ?? "-"
        let outputItemTypes = summary.outputItemTypes.isEmpty ? "-" : summary.outputItemTypes.joined(separator: ",")
        let textLength = summary.textLength.map(String.init) ?? "-"

        logger.info("openai response stream event type=\(summary.type, privacy: .public) bytes=\(summary.payloadByteCount, privacy: .public) status=\(responseStatus, privacy: .public) outputTypes=\(outputItemTypes, privacy: .public) textLength=\(textLength, privacy: .public)")
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let decoded = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            if decoded.error.code == "invalid_api_key" ||
                decoded.error.message.hasPrefix("Incorrect API key provided") {
                return "Incorrect API key provided."
            }

            return decoded.error.message
        }

        return String(data: data, encoding: .utf8) ?? "OpenAI returned HTTP \(statusCode)."
    }
}

struct OpenAIResponsesResult: Equatable, Sendable {
    var response: OpenAIAssistantResponse
    var responseId: String?

    var text: String {
        response.text
    }
}

enum WatchOpenAIClientError: LocalizedError, Equatable {
    case invalidResponse
    case openAIError(String)
    case emptyTranscription
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case .openAIError(let message):
            return message
        case .emptyTranscription:
            return "No speech was transcribed."
        case .emptyResponse:
            return "OpenAI returned an empty response."
        }
    }

    var isInvalidPreviousResponseID: Bool {
        guard case .openAIError(let message) = self else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("previous_response_id") ||
            (lowercased.contains("previous response") && (
                lowercased.contains("invalid") ||
                    lowercased.contains("not found") ||
                    lowercased.contains("could not")
            ))
    }
}

protocol AssistantConversationProvider: Sendable {
    var providerID: String { get }

    func respond(apiKey: String, request: AssistantTurnRequest) async throws -> AssistantTurnResult

    func summarizeIfNeeded(
        apiKey: String,
        request: ConversationSummaryRequest
    ) async throws -> ConversationSummaryResult?
}

struct OpenAIResponsesConversationProvider: AssistantConversationProvider {
    let providerID = AssistantProviderIDs.openAI
    var client: OpenAIResponsesClient
    var fallbackContextBuilder: AssistantFallbackContextBuilder

    init(
        client: OpenAIResponsesClient,
        fallbackContextBuilder: AssistantFallbackContextBuilder = AssistantFallbackContextBuilder()
    ) {
        self.client = client
        self.fallbackContextBuilder = fallbackContextBuilder
    }

    func respond(apiKey: String, request: AssistantTurnRequest) async throws -> AssistantTurnResult {
        var providerContext = request.providerContext ?? ProviderContextState(providerID: providerID)

        if !providerContext.requiresLocalHistoryBootstrap,
           let previousResponseID = previousResponseID(in: providerContext) {
            do {
                return try await response(
                    apiKey: apiKey,
                    request: request,
                    input: [OpenAIResponsesInputMessage(message: request.userMessage)],
                    previousResponseId: previousResponseID,
                    providerContext: providerContext
                )
            } catch let error as WatchOpenAIClientError where error.isInvalidPreviousResponseID {
                providerContext = ProviderContextState(providerID: providerContext.providerID)
            }
        }

        return try await response(
            apiKey: apiKey,
            request: request,
            input: fallbackContextInput(for: request),
            previousResponseId: nil,
            providerContext: providerContext
        )
    }

    func summarizeIfNeeded(
        apiKey: String,
        request: ConversationSummaryRequest
    ) async throws -> ConversationSummaryResult? {
        guard !request.messages.isEmpty else { return nil }

        let summary = try await client.summaryText(
            apiKey: apiKey,
            settings: request.settings,
            currentSummary: request.currentSummary,
            messages: request.messages
        )
        return ConversationSummaryResult(
            summary: summary,
            throughMessageID: request.throughMessageID,
            providerContext: request.providerContext
        )
    }

    private func response(
        apiKey: String,
        request: AssistantTurnRequest,
        input: [OpenAIResponsesInputMessage],
        previousResponseId: String?,
        providerContext: ProviderContextState
    ) async throws -> AssistantTurnResult {
        let result = try await client.response(
            apiKey: apiKey,
            settings: request.settings,
            input: input,
            previousResponseId: previousResponseId,
            store: true
        )
        guard let responseID = result.responseId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !responseID.isEmpty
        else {
            throw AssistantProviderError.missingContextID
        }

        var updatedContext = providerContext
        updatedContext.lastRemoteTurnID = responseID
        updatedContext.clearLocalHistoryBootstrapRequirement()

        return AssistantTurnResult(
            response: result.response,
            providerContext: updatedContext
        )
    }

    private func fallbackContextInput(for request: AssistantTurnRequest) -> [OpenAIResponsesInputMessage] {
        let fallbackContext = fallbackContextBuilder.build(for: request)
        var input: [OpenAIResponsesInputMessage] = []

        if let summary = fallbackContext.summary {
            input.append(OpenAIResponsesInputMessage(
                role: "system",
                content: "Earlier conversation summary:\n\(summary)"
            ))
        }

        input.append(contentsOf: fallbackContext.messages.map(OpenAIResponsesInputMessage.init(message:)))
        input.append(OpenAIResponsesInputMessage(message: fallbackContext.userMessage))

        return input
    }

    private func previousResponseID(in providerContext: ProviderContextState) -> String? {
        providerContext.lastRemoteTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
            providerContext.contextID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private struct HermesResponsesRequest: Encodable {
    var model: String
    var instructions: String?
    var input: [OpenAIResponsesInputMessage]
    var conversation: String?
    var store: Bool
    var stream: Bool
}

struct HermesResponsesClient: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.nadgar.Nadgar.watchkitapp",
        category: "HermesResponsesClient"
    )

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(
        apiKey: String,
        profile: ProviderProfile,
        settings: ProviderSettings,
        input: [OpenAIResponsesInputMessage],
        conversation: String?,
        sessionKey: String,
        store: Bool
    ) async throws -> OpenAIResponsesResult {
        guard let endpoint = profile.hermesV1BaseURL?.appendingPathComponent("responses") else {
            throw HermesResponsesClientError.invalidBaseURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        request.httpBody = try JSONEncoder().encode(HermesResponsesRequest(
            model: settings.model,
            instructions: settings.instructions,
            input: input,
            conversation: conversation,
            store: store,
            stream: false
        ))

        Self.logger.info("hermes response request model=\(settings.model, privacy: .public) hasConversation=\((conversation != nil), privacy: .public) inputCount=\(input.count, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchOpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WatchOpenAIClientError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        var assistantResponse = decoded.assistantResponse
        let trimmedText = assistantResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw WatchOpenAIClientError.emptyResponse
        }

        if assistantResponse.citations.isEmpty {
            assistantResponse.text = trimmedText
        }

        return OpenAIResponsesResult(response: assistantResponse, responseId: decoded.id)
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let decoded = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            return decoded.error.message
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw! : "Hermes returned HTTP \(statusCode)."
    }
}

enum HermesResponsesClientError: LocalizedError, Equatable {
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Hermes URL must be HTTPS and point to a pure Hermes API server."
        }
    }
}

struct HermesResponsesConversationProvider: AssistantConversationProvider {
    var providerID: String
    var profile: ProviderProfile
    var client: HermesResponsesClient
    var fallbackContextBuilder: AssistantFallbackContextBuilder

    init(
        profile: ProviderProfile,
        providerID: String,
        client: HermesResponsesClient,
        fallbackContextBuilder: AssistantFallbackContextBuilder = AssistantFallbackContextBuilder()
    ) {
        self.profile = profile
        self.providerID = providerID
        self.client = client
        self.fallbackContextBuilder = fallbackContextBuilder
    }

    func respond(apiKey: String, request: AssistantTurnRequest) async throws -> AssistantTurnResult {
        var providerContext = request.providerContext ?? ProviderContextState(providerID: providerID)
        let shouldBootstrap = providerContext.requiresLocalHistoryBootstrap ||
            providerContext.lastRemoteTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        let input = shouldBootstrap ? fallbackContextInput(for: request) : [
            OpenAIResponsesInputMessage(message: request.userMessage)
        ]
        let conversationName = conversationName(for: request)
        let result = try await client.response(
            apiKey: apiKey,
            profile: profile,
            settings: request.settings,
            input: input,
            conversation: conversationName,
            sessionKey: sessionKey(for: request),
            store: true
        )

        providerContext.providerID = providerID
        providerContext.contextID = conversationName
        providerContext.lastRemoteTurnID = result.responseId
        providerContext.clearLocalHistoryBootstrapRequirement()
        return AssistantTurnResult(response: result.response, providerContext: providerContext)
    }

    func summarizeIfNeeded(
        apiKey: String,
        request: ConversationSummaryRequest
    ) async throws -> ConversationSummaryResult? {
        guard !request.messages.isEmpty else { return nil }

        var input: [OpenAIResponsesInputMessage] = [
            OpenAIResponsesInputMessage(
                role: "system",
                content: """
                Summarize the earlier Nadgar conversation for future context. Keep stable facts, user preferences, unresolved requests, and important decisions. Be concise and do not add new information.
                """
            )
        ]
        if let currentSummary = request.currentSummary {
            input.append(OpenAIResponsesInputMessage(
                role: "system",
                content: "Existing summary to update:\n\(currentSummary)"
            ))
        }
        input.append(contentsOf: request.messages.map(OpenAIResponsesInputMessage.init(message:)))

        let result = try await client.response(
            apiKey: apiKey,
            profile: profile,
            settings: request.settings,
            input: input,
            conversation: nil,
            sessionKey: "\(sessionKey(for: request)):summary",
            store: false
        )
        return ConversationSummaryResult(
            summary: result.text,
            throughMessageID: request.throughMessageID,
            providerContext: request.providerContext
        )
    }

    private func fallbackContextInput(for request: AssistantTurnRequest) -> [OpenAIResponsesInputMessage] {
        let fallbackContext = fallbackContextBuilder.build(for: request)
        var input: [OpenAIResponsesInputMessage] = []

        if let summary = fallbackContext.summary {
            input.append(OpenAIResponsesInputMessage(
                role: "system",
                content: "Earlier conversation summary:\n\(summary)"
            ))
        }

        input.append(contentsOf: fallbackContext.messages.map(OpenAIResponsesInputMessage.init(message:)))
        input.append(OpenAIResponsesInputMessage(message: fallbackContext.userMessage))
        return input
    }

    private func conversationName(for request: AssistantTurnRequest) -> String {
        "nadgar:\(profile.id):\(modelKey(for: request.settings)):\(request.conversationKey):\(request.contextEpochID.uuidString.lowercased())"
    }

    private func sessionKey(for request: AssistantTurnRequest) -> String {
        "nadgar:\(profile.id):\(modelKey(for: request.settings)):\(request.conversationKey)"
    }

    private func sessionKey(for request: ConversationSummaryRequest) -> String {
        "nadgar:\(profile.id):\(modelKey(for: request.settings)):\(request.conversationKey)"
    }

    private func modelKey(for settings: ProviderSettings) -> String {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "default" : model
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
