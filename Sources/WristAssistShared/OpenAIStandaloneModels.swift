import Foundation

public struct OpenAIResponsesRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var instructions: String?
    public var reasoning: OpenAIReasoningOptions
    public var text: OpenAITextOptions
    public var store: Bool
    public var tools: [OpenAIResponsesTool]
    public var toolChoice: String
    public var input: [OpenAIResponsesInputMessage]

    public init(
        model: String = StandalonePTTDefaults.assistantModel,
        instructions: String?,
        messages: [ChatMessage]
    ) {
        self.model = model
        self.instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.reasoning = OpenAIReasoningOptions(effort: "low")
        self.text = OpenAITextOptions(verbosity: "low")
        self.store = false
        self.tools = [OpenAIResponsesTool(type: "web_search")]
        self.toolChoice = "auto"
        self.input = messages
            .filter { !$0.isPlaceholder }
            .map(OpenAIResponsesInputMessage.init(message:))
    }

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case reasoning
        case text
        case store
        case tools
        case toolChoice = "tool_choice"
        case input
    }
}

public struct OpenAIResponsesTool: Codable, Equatable, Sendable {
    public var type: String

    public init(type: String) {
        self.type = type
    }
}

public struct OpenAIReasoningOptions: Codable, Equatable, Sendable {
    public var effort: String

    public init(effort: String) {
        self.effort = effort
    }
}

public struct OpenAITextOptions: Codable, Equatable, Sendable {
    public var verbosity: String

    public init(verbosity: String) {
        self.verbosity = verbosity
    }
}

public struct OpenAIResponsesInputMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: ChatMessageRole, content: String) {
        self.role = role.rawValue
        self.content = content
    }

    public init(message: ChatMessage) {
        self.init(role: message.role, content: message.text)
    }
}

public struct OpenAIResponsesResponse: Decodable, Equatable, Sendable {
    public var outputText: String?
    public var output: [OpenAIResponsesOutputItem]

    public init(outputText: String? = nil, output: [OpenAIResponsesOutputItem] = []) {
        self.outputText = outputText
        self.output = output
    }

    public var assistantText: String {
        assistantResponse.text
    }

    public var assistantResponse: OpenAIAssistantResponse {
        let nestedResponse = nestedAssistantResponse
        if !nestedResponse.citations.isEmpty {
            return nestedResponse
        }

        let directText = outputText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directText, !directText.isEmpty {
            return OpenAIAssistantResponse(
                text: directText,
                citations: [],
                usedWebSearch: nestedResponse.usedWebSearch
            )
        }

        return nestedResponse
    }

    private var nestedAssistantResponse: OpenAIAssistantResponse {
        var textParts: [String] = []
        var citations: [ChatCitation] = []
        var nextOffset = 0

        for content in output.flatMap(\.content) {
            guard let text = content.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            if !textParts.isEmpty {
                nextOffset += 1
            }

            textParts.append(text)

            for annotation in content.annotations {
                if let citation = annotation.chatCitation(offset: nextOffset, textLength: text.count) {
                    citations.append(citation)
                }
            }

            nextOffset += text.count
        }

        return OpenAIAssistantResponse(
            text: textParts.joined(separator: "\n"),
            citations: citations,
            usedWebSearch: output.contains { $0.type == "web_search_call" } || !citations.isEmpty
        )
    }

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outputText = try container.decodeIfPresent(String.self, forKey: .outputText)
        self.output = try container.decodeIfPresent([OpenAIResponsesOutputItem].self, forKey: .output) ?? []
    }
}

public struct OpenAIAssistantResponse: Equatable, Sendable {
    public var text: String
    public var citations: [ChatCitation]
    public var usedWebSearch: Bool

    public init(text: String, citations: [ChatCitation] = [], usedWebSearch: Bool = false) {
        self.text = text
        self.citations = citations
        self.usedWebSearch = usedWebSearch
    }
}

