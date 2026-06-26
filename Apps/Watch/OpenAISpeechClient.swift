import Foundation
import os
import WristAssistShared

struct OpenAISpeechClient {
    private static let streamChunkByteCount = 24_000
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
        category: "OpenAISpeechClient"
    )

    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func speechAudioStream(
        apiKey: String,
        settings: ProviderSettings,
        input: String
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.request(apiKey: apiKey, settings: settings, input: input)
                    Self.logger.info("openai speech stream request model=\(settings.ttsModel, privacy: .public) voice=\(settings.voice, privacy: .public) characters=\(input.count, privacy: .public)")

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw WatchOpenAIClientError.invalidResponse
                    }

                    Self.logger.info("openai speech stream httpStatus=\(httpResponse.statusCode, privacy: .public)")
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        let data = try await Self.data(from: bytes)
                        throw WatchOpenAIClientError.openAIError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
                    }

                    var buffer = Data()
                    buffer.reserveCapacity(Self.streamChunkByteCount)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)

                        guard buffer.count >= Self.streamChunkByteCount else { continue }
                        Self.yieldEvenPCMBuffer(&buffer, to: continuation)
                    }

                    if !buffer.isEmpty {
                        guard buffer.count.isMultiple(of: 2) else {
                            throw WatchOpenAIClientError.invalidResponse
                        }
                        continuation.yield(buffer)
                    }

                    continuation.finish()
                } catch {
                    Self.logger.error("openai speech stream failed error=\(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func request(apiKey: String, settings: ProviderSettings, input: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let body = OpenAISpeechRequest(
            model: settings.ttsModel,
            input: input,
            voice: settings.voice,
            responseFormat: "pcm",
            streamFormat: "audio"
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func yieldEvenPCMBuffer(
        _ buffer: inout Data,
        to continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        let evenCount = buffer.count - (buffer.count % 2)
        guard evenCount > 0 else { return }

        continuation.yield(buffer.prefix(evenCount))
        buffer.removeSubrange(..<evenCount)
    }

    private static func data(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
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
