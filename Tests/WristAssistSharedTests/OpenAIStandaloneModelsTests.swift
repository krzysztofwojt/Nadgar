import Foundation
import Testing
@testable import WristAssistShared

struct OpenAIStandaloneModelsTests {
    @Test func responsesRequestIncludesHistoryInstructionsAndLowReasoning() throws {
        let messages = [
            ChatMessage(id: UUID(), role: .user, text: "Cześć", createdAt: Date(timeIntervalSince1970: 1)),
            ChatMessage(id: UUID(), role: .assistant, text: "Hej", createdAt: Date(timeIntervalSince1970: 2))
        ]
        let request = OpenAIResponsesRequest(
            model: "gpt-5.5",
            instructions: "Answer briefly.",
            messages: messages
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["model"] as? String == "gpt-5.5")
        #expect(object["instructions"] as? String == "Answer briefly.")

        let reasoning = try #require(object["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")

        let text = try #require(object["text"] as? [String: Any])
        #expect(text["verbosity"] as? String == "low")

        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input.count == 2)
        #expect(input[0]["role"] as? String == "user")
        #expect(input[0]["content"] as? String == "Cześć")
        #expect(input[1]["role"] as? String == "assistant")
        #expect(input[1]["content"] as? String == "Hej")
    }

    @Test func responsesResponsePrefersOutputText() throws {
        let data = #"{"output_text":"Gotowe.","output":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)

        #expect(decoded.assistantText == "Gotowe.")
    }

    @Test func responsesResponseFallsBackToNestedOutputContent() throws {
        let data = """
        {
          "output": [
            {
              "type": "message",
              "content": [
                {"type": "output_text", "text": "Pierwsza linia."},
                {"type": "output_text", "text": "Druga linia."}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)

        #expect(decoded.assistantText == "Pierwsza linia.\nDruga linia.")
    }

    @Test func responsesRequestExcludesPlaceholderMessages() throws {
        let messages = [
            ChatMessage(
                id: UUID(),
                role: .user,
                text: "Transcribing...",
                createdAt: Date(timeIntervalSince1970: 1),
                isPlaceholder: true
            ),
            ChatMessage(
                id: UUID(),
                role: .user,
                text: "Real transcript.",
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            ChatMessage(
                id: UUID(),
                role: .assistant,
                text: "Writing...",
                createdAt: Date(timeIntervalSince1970: 3),
                isPlaceholder: true
            )
        ]
        let request = OpenAIResponsesRequest(
            instructions: nil,
            messages: messages
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])

        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
        #expect(input[0]["content"] as? String == "Real transcript.")
    }
}
