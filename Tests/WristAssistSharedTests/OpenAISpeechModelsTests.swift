import Foundation
import Testing
@testable import WristAssistShared

struct OpenAISpeechModelsTests {
    @Test func speechRequestEncodesPCMStreamingAudioDefaults() throws {
        let request = OpenAISpeechRequest(input: "Read this aloud.", voice: "CEDAR")

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["model"] as? String == StandalonePTTDefaults.speechModel)
        #expect(object["input"] as? String == "Read this aloud.")
        #expect(object["voice"] as? String == "cedar")
        #expect(object["response_format"] as? String == "pcm")
        #expect(object["stream_format"] as? String == "audio")
    }
}
