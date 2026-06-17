import Foundation

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
        self.model = model
        self.voice = voice
        self.instructions = instructions
    }

    public static let defaultModel = "gpt-realtime-2"
    public static let defaultVoice = "marin"
    public static let defaultInstructions = "You are WristAssist, a concise voice assistant on Apple Watch. Answer briefly unless the user asks for detail."

    public static let `default` = ProviderSettings()
}
