import Foundation

public enum AuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAIAPIKey
    case chatGPTCodexUnavailable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAIAPIKey:
            return "OpenAI API Key"
        case .chatGPTCodexUnavailable:
            return "ChatGPT/Codex"
        }
    }
}
