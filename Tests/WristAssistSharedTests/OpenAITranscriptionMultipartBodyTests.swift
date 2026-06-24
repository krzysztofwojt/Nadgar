import Foundation
import Testing
@testable import WristAssistShared

struct OpenAITranscriptionMultipartBodyTests {
    @Test func multipartBodyIncludesModelAndAudioWAVFilePart() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let result = OpenAITranscriptionMultipartBody.make(
            audioData: audio,
            model: "gpt-4o-mini-transcribe",
            fileName: "sample.wav",
            boundary: "test-boundary"
        )

        #expect(result.boundary == "test-boundary")

        let body = String(decoding: result.data, as: UTF8.self)
        #expect(body.contains("--test-boundary\r\n"))
        #expect(body.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
        #expect(body.contains("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"sample.wav\"\r\n"))
        #expect(body.contains("Content-Type: audio/wav\r\n\r\nRIFF\r\n"))
        #expect(body.hasSuffix("--test-boundary--\r\n"))
    }
}
