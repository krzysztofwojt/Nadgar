import Foundation
import WristAssistShared

protocol OpenAIAPIKeyValidating: Sendable {
    func validateAPIKey(apiKey: String, model: String) async throws
}

struct OpenAIAPIKeyValidationService: OpenAIAPIKeyValidating {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateAPIKey(apiKey: String, model: String) async throws {
        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://api.openai.com/v1/models/\(encodedModel)")
        else {
            throw APIKeyValidationError.invalidModel
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIKeyValidationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIKeyValidationError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }
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

enum APIKeyValidationError: LocalizedError, Equatable {
    case invalidModel
    case invalidResponse
    case openAIError(String)

    var errorDescription: String? {
        switch self {
        case .invalidModel:
            return "OpenAI model name is invalid."
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case .openAIError(let message):
            return message
        }
    }
}
