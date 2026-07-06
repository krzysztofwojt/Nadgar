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

public struct OpenAIModelOption: Equatable, Hashable, Identifiable, Sendable {
    public var id: String { apiValue }

    public let apiValue: String
    public let displayName: String

    public init(apiValue: String, displayName: String) {
        self.apiValue = apiValue
        self.displayName = displayName
    }
}

public enum ProviderType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case openAI = "openAI"
    case custom

    public var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI API"
        case .custom:
            return "Custom"
        }
    }
}

public struct ProviderProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let legacyOpenAIProfileID = "openai-default"
    public static let defaultOpenAIName = "OpenAI API"
    public static let defaultCustomName = "Custom"

    public var id: String
    public var type: ProviderType
    public var name: String
    public var createdAt: Date
    public var hasAPIKey: Bool

    public init(
        id: String = UUID().uuidString,
        type: ProviderType,
        name: String? = nil,
        createdAt: Date = Date(),
        hasAPIKey: Bool = false
    ) {
        self.id = Self.normalizedID(id)
        self.type = type
        self.name = Self.normalizedName(name, type: type)
        self.createdAt = createdAt
        self.hasAPIKey = hasAPIKey
    }

    public static func legacyOpenAIProfile(hasAPIKey: Bool = false) -> ProviderProfile {
        ProviderProfile(
            id: legacyOpenAIProfileID,
            type: .openAI,
            name: defaultOpenAIName,
            createdAt: Date(timeIntervalSince1970: 0),
            hasAPIKey: hasAPIKey
        )
    }

    public mutating func setName(_ name: String) {
        self.name = Self.normalizedName(name, type: type)
    }

    private static func normalizedID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? UUID().uuidString : trimmed
    }

    private static func normalizedName(_ name: String?, type: ProviderType) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        return type == .openAI ? defaultOpenAIName : defaultCustomName
    }
}

public struct ProviderProfileSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: ProviderType
    public var name: String
    public var hasAPIKey: Bool

    public init(profile: ProviderProfile) {
        self.id = profile.id
        self.type = profile.type
        self.name = profile.name
        self.hasAPIKey = profile.hasAPIKey
    }
}

public struct TaskModelSelection: Codable, Equatable, Hashable, Sendable {
    public var profileID: String
    public var model: String

    public init(profileID: String, model: String) {
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct ProviderSettings: Codable, Equatable, Sendable {
    public var selectedAuthMode: AuthMode
    public var hasAPIKey: Bool
    public var model: String
    public var transcriptionModel: String
    public var providerProfiles: [ProviderProfile]
    public var selectedResponse: TaskModelSelection?
    public var selectedTranscription: TaskModelSelection?
    public var configurationVersion: Int
    public var voice: String
    public var instructions: String
    public var isAutoReadEnabled: Bool
    public var shouldIgnoreSilentModeForAutoRead: Bool
    public var ttsModel: String

    public init(
        selectedAuthMode: AuthMode = .openAIAPIKey,
        hasAPIKey: Bool = false,
        model: String = Self.defaultModel,
        transcriptionModel: String = Self.defaultTranscriptionModel,
        providerProfiles: [ProviderProfile]? = nil,
        selectedResponse: TaskModelSelection? = nil,
        selectedTranscription: TaskModelSelection? = nil,
        configurationVersion: Int = 0,
        voice: String = Self.defaultVoice,
        instructions: String = Self.defaultInstructions,
        isAutoReadEnabled: Bool = false,
        shouldIgnoreSilentModeForAutoRead: Bool = false,
        ttsModel: String = Self.defaultTTSModel
    ) {
        self.selectedAuthMode = selectedAuthMode
        let normalizedModel = Self.normalizedModel(model)
        let normalizedTranscriptionModel = Self.normalizedTranscriptionModel(transcriptionModel)
        var normalizedProfiles = providerProfiles ?? [ProviderProfile.legacyOpenAIProfile(hasAPIKey: hasAPIKey)]
        normalizedProfiles = Self.normalizedProfiles(normalizedProfiles)
        let hasAnySelectedKey = Self.hasAnySelectedKey(
            profiles: normalizedProfiles,
            response: selectedResponse,
            transcription: selectedTranscription
        )

        self.hasAPIKey = hasAnySelectedKey || hasAPIKey
        self.model = normalizedModel
        self.transcriptionModel = normalizedTranscriptionModel
        self.providerProfiles = normalizedProfiles
        self.selectedResponse = Self.normalizedSelection(
            selectedResponse,
            fallbackModel: normalizedModel,
            profiles: normalizedProfiles,
            options: Self.supportedAssistantModels
        )
        self.selectedTranscription = Self.normalizedSelection(
            selectedTranscription,
            fallbackModel: normalizedTranscriptionModel,
            profiles: normalizedProfiles,
            options: Self.supportedTranscriptionModels
        )
        self.configurationVersion = max(0, configurationVersion)
        self.voice = Self.normalizedVoice(voice)
        self.instructions = instructions
        self.isAutoReadEnabled = isAutoReadEnabled
        self.shouldIgnoreSilentModeForAutoRead = shouldIgnoreSilentModeForAutoRead
        self.ttsModel = Self.normalizedTTSModel(ttsModel)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let selectedAuthMode = try container.decodeIfPresent(AuthMode.self, forKey: .selectedAuthMode) ?? .openAIAPIKey
        let hasAPIKey = try container.decodeIfPresent(Bool.self, forKey: .hasAPIKey) ?? false
        let model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
        let transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel)
            ?? Self.defaultTranscriptionModel
        let providerProfiles = try container.decodeIfPresent([ProviderProfile].self, forKey: .providerProfiles)
        let selectedResponse = try container.decodeIfPresent(TaskModelSelection.self, forKey: .selectedResponse)
        let selectedTranscription = try container.decodeIfPresent(TaskModelSelection.self, forKey: .selectedTranscription)
        let configurationVersion = try container.decodeIfPresent(Int.self, forKey: .configurationVersion) ?? 0
        let voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? Self.defaultVoice
        let instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? Self.defaultInstructions
        let isAutoReadEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoReadEnabled) ?? false
        let shouldIgnoreSilentModeForAutoRead = try container.decodeIfPresent(Bool.self, forKey: .shouldIgnoreSilentModeForAutoRead) ?? false
        let ttsModel = try container.decodeIfPresent(String.self, forKey: .ttsModel) ?? Self.defaultTTSModel

        self.init(
            selectedAuthMode: selectedAuthMode,
            hasAPIKey: hasAPIKey,
            model: model,
            transcriptionModel: transcriptionModel,
            providerProfiles: providerProfiles,
            selectedResponse: selectedResponse,
            selectedTranscription: selectedTranscription,
            configurationVersion: configurationVersion,
            voice: voice,
            instructions: instructions,
            isAutoReadEnabled: isAutoReadEnabled,
            shouldIgnoreSilentModeForAutoRead: shouldIgnoreSilentModeForAutoRead,
            ttsModel: ttsModel
        )
    }

