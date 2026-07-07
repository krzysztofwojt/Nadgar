import Foundation
import NadgarShared

protocol OpenAIAPIKeyValidating: Sendable {
    func validateAPIKey(apiKey: String, model: String) async throws
}

protocol HermesAPIKeyValidating: Sendable {
    func validateAPIKey(apiKey: String, baseURL: String) async throws -> [String]
}

protocol ProviderResponseTesting: Sendable {
    func testResponse(
        apiKey: String,
        profile: ProviderProfile,
        model: String,
        instructions: String?,
        prompt: String
    ) async throws -> String
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

struct HermesAPIKeyValidationService: HermesAPIKeyValidating {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateAPIKey(apiKey: String, baseURL: String) async throws -> [String] {
        guard let v1BaseURL = ProviderProfile.hermesV1BaseURL(from: baseURL) else {
            throw HermesAPIValidationError.invalidBaseURL
        }

        var request = URLRequest(url: v1BaseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HermesAPIValidationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HermesAPIValidationError.hermesError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let decoded: HermesModelsResponse
        do {
            decoded = try JSONDecoder().decode(HermesModelsResponse.self, from: data)
        } catch {
            throw HermesAPIValidationError.invalidResponse
        }

        guard !decoded.modelIDs.isEmpty else {
            throw HermesAPIValidationError.noModels
        }

        return decoded.modelIDs
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

struct ProviderResponseTestService: ProviderResponseTesting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testResponse(
        apiKey: String,
        profile: ProviderProfile,
        model: String,
        instructions: String?,
        prompt: String
    ) async throws -> String {
        switch profile.type {
        case .openAI:
            return try await testOpenAIResponse(
                apiKey: apiKey,
                model: model,
                instructions: instructions,
                prompt: prompt
            )
        case .hermes:
            return try await testHermesResponse(
                apiKey: apiKey,
                profile: profile,
                model: model,
                instructions: instructions,
                prompt: prompt
            )
        case .custom:
            throw ProviderResponseTestError.unsupportedProvider
        }
    }

    private func testOpenAIResponse(
        apiKey: String,
        model: String,
        instructions: String?,
        prompt: String
    ) async throws -> String {
        guard let endpoint = URL(string: "https://api.openai.com/v1/responses") else {
            throw ProviderResponseTestError.invalidResponseEndpoint
        }

        let body = OpenAIResponsesRequest(
            model: model,
            instructions: instructions,
            input: [OpenAIResponsesInputMessage(role: .user, content: prompt)],
            store: false,
            tools: [],
            toolChoice: "none",
            stream: false
        )

        return try await sendResponseRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            body: body,
            sessionKey: nil,
            providerName: "OpenAI"
        )
    }

    private func testHermesResponse(
        apiKey: String,
        profile: ProviderProfile,
        model: String,
        instructions: String?,
        prompt: String
    ) async throws -> String {
        guard let endpoint = profile.hermesV1BaseURL?.appendingPathComponent("responses") else {
            throw ProviderResponseTestError.invalidResponseEndpoint
        }

        let sessionKey = "nadgar-response-test-\(UUID().uuidString)"
        let body = HermesResponseTestRequest(
            model: model,
            instructions: instructions,
            input: [OpenAIResponsesInputMessage(role: .user, content: prompt)],
            conversation: sessionKey,
            store: false,
            stream: false
        )

        return try await sendResponseRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            body: body,
            sessionKey: sessionKey,
            providerName: "Hermes"
        )
    }

    private func sendResponseRequest<Body: Encodable>(
        endpoint: URL,
        apiKey: String,
        body: Body,
        sessionKey: String?,
        providerName: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionKey {
            request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderResponseTestError.invalidResponse(providerName)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ProviderResponseTestError.providerError(Self.errorMessage(
                from: data,
                statusCode: httpResponse.statusCode,
                providerName: providerName
            ))
        }

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        let text = decoded.assistantResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProviderResponseTestError.emptyResponse(providerName)
        }

        return text
    }

    private static func errorMessage(from data: Data, statusCode: Int, providerName: String) -> String {
        if let decoded = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            return decoded.error.message
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw! : "\(providerName) returned HTTP \(statusCode)."
    }
}

private struct HermesResponseTestRequest: Encodable {
    var model: String
    var instructions: String?
    var input: [OpenAIResponsesInputMessage]
    var conversation: String
    var store: Bool
    var stream: Bool
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

enum ProviderResponseTestError: LocalizedError, Equatable {
    case invalidResponseEndpoint
    case invalidResponse(String)
    case emptyResponse(String)
    case providerError(String)
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .invalidResponseEndpoint:
            return "Response endpoint is not configured."
        case .invalidResponse(let providerName):
            return "\(providerName) returned an invalid response."
        case .emptyResponse(let providerName):
            return "\(providerName) returned an empty response."
        case .providerError(let message):
            return message
        case .unsupportedProvider:
            return "This provider does not support response tests yet."
        }
    }
}

enum HermesAPIValidationError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case noModels
    case hermesError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Hermes URL must be HTTPS and point to a pure Hermes API server."
        case .invalidResponse:
            return "Hermes returned an invalid response."
        case .noModels:
            return "Hermes did not return any response models."
        case .hermesError(let message):
            return message
        }
    }
}
