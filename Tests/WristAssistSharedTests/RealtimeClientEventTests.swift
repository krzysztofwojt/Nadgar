import Foundation
import Testing
@testable import WristAssistShared

struct RealtimeClientEventTests {
    @Test func sessionUpdateEncodesMVPRealtimeConfiguration() throws {
        let settings = ProviderSettings(
            hasAPIKey: true,
            model: "gpt-realtime-2",
            voice: "MARIN",
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
        let turnDetection = try #require(input["turn_detection"] as? [String: Any])
        #expect(turnDetection["type"] as? String == "semantic_vad")
        #expect(turnDetection["eagerness"] as? String == "low")
        #expect(turnDetection["create_response"] as? Bool == true)
        #expect(turnDetection["interrupt_response"] as? Bool == false)

        let output = try #require(audio["output"] as? [String: Any])
        let outputFormat = try #require(output["format"] as? [String: Any])
        #expect(outputFormat["type"] as? String == "audio/pcm")
        #expect(outputFormat["rate"] as? Int == 24_000)
        #expect(output["voice"] as? String == "marin")
    }

    @Test func sessionUpdateEncodesPushToTalkWithDisabledTurnDetection() throws {
        let settings = ProviderSettings(
            hasAPIKey: true,
            model: "gpt-realtime-2",
            voice: "MARIN",
            instructions: "Be concise."
        )

        let data = try RealtimeClientEvent
            .sessionUpdate(RealtimeSession(settings: settings, mode: .pushToTalk))
            .encodedData()

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])

        #expect(input["turn_detection"] is NSNull)
    }

    @Test func appendInputAudioEncodesBase64Payload() throws {
        let data = try RealtimeClientEvent.appendInputAudio(base64PCM16: "abc123").encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "input_audio_buffer.append")
        #expect(object["audio"] as? String == "abc123")
    }

    @Test func clearInputAudioEncodesClearEvent() throws {
        let data = try RealtimeClientEvent.clearInputAudio.encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "input_audio_buffer.clear")
    }

    @Test func commitInputAudioEncodesCommitEvent() throws {
        let data = try RealtimeClientEvent.commitInputAudio.encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "input_audio_buffer.commit")
    }

    @Test func createResponseEncodesCreateEvent() throws {
        let data = try RealtimeClientEvent.createResponse.encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "response.create")
    }

    @Test func cancelResponseEncodesOptionalResponseID() throws {
        let data = try RealtimeClientEvent.cancelResponse(responseID: "resp_123").encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "response.cancel")
        #expect(object["response_id"] as? String == "resp_123")
    }

    @Test func truncateConversationItemEncodesPlaybackPosition() throws {
        let data = try RealtimeClientEvent
            .truncateConversationItem(itemID: "item_123", contentIndex: 0, audioEndMilliseconds: 420)
            .encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "conversation.item.truncate")
        #expect(object["item_id"] as? String == "item_123")
        #expect(object["content_index"] as? Int == 0)
        #expect(object["audio_end_ms"] as? Int == 420)
    }
}