    public static let defaultModel = StandalonePTTDefaults.assistantModel
    public static let defaultTranscriptionModel = StandalonePTTDefaults.transcriptionModel
    public static let defaultTTSModel = StandalonePTTDefaults.speechModel
    public static let defaultVoice = "marin"
    public static let defaultInstructions = "You are Nadgar, a concise voice assistant on Apple Watch. Answer briefly unless the user asks for detail."

    public static let supportedAssistantModels = [
        OpenAIModelOption(apiValue: "gpt-5.4-nano", displayName: "GPT-5.4 nano"),
        OpenAIModelOption(apiValue: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
        OpenAIModelOption(apiValue: "gpt-5.4", displayName: "GPT-5.4"),
        OpenAIModelOption(apiValue: "gpt-5.5", displayName: "GPT-5.5")
    ]

    public static let supportedTranscriptionModels = [
        OpenAIModelOption(apiValue: "gpt-4o-mini-transcribe", displayName: "GPT-4o mini Transcribe"),
        OpenAIModelOption(apiValue: "gpt-4o-transcribe", displayName: "GPT-4o Transcribe")
    ]

    public static let supportedVoices = [
        RealtimeVoiceOption(apiValue: "alloy", displayName: "Alloy"),
        RealtimeVoiceOption(apiValue: "ash", displayName: "Ash"),
        RealtimeVoiceOption(apiValue: "ballad", displayName: "Ballad"),
        RealtimeVoiceOption(apiValue: "coral", displayName: "Coral"),
        RealtimeVoiceOption(apiValue: "echo", displayName: "Echo"),
        RealtimeVoiceOption(apiValue: "fable", displayName: "Fable"),
        RealtimeVoiceOption(apiValue: "nova", displayName: "Nova"),
        RealtimeVoiceOption(apiValue: "onyx", displayName: "Onyx"),
        RealtimeVoiceOption(apiValue: "sage", displayName: "Sage"),
        RealtimeVoiceOption(apiValue: "shimmer", displayName: "Shimmer"),
        RealtimeVoiceOption(apiValue: "verse", displayName: "Verse"),
        RealtimeVoiceOption(apiValue: "marin", displayName: "Marin"),
        RealtimeVoiceOption(apiValue: "cedar", displayName: "Cedar")
    ]

    public static let `default` = ProviderSettings()

    public var providerSummaries: [ProviderProfileSummary] {
        providerProfiles.map(ProviderProfileSummary.init(profile:))
    }

    public var selectedResponseProfile: ProviderProfile? {
        guard let selectedResponse else { return nil }
        return profile(id: selectedResponse.profileID)
    }

    public var selectedTranscriptionProfile: ProviderProfile? {
        guard let selectedTranscription else { return nil }
        return profile(id: selectedTranscription.profileID)
    }

    public var selectedResponseContextProviderID: String {
        guard let selectedResponse else { return AssistantProviderIDs.openAI }
        return Self.contextProviderID(for: selectedResponse)
    }

    public func profile(id: String) -> ProviderProfile? {
        providerProfiles.first { $0.id == id }
    }

    public func firstOpenAIProfile(withAPIKey: Bool = false) -> ProviderProfile? {
        providerProfiles.first { profile in
            profile.type == .openAI && (!withAPIKey || profile.hasAPIKey)
        }
    }

    public mutating func bumpConfigurationVersion() {
        configurationVersion += 1
    }

    public mutating func setAPIKeyStatus(_ hasAPIKey: Bool, for profileID: String) {
        guard let index = providerProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        providerProfiles[index].hasAPIKey = hasAPIKey
        self.hasAPIKey = selectedResponseProfile?.hasAPIKey == true || selectedTranscriptionProfile?.hasAPIKey == true
    }

    public mutating func normalizeSelectionsAfterProfileChange() {
        if !isExecutableResponseSelection(selectedResponse) {
            selectedResponse = defaultResponseSelection()
        }
        if !isExecutableTranscriptionSelection(selectedTranscription) {
            selectedTranscription = defaultTranscriptionSelection()
        }
        model = selectedResponse?.model ?? Self.defaultModel
        transcriptionModel = selectedTranscription?.model ?? Self.defaultTranscriptionModel
        hasAPIKey = selectedResponseProfile?.hasAPIKey == true || selectedTranscriptionProfile?.hasAPIKey == true
    }

    public static func contextProviderID(for selection: TaskModelSelection) -> String {
        "openai:\(selection.profileID):\(selection.model)"
    }

    public static func normalizedModel(_ model: String) -> String {
        normalizedOptionValue(model, options: supportedAssistantModels, fallback: defaultModel)
    }

    public static func normalizedTranscriptionModel(_ model: String) -> String {
        normalizedOptionValue(model, options: supportedTranscriptionModels, fallback: defaultTranscriptionModel)
    }

    public static func normalizedTTSModel(_ model: String) -> String {
        defaultTTSModel
    }

    public static func normalizedVoice(_ voice: String) -> String {
        let value = voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedVoices.contains(where: { $0.apiValue == value }) else {
            return defaultVoice
        }

        return value
    }

    private static func normalizedOptionValue(
        _ value: String,
        options: [OpenAIModelOption],
        fallback: String
    ) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let option = options.first(where: { $0.apiValue == normalized }) else {
            return fallback
        }

        return option.apiValue
    }

