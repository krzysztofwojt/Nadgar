import Foundation
import Testing
@testable import WristAssistShared

struct RealtimeClientEventTests {
    @Test func sessionUpdateEncodesMVPRealtimeConfiguration() throws {
        let settings = ProviderSettings(
            hasAPIKey: true,
            model: "gpt-realtime-2",
            voice: "marin",
            instructions: "Be concise."
        )

        let data = try RealtimeClientEvent
            .sessionUpdate(RealtimeSession(settings: settings))
            .encodedData()

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "session.update")

        let session = try #require(object["session"] as? [String: Any])
        #expect(session["model"] as? String == "gpt-realtime-2")
        #expect(session["type"] as? String == "realtime")
        #expect(session["output_modalities"] as? [String] == ["audio"])

        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let inputFormat = try #require(input["format"] as? [String: Any])
        #expect(inputFormat["type"] as? String == "audio/pcm")
        #expect(inputFormat["rate"] as? Int == 24_000)

        let output = try #require(audio["output"] as? [String: Any])
        let outputFormat = try #require(output["format"] as? [String: Any])
        #expect(outputFormat["type"] as? String == "audio/pcm")
        #expect(outputFormat["rate"] as? Int == 24_000)
    }

    @Test func appendInputAudioEncodesBase64Payload() throws {
        let data = try RealtimeClientEvent.appendInputAudio(base64PCM16: "abc123").encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "input_audio_buffer.append")
        #expect(object["audio"] as? String == "abc123")
    }
}