public enum OpenAIMockResponses {
    public static func richMarkdownCitationResponse(turnNumber: Int) -> OpenAIAssistantResponse {
        let firstCitedFragment = "latest OpenAI product news"
        let secondCitedFragment = "Warsaw weather alerts for Thursday"
        let repeatedCitedFragment = "duplicate source"
        let text = """
        ## Mock web answer \(turnNumber)

        Today we verify **bold**, __strong__, *italic*, _emphasis_, ***bold italic***, ~~strikethrough~~, `inline code`, escaped \\*literal asterisks\\*, and a markdown link to [OpenAI News](https://openai.com/news).

        URL citation #1 should underline only this visible fragment: \(firstCitedFragment).

        1. Ordered item with <https://openai.com/news> as an autolink.
        2. Image markdown should display alt text only: ![OpenAI logo](https://openai.com/favicon.ico).
        - **Markets:** a bullet with [Apple Developer watchOS docs](https://developer.apple.com/watchos/) and no raw URL.
        - _Weather:_ second citation target is \(secondCitedFragment).
        - Repeated citation check: duplicate source appears before the cited \(repeatedCitedFragment).
        - [x] Task list checked.
        - [ ] Task list unchecked.

        ```swift
        let sourceCount = 4
        ```

        ---

        | Format | Status | Source | Notes |
        |---|---|---|---|
        | Link | Hidden URL | [OpenAI](https://openai.com/news) | Scroll sideways to inspect this longer table cell |

        > Blockquote text stays compact on watchOS, and the source action should open on iPhone.
        """

        return OpenAIAssistantResponse(
            text: text,
            citations: [
                citation(
                    for: firstCitedFragment,
                    in: text,
                    url: "https://openai.com/news/",
                    title: "OpenAI News"
                ),
                citation(
                    for: secondCitedFragment,
                    in: text,
                    url: "https://www.weather.gov/",
                    title: "Weather Alerts"
                ),
                citation(
                    for: repeatedCitedFragment,
                    in: text,
                    occurrence: 2,
                    url: "https://openai.com/research/",
                    title: "Repeated Source"
                )
            ].compactMap { $0 },
            usedWebSearch: true
        )
    }

    private static func citation(
        for fragment: String,
        in text: String,
        occurrence: Int = 1,
        url: String,
        title: String
    ) -> ChatCitation? {
        guard occurrence > 0 else { return nil }

        var searchStart = text.startIndex
        var matchedRange: Range<String.Index>?
        for _ in 0..<occurrence {
            guard let range = text.range(of: fragment, range: searchStart..<text.endIndex) else {
                return nil
            }

            matchedRange = range
            searchStart = range.upperBound
        }

        guard let range = matchedRange else { return nil }

        return ChatCitation(
            startIndex: text.distance(from: text.startIndex, to: range.lowerBound),
            endIndex: text.distance(from: text.startIndex, to: range.upperBound),
            url: url,
            title: title
        )
    }
}

public struct OpenAIResponsesOutputItem: Decodable, Equatable, Sendable {
    public var type: String?
    public var content: [OpenAIResponsesOutputContent]

    public init(type: String? = nil, content: [OpenAIResponsesOutputContent] = []) {
        self.type = type
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case type
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.content = try container.decodeIfPresent([OpenAIResponsesOutputContent].self, forKey: .content) ?? []
    }
}

public struct OpenAIResponsesOutputContent: Decodable, Equatable, Sendable {
    public var type: String?
    public var text: String?
    public var annotations: [OpenAIResponsesAnnotation]

    public init(type: String? = nil, text: String? = nil, annotations: [OpenAIResponsesAnnotation] = []) {
        self.type = type
        self.text = text
        self.annotations = annotations
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case annotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.annotations = try container.decodeIfPresent([OpenAIResponsesAnnotation].self, forKey: .annotations) ?? []
    }
}

public struct OpenAIResponsesAnnotation: Decodable, Equatable, Sendable {
    public var type: String?
    public var startIndex: Int?
    public var endIndex: Int?
    public var url: String?
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case type
        case startIndex = "start_index"
        case endIndex = "end_index"
        case url
        case title
    }

    func chatCitation(offset: Int, textLength: Int) -> ChatCitation? {
        guard type == "url_citation",
              let startIndex,
              let endIndex,
              let url,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let clampedStart = min(max(0, startIndex), textLength)
        let clampedEnd = min(max(clampedStart, endIndex), textLength)
        guard clampedEnd > clampedStart else {
            return nil
        }

        return ChatCitation(
            startIndex: offset + clampedStart,
            endIndex: offset + clampedEnd,
            url: url,
            title: title ?? ""
        )
    }
}

public struct OpenAITranscriptionResponse: Decodable, Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct OpenAIErrorResponse: Decodable, Equatable, Sendable {
    public var error: OpenAIErrorPayload

    public init(error: OpenAIErrorPayload) {
        self.error = error
    }
}

public struct OpenAIErrorPayload: Decodable, Equatable, Sendable {
    public var message: String
    public var code: String?

    public init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
