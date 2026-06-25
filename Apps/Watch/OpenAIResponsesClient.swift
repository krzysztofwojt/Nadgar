import Foundation
import os
import WristAssistShared

struct OpenAIResponsesClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
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
        messages: [ChatMessage]
    ) async throws -> OpenAIAssistantResponse {
        let request = try request(
            apiKey: apiKey,
            settings: settings,
            messages: messages,
            stream: false
        )

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

        return assistantResponse
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
}
