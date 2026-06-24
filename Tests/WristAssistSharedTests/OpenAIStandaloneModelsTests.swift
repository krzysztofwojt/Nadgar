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

        #expect(object["store"] as? Bool == false)

        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search")
        #expect(object["tool_choice"] as? String == "auto")

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

    @Test func responsesResponseSkipsOutputItemsWithoutContent() throws {
        let data = """
        {
          "output": [
            {
              "type": "reasoning"
            },
            {
              "type": "message",
              "content": [
                {"type": "output_text", "text": "Gotowe."}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)

        #expect(decoded.assistantText == "Gotowe.")
    }

    @Test func responsesResponseExtractsWebCitations() throws {
        let data = """
        {
          "output": [
            {
              "type": "web_search_call",
              "status": "completed"
            },
            {
              "type": "message",
              "content": [
                {
                  "type": "output_text",
                  "text": "OpenAI released a new model today.",
                  "annotations": [
                    {
                      "type": "url_citation",
                      "start_index": 0,
                      "end_index": 6,
                      "url": "https://openai.com/news",
                      "title": "OpenAI News"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        let response = decoded.assistantResponse

        #expect(response.text == "OpenAI released a new model today.")
        #expect(response.usedWebSearch)
        #expect(response.citations == [
            ChatCitation(
                startIndex: 0,
                endIndex: 6,
                url: "https://openai.com/news",
                title: "OpenAI News"
            )
        ])
    }

    @Test func responsesResponsePreservesCitationOffsetsWithSurroundingWhitespace() throws {
        let data = """
        {
          "output": [
            {
              "type": "message",
              "content": [
                {
                  "type": "output_text",
                  "text": "\\nOpenAI released a new model today.\\n",
                  "annotations": [
                    {
                      "type": "url_citation",
                      "start_index": 1,
                      "end_index": 7,
                      "url": "https://openai.com/news",
                      "title": "OpenAI News"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        let response = decoded.assistantResponse
        let citation = try #require(response.citations.first)

        #expect(response.text == "\nOpenAI released a new model today.\n")
        #expect(try substring(in: response.text, citation: citation) == "OpenAI")
    }

    @Test func richMockResponseIncludesMarkdownLinksAndWebCitations() throws {
        let response = OpenAIMockResponses.richMarkdownCitationResponse(turnNumber: 7)

        #expect(response.usedWebSearch)
        #expect(response.text.contains("## Mock web answer 7"))
        #expect(response.text.contains("**bold**"))
        #expect(response.text.contains("__strong__"))
        #expect(response.text.contains("*italic*"))
        #expect(response.text.contains("_emphasis_"))
        #expect(response.text.contains("***bold italic***"))
        #expect(response.text.contains("~~strikethrough~~"))
        #expect(response.text.contains("`inline code`"))
        #expect(response.text.contains("\\*literal asterisks\\*"))
        #expect(response.text.contains("[OpenAI News](https://openai.com/news)"))
        #expect(response.text.contains("<https://openai.com/news>"))
        #expect(response.text.contains("![OpenAI logo](https://openai.com/favicon.ico)"))
        #expect(response.text.contains("[Apple Developer watchOS docs](https://developer.apple.com/watchos/)"))
        #expect(response.text.contains("```swift"))
        #expect(response.text.contains("---"))
        #expect(response.text.contains("| Format | Status | Source | Notes |"))
        #expect(response.text.contains("| Link | Hidden URL | [OpenAI](https://openai.com/news) | Scroll sideways"))
        #expect(response.text.contains("duplicate source appears before the cited duplicate source"))
        #expect(response.citations.count == 3)

        let citedText = try response.citations.map { try substring(in: response.text, citation: $0) }
        #expect(citedText == [
            "latest OpenAI product news",
            "Warsaw weather alerts for Thursday",
            "duplicate source"
        ])
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

    @Test func chatMessageCitationsDefaultToEmptyForLegacyMessages() throws {
        let data = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "role": "assistant",
          "text": "Legacy response.",
          "createdAt": 1,
          "isPlaceholder": false
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        #expect(decoded.citations.isEmpty)
    }

    private func substring(in text: String, citation: ChatCitation) throws -> String {
        let start = text.index(text.startIndex, offsetBy: citation.startIndex)
        let end = text.index(text.startIndex, offsetBy: citation.endIndex)
        return String(text[start..<end])
    }
}
