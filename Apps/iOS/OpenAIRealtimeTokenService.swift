import Foundation
import WristAssistShared

protocol OpenAIRealtimeTokenServing: Sendable {
    func createClientSecret(apiKey: String, settings: ProviderSettings, safetyIdentifier: String) async throws -> String
}

struct OpenAIRealtimeTokenService: OpenAIRealtimeTokenServing {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func createClientSecret(apiKey: String, settings: ProviderSettings, safetyIdentifier: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.httpBody = try RealtimeJSON.encoder.encode(RealtimeSessionConfiguration(settings: settings))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TokenServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TokenServiceError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let decoded = try RealtimeJSON.decoder.decode(RealtimeClientSecretResponse.self, from: data)
        return decoded.value
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let decoded = try? RealtimeJSON.decoder.decode(OpenAIErrorResponse.self, from: data) {
            if decoded.error.code == "invalid_api_key" ||
                decoded.error.message.hasPrefix("Incorrect API key provided") {
                return "Incorrect API key provided"
            }

            return SecretRedactor.redact(decoded.error.message)
        }

        return SecretRedactor.redact(String(data: data, encoding: .utf8) ?? "OpenAI returned HTTP \(statusCode).")
    }
}

private struct OpenAIErrorResponse: Decodable {
    let error: OpenAIErrorPayload
}

private struct OpenAIErrorPayload: Decodable {
    let message: String
    let code: String?
}

enum TokenServiceError: LocalizedError, Equatable {
    case invalidResponse
    case openAIError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case .openAIError(let message):
            return message
        }
    }
}