    private static func normalizedProfiles(_ profiles: [ProviderProfile]) -> [ProviderProfile] {
        var seen = Set<String>()
        return profiles.compactMap { profile in
            guard !seen.contains(profile.id) else { return nil }
            seen.insert(profile.id)
            var normalized = profile
            normalized.setName(profile.name)
            return normalized
        }
    }

    private static func normalizedSelection(
        _ selection: TaskModelSelection?,
        fallbackModel: String,
        profiles: [ProviderProfile],
        options: [OpenAIModelOption]
    ) -> TaskModelSelection? {
        let fallbackProfileID = profiles.first(where: { $0.type == .openAI })?.id
        let profileID = selection?.profileID.nilIfEmpty ?? fallbackProfileID
        guard let profileID,
              profiles.contains(where: { $0.id == profileID && $0.type == .openAI })
        else {
            return nil
        }

        return TaskModelSelection(
            profileID: profileID,
            model: normalizedOptionValue(selection?.model ?? fallbackModel, options: options, fallback: fallbackModel)
        )
    }

    private static func hasAnySelectedKey(
        profiles: [ProviderProfile],
        response: TaskModelSelection?,
        transcription: TaskModelSelection?
    ) -> Bool {
        let ids = Set([response?.profileID, transcription?.profileID].compactMap { $0 })
        return profiles.contains { ids.contains($0.id) && $0.hasAPIKey }
    }

    private func isExecutableResponseSelection(_ selection: TaskModelSelection?) -> Bool {
        guard let selection,
              let profile = profile(id: selection.profileID)
        else { return false }
        return profile.type == .openAI && profile.hasAPIKey &&
            Self.supportedAssistantModels.contains { $0.apiValue == selection.model }
    }

    private func isExecutableTranscriptionSelection(_ selection: TaskModelSelection?) -> Bool {
        guard let selection,
              let profile = profile(id: selection.profileID)
        else { return false }
        return profile.type == .openAI && profile.hasAPIKey &&
            Self.supportedTranscriptionModels.contains { $0.apiValue == selection.model }
    }

    private func defaultResponseSelection() -> TaskModelSelection? {
        guard let profile = firstOpenAIProfile(withAPIKey: true) else { return nil }
        return TaskModelSelection(profileID: profile.id, model: Self.defaultModel)
    }

    private func defaultTranscriptionSelection() -> TaskModelSelection? {
        guard let profile = firstOpenAIProfile(withAPIKey: true) else { return nil }
        return TaskModelSelection(profileID: profile.id, model: Self.defaultTranscriptionModel)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
