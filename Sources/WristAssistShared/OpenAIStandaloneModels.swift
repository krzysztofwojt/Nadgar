import Foundation

public struct OpenAIResponsesRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var instructions: String?
    public var reasoning: OpenAIReasoningOptions
    public var text: OpenAITextOptions
    public var store: Bool
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
        self.input = messages
            .filter { !$0.isPlaceholder }
            .map(OpenAIResponsesInputMessage.init(message:))
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
        let directText = outputText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directText, !directText.isEmpty {
            return directText
        }

        return output
            .flatMap(\.content)
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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

    public init(type: String? = nil, text: String? = nil) {
        self.type = type
        self.text = text
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
