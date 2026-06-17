import Foundation

public struct RealtimeVoiceOption: Equatable, Hashable, Identifiable, Sendable {
    public var id: String { apiValue }

    public let apiValue: String
    public let displayName: String

    public init(apiValue: String, displayName: String) {
        self.apiValue = apiValue
        self.displayName = displayName
    }
}

public struct ProviderSettings: Codable, Equatable, Sendable {
    public var selectedAuthMode: AuthMode
    public var hasAPIKey: Bool
    public var model: String
    public var voice: String
    public var instructions: String

    public init(
        selectedAuthMode: AuthMode = .openAIAPIKey,
        hasAPIKey: Bool = false,
        model: String = Self.defaultModel,
        voice: String = Self.defaultVoice,
        instructions: String = Self.defaultInstructions
    ) {
        self.selectedAuthMode = selectedAuthMode
        self.hasAPIKey = hasAPIKey
        self.model = Self.normalizedModel(model)
        self.voice = Self.normalizedVoice(voice)
        self.instructions = instructions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let selectedAuthMode = try container.decodeIfPresent(AuthMode.self, forKey: .selectedAuthMode) ?? .openAIAPIKey
        let hasAPIKey = try container.decodeIfPresent(Bool.self, forKey: .hasAPIKey) ?? false
        let model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
        let voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? Self.defaultVoice
        let instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? Self.defaultInstructions

        self.init(
            selectedAuthMode: selectedAuthMode,
            hasAPIKey: hasAPIKey,
            model: model,
            voice: voice,
            instructions: instructions
        )
    }

    public static let defaultModel = "gpt-realtime-2"
    public static let defaultVoice = "marin"
    public static let defaultInstructions = "You are WristAssist, a concise voice assistant on Apple Watch. Answer briefly unless the user asks for detail."

    public static let supportedVoices = [
        RealtimeVoiceOption(apiValue: "alloy", displayName: "Alloy"),
        RealtimeVoiceOption(apiValue: "ash", displayName: "Ash"),
        RealtimeVoiceOption(apiValue: "ballad", displayName: "Ballad"),
        RealtimeVoiceOption(apiValue: "coral", displayName: "Coral"),
        RealtimeVoiceOption(apiValue: "echo", displayName: "Echo"),
        RealtimeVoiceOption(apiValue: "sage", displayName: "Sage"),
        RealtimeVoiceOption(apiValue: "shimmer", displayName: "Shimmer"),
        RealtimeVoiceOption(apiValue: "verse", displayName: "Verse"),
        RealtimeVoiceOption(apiValue: "marin", displayName: "Marin"),
        RealtimeVoiceOption(apiValue: "cedar", displayName: "Cedar")
    ]

    public static let `default` = ProviderSettings()

    public static func normalizedModel(_ model: String) -> String {
        defaultModel
    }

    public static func normalizedVoice(_ voice: String) -> String {
        let value = voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedVoices.contains(where: { $0.apiValue == value }) else {
            return defaultVoice
        }

        return value
    }
}
