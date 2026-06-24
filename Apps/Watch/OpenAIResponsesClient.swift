import Foundation
import WristAssistShared

struct OpenAIResponsesClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func responseText(
        apiKey: String,
        settings: ProviderSettings,
        messages: [ChatMessage]
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OpenAIResponsesRequest(
            model: settings.model,
            instructions: settings.instructions,
            messages: messages
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchOpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WatchOpenAIClientError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        let text = decoded.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WatchOpenAIClientError.emptyResponse
        }

        return text
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
