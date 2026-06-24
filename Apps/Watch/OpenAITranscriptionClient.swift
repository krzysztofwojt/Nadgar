import Foundation
import os
import WristAssistShared

struct OpenAITranscriptionClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
        category: "OpenAITranscriptionClient"
    )

    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        model: String = StandalonePTTDefaults.transcriptionModel
    ) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let multipart = OpenAITranscriptionMultipartBody.make(audioData: audioData, model: model)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.data

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchOpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WatchOpenAIClientError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            Self.logger.error("openai transcription returned empty text responseBytes=\(data.count, privacy: .public)")
            throw WatchOpenAIClientError.emptyTranscription
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
