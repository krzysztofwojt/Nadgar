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
            model: StandalonePTTDefaults.assistantModel,
            instructions: "Answer briefly.",
            messages: messages
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["model"] as? String == StandalonePTTDefaults.assistantModel)
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

    @Test func responsesRequestOmitsStreamByDefault() throws {
        let request = OpenAIResponsesRequest(
            instructions: nil,
            messages: [
                ChatMessage(role: .user, text: "Hej")
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["stream"] == nil)
    }

    @Test func streamingResponsesRequestIncludesStreamWhenEnabled() throws {
        let request = OpenAIResponsesRequest(
            instructions: nil,
            messages: [
                ChatMessage(role: .user, text: "Hej")
            ],
            stream: true
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["stream"] as? Bool == true)
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

    @Test func responsesResponseReadsSingleObjectContent() throws {
        let data = """
        {
          "output": [
            {
              "type": "message",
              "content": {"type": "output_text", "text": "Single content object."}
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)

        #expect(decoded.assistantText == "Single content object.")
    }

    @Test func responsesResponseReadsStringContent() throws {
        let data = """
        {
          "output": [
            {
              "type": "message",
              "content": "String content."
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)

        #expect(decoded.assistantText == "String content.")
    }

    @Test func responsesResponseReadsNestedTextValue() throws {
        let data = """
        {
          "output": [
            {
              "type": "message",
              "content": [
                {"type": "output_text", "text": {"value": "Nested text value."}}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)

        #expect(decoded.assistantText == "Nested text value.")
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

    @Test func responsesSSEParserEmitsTextDeltasInOrder() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.output_text.delta","delta":"Pierwsza "}"#)
        updates += try parser.parse(line: "")
        updates += try parser.parse(line: #"data: {"type":"response.output_text.delta","delta":"druga."}"#)
        updates += try parser.parse(line: "")

        #expect(updates == [
            .textDelta("Pierwsza "),
            .textDelta("druga.")
        ])
    }

    @Test func responsesSSEParserUsesEventLinesAsBoundariesWhenBlankLinesAreMissing() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: "event: response.created")
        updates += try parser.parse(line: #"data: {"type":"response.created","response":{"status":"in_progress"}}"#)
        updates += try parser.parse(line: "event: response.output_text.delta")
        updates += try parser.parse(line: #"data: {"type":"response.output_text.delta","delta":"Pierwsza "}"#)
        updates += try parser.parse(line: "event: response.output_text.delta")
        updates += try parser.parse(line: #"data: {"type":"response.output_text.delta","delta":"druga."}"#)
        updates += try parser.parse(line: "event: response.completed")
        updates += try parser.parse(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Pierwsza druga."}]}]}}"#)
        updates += try parser.finish()

        #expect(updates == [
            .textDelta("Pierwsza "),
            .textDelta("druga."),
            .completed(OpenAIAssistantResponse(text: "Pierwsza druga."))
        ])
    }

    @Test func responsesSSEParserReportsEventSummaries() throws {
        let recorder = StreamSummaryRecorder()
        var parser = OpenAIResponsesSSEParser { summary in
            recorder.append(summary)
        }
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Done."}]}]}}"#)
        updates += try parser.parse(line: "")

        #expect(updates == [
            .completed(OpenAIAssistantResponse(text: "Done."))
        ])
        let summary = try #require(recorder.summaries.first)
        #expect(summary.type == "response.completed")
        #expect(summary.payloadByteCount > 0)
        #expect(summary.responseStatus == "completed")
        #expect(summary.outputItemTypes == ["message"])
        #expect(summary.textLength == 5)
    }

    @Test func responsesSSEParserUsesTopLevelEventTypeWhenNestedTypeAppearsFirst() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Done."}]}]},"type":"response.completed"}"#)
        updates += try parser.parse(line: "")

        #expect(updates == [
            .completed(OpenAIAssistantResponse(text: "Done."))
        ])
    }

    @Test func responsesSSEParserUsesOutputTextDoneWhenNoDeltasArrived() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.output_text.done","text":"Final text without deltas."}"#)
        updates += try parser.parse(line: "")

        #expect(updates == [
            .textDelta("Final text without deltas.")
        ])
    }

    @Test func responsesSSEParserIgnoresOutputTextDoneAfterDeltas() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.output_text.delta","delta":"Final "}"#)
        updates += try parser.parse(line: "")
        updates += try parser.parse(line: #"data: {"type":"response.output_text.done","text":"Final text."}"#)
        updates += try parser.parse(line: "")
        updates += try parser.parse(line: #"data: {"type":"response.output_text.delta","delta":"text."}"#)
        updates += try parser.parse(line: "")

        #expect(updates == [
            .textDelta("Final "),
            .textDelta("text.")
        ])
    }

    @Test func responsesSSEParserEmitsCompletedResponseWithCitations() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.completed","response":{"output":[{"type":"web_search_call","status":"completed"},{"type":"message","content":[{"type":"output_text","text":"OpenAI News","annotations":[{"type":"url_citation","start_index":0,"end_index":6,"url":"https://openai.com/news","title":"OpenAI News"}]}]}]}}"#)
        updates += try parser.parse(line: "")

        let response = OpenAIAssistantResponse(
            text: "OpenAI News",
            citations: [
                ChatCitation(
                    startIndex: 0,
                    endIndex: 6,
                    url: "https://openai.com/news",
                    title: "OpenAI News"
                )
            ],
            usedWebSearch: true
        )
        #expect(updates == [.completed(response)])
    }

    @Test func responsesSSEParserIgnoresUnneededEventsWithUnexpectedPayloads() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.in_progress","response":{"output":[{"type":"message","content":"unexpected-string"}]}}"#)
        updates += try parser.parse(line: "")
        updates += try parser.parse(line: #"data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","start_index":0,"end_index":4,"url":"https://example.com"}}"#)
        updates += try parser.parse(line: "")

        #expect(updates.isEmpty)
    }

    @Test func responsesSSEParserIgnoresMalformedUnneededControlEvents() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.created","response":{"id":"resp_123","status":"in_progress","frequency_penalty""#)
        updates += try parser.parse(line: "")

        #expect(updates.isEmpty)
    }

    @Test func responsesSSEParserIgnoresEmptyDataEvents() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: "data: ")
        updates += try parser.parse(line: "")

        #expect(updates.isEmpty)
    }

    @Test func responsesSSEParserToleratesUnexpectedCompletedOutputItems() throws {
        var parser = OpenAIResponsesSSEParser()
        var updates: [OpenAIResponsesStreamUpdate] = []

        updates += try parser.parse(line: #"data: {"type":"response.completed","response":{"output_text":"Final text.","output":[{"type":"message","content":"unexpected-string"}]}}"#)
        updates += try parser.parse(line: "")

        #expect(updates == [
            .completed(OpenAIAssistantResponse(text: "Final text."))
        ])
    }

    @Test func responsesSSEParserMapsFailedResponses() throws {
        var parser = OpenAIResponsesSSEParser()
        var caughtError: OpenAIResponsesStreamError?

        do {
            _ = try parser.parse(line: #"data: {"type":"response.failed","response":{"error":{"message":"Search failed."}}}"#)
            _ = try parser.parse(line: "")
        } catch let error as OpenAIResponsesStreamError {
            caughtError = error
        }

        #expect(caughtError == .openAIError("Search failed."))
    }

    @Test func responsesSSEParserMapsIncompleteResponses() throws {
        var parser = OpenAIResponsesSSEParser()
        var caughtError: OpenAIResponsesStreamError?

        do {
            _ = try parser.parse(line: #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)
            _ = try parser.parse(line: "")
        } catch let error as OpenAIResponsesStreamError {
            caughtError = error
        }

        #expect(caughtError == .openAIError("OpenAI response was incomplete: max_output_tokens."))
    }

    @Test func responsesSSEParserMapsErrorEvents() throws {
        var parser = OpenAIResponsesSSEParser()
        var caughtError: OpenAIResponsesStreamError?

        do {
            _ = try parser.parse(line: #"data: {"type":"error","message":"Bad request."}"#)
            _ = try parser.parse(line: "")
        } catch let error as OpenAIResponsesStreamError {
            caughtError = error
        }

        #expect(caughtError == .openAIError("Bad request."))
    }

    private func substring(in text: String, citation: ChatCitation) throws -> String {
        let start = text.index(text.startIndex, offsetBy: citation.startIndex)
        let end = text.index(text.startIndex, offsetBy: citation.endIndex)
        return String(text[start..<end])
    }
}

private final class StreamSummaryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OpenAIResponsesStreamEventSummary] = []

    var summaries: [OpenAIResponsesStreamEventSummary] {
        lock.withLock { storage }
    }

    func append(_ summary: OpenAIResponsesStreamEventSummary) {
        lock.withLock {
            storage.append(summary)
        }
    }
}
