import Foundation

public struct OpenAIResponsesRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var instructions: String?
    public var reasoning: OpenAIReasoningOptions
    public var text: OpenAITextOptions
    public var store: Bool
    public var stream: Bool
    public var tools: [OpenAIResponsesTool]
    public var toolChoice: String
    public var input: [OpenAIResponsesInputMessage]

    public init(
        model: String = StandalonePTTDefaults.assistantModel,
        instructions: String?,
        messages: [ChatMessage],
        stream: Bool = false
    ) {
        self.model = model
        self.instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.reasoning = OpenAIReasoningOptions(effort: "low")
        self.text = OpenAITextOptions(verbosity: "low")
        self.store = false
        self.stream = stream
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
        case stream
        case tools
        case toolChoice = "tool_choice"
        case input
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encode(reasoning, forKey: .reasoning)
        try container.encode(text, forKey: .text)
        try container.encode(store, forKey: .store)
        if stream {
            try container.encode(true, forKey: .stream)
        }
        try container.encode(tools, forKey: .tools)
        try container.encode(toolChoice, forKey: .toolChoice)
        try container.encode(input, forKey: .input)
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
        self.outputText = (try? container.decodeIfPresent(String.self, forKey: .outputText)) ?? nil
        self.output = (try? container.decodeIfPresent([OpenAIResponsesOutputItem].self, forKey: .output)) ?? []
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

public enum OpenAIResponsesStreamUpdate: Equatable, Sendable {
    case textDelta(String)
    case completed(OpenAIAssistantResponse)
}

public struct OpenAIResponsesStreamEventSummary: Equatable, Sendable {
    public var type: String
    public var payloadByteCount: Int
    public var responseStatus: String?
    public var outputItemTypes: [String]
    public var textLength: Int?

    public init(
        type: String,
        payloadByteCount: Int,
        responseStatus: String? = nil,
        outputItemTypes: [String] = [],
        textLength: Int? = nil
    ) {
        self.type = type
        self.payloadByteCount = payloadByteCount
        self.responseStatus = responseStatus
        self.outputItemTypes = outputItemTypes
        self.textLength = textLength
    }
}

public enum OpenAIResponsesStreamError: LocalizedError, Equatable, Sendable {
    case invalidEvent(String)
    case openAIError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEvent(let message), .openAIError(let message):
            return message
        }
    }
}

public struct OpenAIResponsesSSEParser: Sendable {
    private var dataLines: [String] = []
    private var hasEmittedTextDelta = false
    private var onEvent: (@Sendable (OpenAIResponsesStreamEventSummary) -> Void)?

    public init(onEvent: (@Sendable (OpenAIResponsesStreamEventSummary) -> Void)? = nil) {
        self.onEvent = onEvent
    }

    public mutating func parse(line rawLine: String) throws -> [OpenAIResponsesStreamUpdate] {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.isEmpty else {
            return try flushEvent()
        }

        if line.hasPrefix("event:") {
            return try flushEvent()
        }

        guard line.hasPrefix("data:") else {
            return []
        }

        let dataLine = dataValue(from: line)
        let trimmedDataLine = dataLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDataLine != "[DONE]" else {
            return try flushEvent()
        }

        if trimmedDataLine.isEmpty && dataLines.isEmpty {
            return []
        }

        dataLines.append(dataLine)
        return []
    }

    public mutating func finish() throws -> [OpenAIResponsesStreamUpdate] {
        try flushEvent()
    }

    private mutating func flushEvent() throws -> [OpenAIResponsesStreamUpdate] {
        guard !dataLines.isEmpty else { return [] }

        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        guard let data = payload.data(using: .utf8) else {
            throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming event that could not be decoded.")
        }

        let event = try OpenAIResponsesStreamEvent(data: data)
        onEvent?(event.summary)
        let updates = try event.updates(hasEmittedTextDelta: hasEmittedTextDelta)
        if updates.contains(where: \.isTextDelta) {
            hasEmittedTextDelta = true
        }
        return updates
    }

    private func dataValue(from line: String) -> String {
        var value = String(line.dropFirst("data:".count))
        if value.first == " " {
            value.removeFirst()
        }
        return value
    }
}

private struct OpenAIResponsesStreamEvent {
    var type: String
    var payload: [String: Any]?
    var summary: OpenAIResponsesStreamEventSummary

