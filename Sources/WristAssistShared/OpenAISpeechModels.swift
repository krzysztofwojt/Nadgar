import Foundation

public struct OpenAISpeechRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var input: String
    public var voice: String
    public var responseFormat: String
    public var streamFormat: String

    public init(
        model: String = StandalonePTTDefaults.speechModel,
        input: String,
        voice: String = ProviderSettings.defaultVoice,
        responseFormat: String = "pcm",
        streamFormat: String = "audio"
    ) {
        self.model = ProviderSettings.normalizedTTSModel(model)
        self.input = input
        self.voice = ProviderSettings.normalizedVoice(voice)
        self.responseFormat = responseFormat
        self.streamFormat = streamFormat
    }

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case streamFormat = "stream_format"
    }
}
