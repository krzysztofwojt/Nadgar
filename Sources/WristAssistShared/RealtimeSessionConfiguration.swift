import Foundation

public struct RealtimeSessionConfiguration: Codable, Equatable, Sendable {
    public var session: RealtimeSession

    public init(session: RealtimeSession) {
        self.session = session
    }

    public init(settings: ProviderSettings, mode: RealtimeConversationMode = .auto) {
        self.session = RealtimeSession(settings: settings, mode: mode)
    }
}

public enum RealtimeConversationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case pushToTalk

    public var id: String { rawValue }
}

public struct RealtimeSession: Codable, Equatable, Sendable {
    public var type: String
    public var model: String
    public var outputModalities: [String]
    public var audio: RealtimeAudioConfiguration
    public var instructions: String?

    public init(
        type: String = "realtime",
        model: String,
        outputModalities: [String] = ["audio"],
        audio: RealtimeAudioConfiguration,
        instructions: String?
    ) {
        self.type = type
        self.model = model
        self.outputModalities = outputModalities
        self.audio = audio
        self.instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public init(settings: ProviderSettings, mode: RealtimeConversationMode = .auto) {
        self.init(
            model: settings.model,
            audio: RealtimeAudioConfiguration(voice: settings.voice, mode: mode),
            instructions: settings.instructions
        )
    }

    enum CodingKeys: String, CodingKey {
        case type
        case model
        case outputModalities = "output_modalities"
        case audio
        case instructions
    }
}

public struct RealtimeAudioConfiguration: Codable, Equatable, Sendable {
    public var input: RealtimeAudioInput
    public var output: RealtimeAudioOutput

    public init(
        input: RealtimeAudioInput = RealtimeAudioInput(),
        output: RealtimeAudioOutput
    ) {
        self.input = input
        self.output = output
    }

    public init(voice: String, mode: RealtimeConversationMode = .auto) {
        self.init(input: RealtimeAudioInput(mode: mode), output: RealtimeAudioOutput(voice: voice))
    }
}

public struct RealtimeAudioInput: Codable, Equatable, Sendable {
    public var format: RealtimeAudioFormat
    public var turnDetection: RealtimeTurnDetection?

    public init(
        format: RealtimeAudioFormat = RealtimeAudioFormat(type: "audio/pcm", rate: 24_000),
        turnDetection: RealtimeTurnDetection? = .semanticConversation
    ) {
        self.format = format
        self.turnDetection = turnDetection
    }

    public init(
        mode: RealtimeConversationMode,
        format: RealtimeAudioFormat = RealtimeAudioFormat(type: "audio/pcm", rate: 24_000)
    ) {
        self.init(format: format, turnDetection: mode == .auto ? .semanticConversation : nil)
    }

    enum CodingKeys: String, CodingKey {
        case format
        case turnDetection = "turn_detection"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try container.decode(RealtimeAudioFormat.self, forKey: .format)
        self.turnDetection = try container.decodeIfPresent(RealtimeTurnDetection.self, forKey: .turnDetection)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)

        if let turnDetection {
            try container.encode(turnDetection, forKey: .turnDetection)
        } else {
            try container.encodeNil(forKey: .turnDetection)
        }
    }
}

public struct RealtimeAudioOutput: Codable, Equatable, Sendable {
    public var format: RealtimeAudioFormat
    public var voice: String

    public init(
        format: RealtimeAudioFormat = RealtimeAudioFormat(type: "audio/pcm", rate: 24_000),
        voice: String
    ) {
        self.format = format
        self.voice = voice
    }
}

public struct RealtimeAudioFormat: Codable, Equatable, Sendable {
    public var type: String
    public var rate: Int?

    public init(type: String, rate: Int?) {
        self.type = type
        self.rate = rate
    }
}

public struct RealtimeTurnDetection: Codable, Equatable, Sendable {
    public var type: String
    public var eagerness: String?
    public var createResponse: Bool?
    public var interruptResponse: Bool?

    public init(
        type: String,
        eagerness: String? = nil,
        createResponse: Bool? = nil,
        interruptResponse: Bool? = nil
    ) {
        self.type = type
        self.eagerness = eagerness
        self.createResponse = createResponse
        self.interruptResponse = interruptResponse
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eagerness
        case createResponse = "create_response"
        case interruptResponse = "interrupt_response"
    }

    public static let semanticConversation = RealtimeTurnDetection(
        type: "semantic_vad",
        eagerness: "low",
        createResponse: true,
        interruptResponse: false
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