    init(data: Data) throws {
        guard let rawPayload = String(data: data, encoding: .utf8) else {
            throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a non-UTF-8 streaming event.")
        }

        let decodedObject: Any?
        do {
            decodedObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            guard let type = Self.eventType(in: rawPayload) else {
                throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming event without a type: \(Self.payloadSnippet(from: data))")
            }

            guard Self.requiresPayload(for: type) else {
                self.type = type
                self.payload = nil
                self.summary = OpenAIResponsesStreamEventSummary(type: type, payloadByteCount: data.count)
                return
            }

            throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming event that could not be decoded: \(Self.payloadSnippet(from: data))")
        }

        guard let payload = decodedObject as? [String: Any] else {
            guard let type = Self.eventType(in: rawPayload) else {
                throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming event without a type: \(Self.payloadSnippet(from: data))")
            }

            guard !Self.requiresPayload(for: type) else {
                throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming event in an unexpected format: \(Self.payloadSnippet(from: data))")
            }

            self.type = type
            self.payload = nil
            self.summary = OpenAIResponsesStreamEventSummary(type: type, payloadByteCount: data.count)
            return
        }

        guard let type = payload["type"] as? String, !type.isEmpty else {
            throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming event without a type: \(Self.payloadSnippet(from: data))")
        }

        self.type = type

        guard !Self.requiresPayload(for: type) || !payload.isEmpty else {
            throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming event in an unexpected format: \(Self.payloadSnippet(from: data))")
        }

        self.payload = payload
        self.summary = Self.summary(type: type, payloadByteCount: data.count, payload: payload)
    }

