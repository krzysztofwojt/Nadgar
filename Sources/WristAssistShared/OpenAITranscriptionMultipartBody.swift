import Foundation

public enum OpenAITranscriptionMultipartBody {
    public static func make(
        audioData: Data,
        model: String = StandalonePTTDefaults.transcriptionModel,
        fileName: String = "recording.wav",
        boundary: String = "Boundary-\(UUID().uuidString)"
    ) -> (boundary: String, data: Data) {
        var body = Data()

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("\(model)\r\n")

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendUTF8("json\r\n")

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.appendUTF8("\r\n")
        body.appendUTF8("--\(boundary)--\r\n")

        return (boundary, body)
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
