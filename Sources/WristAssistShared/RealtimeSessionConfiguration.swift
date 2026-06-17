import Foundation

public struct RealtimeSessionConfiguration: Codable, Equatable, Sendable {
    public var session: RealtimeSession

    public init(session: RealtimeSession) {
        self.session = session
    }

    public init(settings: ProviderSettings) {
        self.session = RealtimeSession(settings: settings)
    }
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

    public init(settings: ProviderSettings) {
        self.init(
            model: settings.model,
            audio: RealtimeAudioConfiguration(voice: settings.voice),
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

    public init(voice: String) {
        self.init(output: RealtimeAudioOutput(voice: voice))
    }
}

public struct RealtimeAudioInput: Codable, Equatable, Sendable {
    public var format: RealtimeAudioFormat
    public var turnDetection: RealtimeTurnDetection

    public init(
        format: RealtimeAudioFormat = RealtimeAudioFormat(type: "audio/pcm", rate: 24_000),
        turnDetection: RealtimeTurnDetection = RealtimeTurnDetection(type: "semantic_vad")
    ) {
        self.format = format
        self.turnDetection = turnDetection
    }

    enum CodingKeys: String, CodingKey {
        case format
        case turnDetection = "turn_detection"
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
    public var createResponse: Bool?
    public var interruptResponse: Bool?

    public init(
        type: String,
        createResponse: Bool? = nil,
        interruptResponse: Bool? = nil
    ) {
        self.type = type
        self.createResponse = createResponse
        self.interruptResponse = interruptResponse
    }

    enum CodingKeys: String, CodingKey {
        case type
        case createResponse = "create_response"
        case interruptResponse = "interrupt_response"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