    func updates(hasEmittedTextDelta: Bool) throws -> [OpenAIResponsesStreamUpdate] {
        switch type {
        case "response.output_text.delta":
            guard let payload else { return [] }
            guard let delta = payload["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]
        case "response.output_text.done":
            guard let payload else { return [] }
            guard !hasEmittedTextDelta else { return [] }
            guard let text = payload["text"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "response.completed":
            guard let payload else { return [] }
            guard let responseObject = payload["response"] else {
                throw OpenAIResponsesStreamError.invalidEvent("OpenAI completed a streaming response without a response payload.")
            }
            let response: OpenAIResponsesResponse
            do {
                let data = try Self.jsonData(from: responseObject)
                response = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
            } catch {
                throw OpenAIResponsesStreamError.invalidEvent("OpenAI completed a streaming response in an unexpected format.")
            }
            return [.completed(response.assistantResponse)]
        case "error":
            guard let payload else { return [] }
            throw OpenAIResponsesStreamError.openAIError(Self.errorMessage(from: payload))
        case "response.failed":
            guard let payload else { return [] }
            throw OpenAIResponsesStreamError.openAIError(Self.responseErrorMessage(from: payload))
        case "response.incomplete":
            guard let payload else { return [] }
            throw OpenAIResponsesStreamError.openAIError(Self.responseIncompleteMessage(from: payload))
        default:
            return []
        }
    }

    private static func requiresPayload(for type: String) -> Bool {
        switch type {
        case "response.output_text.delta",
             "response.output_text.done",
             "response.completed",
             "response.failed",
             "response.incomplete",
             "error":
            return true
        default:
            return false
        }
    }

    private static func eventType(in rawPayload: String) -> String? {
        guard let typeKeyRange = rawPayload.range(of: #""type""#),
              let colonIndex = rawPayload[typeKeyRange.upperBound...].firstIndex(of: ":")
        else {
            return nil
        }

        var cursor = rawPayload.index(after: colonIndex)
        while cursor < rawPayload.endIndex,
              rawPayload[cursor].isWhitespace {
            cursor = rawPayload.index(after: cursor)
        }

        guard cursor < rawPayload.endIndex, rawPayload[cursor] == "\"" else {
            return nil
        }

        cursor = rawPayload.index(after: cursor)
        var value = ""
        var isEscaped = false
        while cursor < rawPayload.endIndex {
            let character = rawPayload[cursor]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return value.isEmpty ? nil : value
            } else {
                value.append(character)
            }
            cursor = rawPayload.index(after: cursor)
        }

        return nil
    }

    private static func jsonData(from object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw OpenAIResponsesStreamError.invalidEvent("OpenAI returned a streaming response payload that could not be decoded.")
        }

        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func responseErrorMessage(from payload: [String: Any]) -> String {
        if let response = payload["response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            return errorMessage(from: error)
        }

        return errorMessage(from: payload)
    }

    private static func responseIncompleteMessage(from payload: [String: Any]) -> String {
        guard let response = payload["response"] as? [String: Any] else {
            return errorMessage(from: payload)
        }

        if let incompleteDetails = response["incomplete_details"] as? [String: Any] {
            if let message = incompleteDetails["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }

            if let reason = incompleteDetails["reason"] as? String,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OpenAI response was incomplete: \(reason)."
            }
        }

        return errorMessage(from: response)
    }

    private static func summary(
        type: String,
        payloadByteCount: Int,
        payload: [String: Any]
    ) -> OpenAIResponsesStreamEventSummary {
        let response = payload["response"] as? [String: Any]
        let output = response?["output"] as? [[String: Any]]

        return OpenAIResponsesStreamEventSummary(
            type: type,
            payloadByteCount: payloadByteCount,
            responseStatus: response?["status"] as? String,
            outputItemTypes: output?.compactMap { $0["type"] as? String } ?? [],
            textLength: textLength(type: type, payload: payload, response: response)
        )
    }

    private static func textLength(
        type: String,
        payload: [String: Any],
        response: [String: Any]?
    ) -> Int? {
        switch type {
        case "response.output_text.delta":
            return (payload["delta"] as? String)?.count
        case "response.output_text.done":
            return (payload["text"] as? String)?.count
        case "response.refusal.delta":
            return (payload["delta"] as? String)?.count
        case "response.refusal.done":
            return (payload["refusal"] as? String)?.count
        case "response.completed":
            guard let response else { return nil }
            return completedTextLength(from: response)
        default:
            return nil
        }
    }

    private static func completedTextLength(from response: [String: Any]) -> Int {
        if let outputText = response["output_text"] as? String {
            return outputText.count
        }

        guard let output = response["output"] as? [[String: Any]] else {
            return 0
        }

        var length = 0
        for item in output {
            if let content = item["content"] as? [[String: Any]] {
                for part in content {
                    if let text = part["text"] as? String {
                        length += text.count
                    } else if let refusal = part["refusal"] as? String {
                        length += refusal.count
                    }
                }
            } else if let text = item["content"] as? String {
                length += text.count
            } else if let text = item["text"] as? String {
                length += text.count
            }
        }

        return length
    }

    private static func errorMessage(from payload: [String: Any]) -> String {
        if let error = payload["error"] as? [String: Any] {
            return errorMessage(from: error)
        }

        if let message = payload["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let code = payload["code"] as? String,
           !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return code
        }

        return "OpenAI streaming request failed."
    }

    private static func payloadSnippet(from data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: "\\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "<empty>" }
        return String(collapsed.prefix(240))
    }
}

private extension OpenAIResponsesStreamUpdate {
    var isTextDelta: Bool {
        if case .textDelta = self {
            return true
        }
        return false
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
        self.type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil
        if let content = try? container.decodeIfPresent([OpenAIResponsesOutputContent].self, forKey: .content) {
            self.content = content
        } else if let content = try? container.decodeIfPresent(OpenAIResponsesOutputContent.self, forKey: .content) {
            self.content = [content]
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            self.content = [OpenAIResponsesOutputContent(type: "output_text", text: text)]
        } else {
            self.content = []
        }
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
        case refusal
        case annotations
    }

    enum TextCodingKeys: String, CodingKey {
        case value
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil
        self.text = Self.decodeString(forKey: .text, from: container) ??
            Self.decodeString(forKey: .refusal, from: container)
        self.annotations = (try? container.decodeIfPresent([OpenAIResponsesAnnotation].self, forKey: .annotations)) ?? []
    }

    private static func decodeString(
        forKey key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return string
        }

        guard let nestedContainer = try? container.nestedContainer(keyedBy: TextCodingKeys.self, forKey: key) else {
            return nil
        }

        return (try? nestedContainer.decodeIfPresent(String.self, forKey: .value)) ??
            (try? nestedContainer.decodeIfPresent(String.self, forKey: .text))
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil
        self.startIndex = (try? container.decodeIfPresent(Int.self, forKey: .startIndex)) ?? nil
        self.endIndex = (try? container.decodeIfPresent(Int.self, forKey: .endIndex)) ?? nil
        self.url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? nil
        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
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
