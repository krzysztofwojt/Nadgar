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

public struct ProviderSpeechCapabilities: Equatable, Sendable {
    public var supportsVoiceSelection: Bool { !voices.isEmpty }

    public let models: [OpenAIModelOption]
    public let voices: [RealtimeVoiceOption]

    public init(
        models: [OpenAIModelOption],
        voices: [RealtimeVoiceOption] = []
    ) {
        self.models = models
        self.voices = voices
    }
}

public enum ProviderType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case openAI = "openAI"
    case hermes
    case custom

    public var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI API"
        case .hermes:
            return "Hermes Agent"
        case .custom:
            return "Custom"
        }
    }

    public var supportsAPIKey: Bool {
        switch self {
        case .openAI, .hermes:
            return true
        case .custom:
            return false
        }
    }

    public var supportsResponses: Bool {
        switch self {
        case .openAI, .hermes:
            return true
        case .custom:
            return false
        }
    }

    public var supportsTranscription: Bool {
        switch self {
        case .openAI:
            return true
        case .hermes, .custom:
            return false
        }
    }

    public var supportsSpeech: Bool {
        switch self {
        case .openAI:
            return true
        case .hermes, .custom:
            return false
        }
    }
}

public struct ProviderProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let legacyOpenAIProfileID = "openai-default"
    public static let defaultOpenAIName = "OpenAI API"
    public static let defaultHermesName = "Hermes Agent"
    public static let defaultCustomName = "Custom"
    public static let defaultHermesResponseModel = "hermes-agent"

    public var id: String
    public var type: ProviderType
    public var name: String
    public var createdAt: Date
    public var hasAPIKey: Bool
    public var hermesBaseURL: String
    public var hermesResponseModel: String
    public var hermesResponseModels: [String]

    public init(
        id: String = UUID().uuidString,
        type: ProviderType,
        name: String? = nil,
        createdAt: Date = Date(),
        hasAPIKey: Bool = false,
        hermesBaseURL: String = "",
        hermesResponseModel: String = Self.defaultHermesResponseModel,
        hermesResponseModels: [String] = []
    ) {
        self.id = Self.normalizedID(id)
        self.type = type
        self.name = Self.normalizedName(name, type: type)
        self.createdAt = createdAt
        self.hasAPIKey = hasAPIKey
        self.hermesBaseURL = Self.normalizedHermesBaseURL(hermesBaseURL)
        self.hermesResponseModel = Self.normalizedHermesResponseModel(hermesResponseModel)
        self.hermesResponseModels = Self.normalizedHermesResponseModels(hermesResponseModels)
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

    public mutating func setHermesBaseURL(_ baseURL: String) {
        self.hermesBaseURL = Self.normalizedHermesBaseURL(baseURL)
    }

    public mutating func setHermesResponseModel(_ model: String) {
        self.hermesResponseModel = Self.normalizedHermesResponseModel(model)
    }

    public mutating func setHermesResponseModels(_ models: [String]) {
        self.hermesResponseModels = Self.normalizedHermesResponseModels(models)
    }

    public var hermesV1BaseURL: URL? {
        Self.hermesV1BaseURL(from: hermesBaseURL)
    }

    public var hasValidHermesBaseURL: Bool {
        hermesV1BaseURL != nil
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

        switch type {
        case .openAI:
            return defaultOpenAIName
        case .hermes:
            return defaultHermesName
        case .custom:
            return defaultCustomName
        }
    }

    public static func normalizedHermesBaseURL(_ baseURL: String) -> String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func normalizedHermesResponseModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultHermesResponseModel : trimmed
    }

    public static func normalizedHermesResponseModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let dedupeKey = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(dedupeKey) else { return nil }
            seen.insert(dedupeKey)
            return trimmed
        }
    }

    public static func hermesV1BaseURL(from baseURL: String) -> URL? {
        let normalized = normalizedHermesBaseURL(baseURL)
        guard !normalized.isEmpty,
              var components = URLComponents(string: normalized),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false
        else {
            return nil
        }

        components.query = nil
        components.fragment = nil

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/v1"
        } else if path.split(separator: "/").last != "v1" {
            components.path = "/" + path + "/v1"
        } else {
            components.path = "/" + path
        }

        return components.url
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case createdAt
        case hasAPIKey
        case hermesBaseURL
        case hermesResponseModel
        case hermesResponseModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ProviderType.self, forKey: .type)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            type: type,
            name: try container.decodeIfPresent(String.self, forKey: .name),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            hasAPIKey: try container.decodeIfPresent(Bool.self, forKey: .hasAPIKey) ?? false,
            hermesBaseURL: try container.decodeIfPresent(String.self, forKey: .hermesBaseURL) ?? "",
            hermesResponseModel: try container.decodeIfPresent(String.self, forKey: .hermesResponseModel) ??
                Self.defaultHermesResponseModel,
            hermesResponseModels: try container.decodeIfPresent([String].self, forKey: .hermesResponseModels) ?? []
        )
    }
}

public struct ProviderProfileSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: ProviderType
    public var name: String
    public var hasAPIKey: Bool
    public var hermesBaseURL: String
    public var hermesResponseModel: String
    public var hermesResponseModels: [String]

    public init(profile: ProviderProfile) {
        self.id = profile.id
        self.type = profile.type
        self.name = profile.name
        self.hasAPIKey = profile.hasAPIKey
        self.hermesBaseURL = profile.hermesBaseURL
        self.hermesResponseModel = profile.hermesResponseModel
        self.hermesResponseModels = profile.hermesResponseModels
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case hasAPIKey
        case hermesBaseURL
        case hermesResponseModel
        case hermesResponseModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decode(ProviderType.self, forKey: .type)
        self.name = try container.decode(String.self, forKey: .name)
        self.hasAPIKey = try container.decodeIfPresent(Bool.self, forKey: .hasAPIKey) ?? false
        self.hermesBaseURL = ProviderProfile.normalizedHermesBaseURL(
            try container.decodeIfPresent(String.self, forKey: .hermesBaseURL) ?? ""
        )
        self.hermesResponseModel = ProviderProfile.normalizedHermesResponseModel(
            try container.decodeIfPresent(String.self, forKey: .hermesResponseModel) ??
                ProviderProfile.defaultHermesResponseModel
        )
        self.hermesResponseModels = ProviderProfile.normalizedHermesResponseModels(
            try container.decodeIfPresent([String].self, forKey: .hermesResponseModels) ?? []
        )
    }
}

public struct TaskModelSelection: Codable, Equatable, Hashable, Sendable {
    public var profileID: String
    public var model: String

    public init(profileID: String, model: String) {
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
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
    public var selectedSpeech: TaskModelSelection?
    public var configurationVersion: Int
    public var speechVoicesByProfileID: [String: String]
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
        selectedSpeech: TaskModelSelection? = nil,
        configurationVersion: Int = 0,
        speechVoicesByProfileID: [String: String] = [:],
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
            transcription: selectedTranscription,
            speech: selectedSpeech
        )

        self.hasAPIKey = hasAnySelectedKey || hasAPIKey
        self.model = normalizedModel
        self.transcriptionModel = normalizedTranscriptionModel
        self.providerProfiles = normalizedProfiles
        self.selectedResponse = Self.normalizedSelection(
            selectedResponse,
            fallbackModel: normalizedModel,
            profiles: normalizedProfiles,
            task: .response
        )
        self.selectedTranscription = Self.normalizedSelection(
            selectedTranscription,
            fallbackModel: normalizedTranscriptionModel,
            profiles: normalizedProfiles,
            task: .transcription
        )
        self.selectedSpeech = Self.normalizedSelection(
            selectedSpeech,
            fallbackModel: Self.normalizedTTSModel(ttsModel),
            profiles: normalizedProfiles,
            task: .speech
        )
        self.configurationVersion = max(0, configurationVersion)
        self.speechVoicesByProfileID = Self.normalizedSpeechVoices(
            speechVoicesByProfileID,
            profiles: normalizedProfiles
        )
        self.voice = Self.activeSpeechVoice(
            selectedSpeech: self.selectedSpeech,
            speechVoicesByProfileID: self.speechVoicesByProfileID,
            fallbackVoice: Self.normalizedVoice(voice),
            profiles: normalizedProfiles
        ) ?? Self.normalizedVoice(voice)
        self.instructions = instructions
        self.isAutoReadEnabled = isAutoReadEnabled
        self.shouldIgnoreSilentModeForAutoRead = shouldIgnoreSilentModeForAutoRead
        self.model = self.selectedResponse?.model ?? normalizedModel
        self.transcriptionModel = self.selectedTranscription?.model ?? normalizedTranscriptionModel
        self.ttsModel = self.selectedSpeech?.model ?? Self.normalizedTTSModel(ttsModel)
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
        let selectedSpeech = try container.decodeIfPresent(TaskModelSelection.self, forKey: .selectedSpeech)
        let configurationVersion = try container.decodeIfPresent(Int.self, forKey: .configurationVersion) ?? 0
        let speechVoicesByProfileID = try container.decodeIfPresent(
            [String: String].self,
            forKey: .speechVoicesByProfileID
        ) ?? [:]
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
            selectedSpeech: selectedSpeech,
            configurationVersion: configurationVersion,
            speechVoicesByProfileID: speechVoicesByProfileID,
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

    public static let openAISpeechCapabilities = ProviderSpeechCapabilities(
        models: [
            OpenAIModelOption(apiValue: defaultTTSModel, displayName: "GPT-4o mini TTS")
        ],
        voices: [
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
    )

    public static var supportedSpeechModels: [OpenAIModelOption] {
        openAISpeechCapabilities.models
    }

    public static var supportedVoices: [RealtimeVoiceOption] {
        openAISpeechCapabilities.voices
    }

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

    public var selectedSpeechProfile: ProviderProfile? {
        guard let selectedSpeech else { return nil }
        return profile(id: selectedSpeech.profileID)
    }

    public var selectedResponseContextProviderID: String {
        guard let selectedResponse else { return AssistantProviderIDs.openAI }
        return Self.contextProviderID(for: selectedResponse, profile: profile(id: selectedResponse.profileID))
    }

    public var activeSpeechVoice: String {
        speechVoice(for: selectedSpeech?.profileID) ?? Self.normalizedVoice(voice)
    }

    public func speechCapabilities(for profileID: String?) -> ProviderSpeechCapabilities? {
        guard let profileID,
              let profile = profile(id: profileID)
        else { return nil }
        return Self.speechCapabilities(for: profile)
    }

    public static func speechCapabilities(for profile: ProviderProfile) -> ProviderSpeechCapabilities? {
        switch profile.type {
        case .openAI:
            return openAISpeechCapabilities
        case .hermes, .custom:
            return nil
        }
    }

    public func speechModelOptions(for profileID: String?) -> [OpenAIModelOption] {
        speechCapabilities(for: profileID)?.models ?? []
    }

    public func speechVoiceOptions(for profileID: String?) -> [RealtimeVoiceOption] {
        speechCapabilities(for: profileID)?.voices ?? []
    }

    public func defaultSpeechVoice(for profileID: String?) -> String? {
        let options = speechVoiceOptions(for: profileID)
        guard !options.isEmpty else { return nil }
        if options.contains(where: { $0.apiValue == Self.defaultVoice }) {
            return Self.defaultVoice
        }
        return options.first?.apiValue
    }

    public func speechVoice(for profileID: String?) -> String? {
        let options = speechVoiceOptions(for: profileID)
        guard !options.isEmpty else { return nil }

        if let profileID,
           let voice = speechVoicesByProfileID[profileID] {
            return Self.normalizedVoice(voice, options: options)
        }

        return Self.normalizedVoice(voice, options: options)
    }

    public func profile(id: String) -> ProviderProfile? {
        providerProfiles.first { $0.id == id }
    }

    public func firstOpenAIProfile(withAPIKey: Bool = false) -> ProviderProfile? {
        providerProfiles.first { profile in
            profile.type == .openAI && (!withAPIKey || profile.hasAPIKey)
        }
    }

    public func firstResponseProfile(withAPIKey: Bool = false) -> ProviderProfile? {
        providerProfiles.first { profile in
            profile.type.supportsResponses &&
                (!withAPIKey || profile.hasAPIKey) &&
                (profile.type != .hermes || profile.hasValidHermesBaseURL)
        }
    }

    public func firstSpeechProfile(withAPIKey: Bool = false) -> ProviderProfile? {
        providerProfiles.first { profile in
            Self.speechCapabilities(for: profile)?.models.isEmpty == false &&
                (!withAPIKey || profile.hasAPIKey)
        }
    }

    public mutating func bumpConfigurationVersion() {
        configurationVersion += 1
    }

    public mutating func setAPIKeyStatus(_ hasAPIKey: Bool, for profileID: String) {
        guard let index = providerProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        providerProfiles[index].hasAPIKey = hasAPIKey
        self.hasAPIKey = selectedResponseProfile?.hasAPIKey == true ||
            selectedTranscriptionProfile?.hasAPIKey == true ||
            selectedSpeechProfile?.hasAPIKey == true
    }

    public mutating func normalizeSelectionsAfterProfileChange() {
        if !isExecutableResponseSelection(selectedResponse) {
            selectedResponse = defaultResponseSelection()
        }
        if !isExecutableTranscriptionSelection(selectedTranscription) {
            selectedTranscription = defaultTranscriptionSelection()
        }
        if !isExecutableSpeechSelection(selectedSpeech) {
            selectedSpeech = defaultSpeechSelection()
        }
        speechVoicesByProfileID = Self.normalizedSpeechVoices(
            speechVoicesByProfileID,
            profiles: providerProfiles
        )
        model = selectedResponse?.model ?? Self.defaultModel
        transcriptionModel = selectedTranscription?.model ?? Self.defaultTranscriptionModel
        ttsModel = selectedSpeech?.model ?? Self.defaultTTSModel
        if let activeSpeechVoice = speechVoice(for: selectedSpeech?.profileID) {
            voice = activeSpeechVoice
        } else {
            voice = Self.normalizedVoice(voice)
        }
        hasAPIKey = selectedResponseProfile?.hasAPIKey == true ||
            selectedTranscriptionProfile?.hasAPIKey == true ||
            selectedSpeechProfile?.hasAPIKey == true
    }

    public static func contextProviderID(for selection: TaskModelSelection, profile: ProviderProfile? = nil) -> String {
        switch profile?.type {
        case .hermes:
            return AssistantProviderIDs.hermes(profileID: selection.profileID, model: selection.model)
        case .openAI, .custom, nil:
            return "openai:\(selection.profileID):\(selection.model)"
        }
    }

    public static func normalizedModel(_ model: String) -> String {
        normalizedOptionValue(model, options: supportedAssistantModels, fallback: defaultModel)
    }

    public static func normalizedTranscriptionModel(_ model: String) -> String {
        normalizedOptionValue(model, options: supportedTranscriptionModels, fallback: defaultTranscriptionModel)
    }

    public static func normalizedTTSModel(_ model: String) -> String {
        normalizedOptionValue(model, options: openAISpeechCapabilities.models, fallback: defaultTTSModel)
    }

    public static func normalizedTTSModel(_ model: String, profile: ProviderProfile) -> String {
        guard let capabilities = speechCapabilities(for: profile),
              let fallback = capabilities.models.first?.apiValue
        else { return defaultTTSModel }
        return normalizedOptionValue(model, options: capabilities.models, fallback: fallback)
    }

    public static func normalizedVoice(_ voice: String) -> String {
        normalizedVoice(voice, options: openAISpeechCapabilities.voices)
    }

    public static func normalizedVoice(_ voice: String, options: [RealtimeVoiceOption]) -> String {
        let value = voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let option = options.first(where: { $0.apiValue == value }) {
            return option.apiValue
        }

        if options.contains(where: { $0.apiValue == defaultVoice }) {
            return defaultVoice
        }
        return options.first?.apiValue ?? defaultVoice
    }

    public static func normalizedSpeechVoices(
        _ voices: [String: String],
        profiles: [ProviderProfile]
    ) -> [String: String] {
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return voices.reduce(into: [:]) { result, entry in
            guard let profile = profilesByID[entry.key],
                  let capabilities = speechCapabilities(for: profile),
                  !capabilities.voices.isEmpty
            else { return }
            result[entry.key] = normalizedVoice(entry.value, options: capabilities.voices)
        }
    }

    private static func activeSpeechVoice(
        selectedSpeech: TaskModelSelection?,
        speechVoicesByProfileID: [String: String],
        fallbackVoice: String,
        profiles: [ProviderProfile]
    ) -> String? {
        if let profileID = selectedSpeech?.profileID,
           let profile = profiles.first(where: { $0.id == profileID }),
           let capabilities = speechCapabilities(for: profile),
           !capabilities.voices.isEmpty {
            if let voice = speechVoicesByProfileID[profileID] {
                return normalizedVoice(voice, options: capabilities.voices)
            }
            return normalizedVoice(fallbackVoice, options: capabilities.voices)
        }
        return nil
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
            normalized.setHermesBaseURL(profile.hermesBaseURL)
            normalized.setHermesResponseModel(profile.hermesResponseModel)
            normalized.setHermesResponseModels(profile.hermesResponseModels)
            return normalized
        }
    }

    private static func normalizedSelection(
        _ selection: TaskModelSelection?,
        fallbackModel: String,
        profiles: [ProviderProfile],
        task: SelectionTask
    ) -> TaskModelSelection? {
        let fallbackProfileID = profiles.first(where: { task.supports($0) })?.id
        let profileID = selection?.profileID.nilIfEmpty ?? fallbackProfileID
        guard let profileID,
              let profile = profiles.first(where: { $0.id == profileID }),
              task.supports(profile)
        else {
            return nil
        }

        let model = selection?.model ?? task.fallbackModel(fallbackModel, profile: profile)
        return TaskModelSelection(profileID: profileID, model: task.normalizedModel(model, profile: profile))
    }

    private static func hasAnySelectedKey(
        profiles: [ProviderProfile],
        response: TaskModelSelection?,
        transcription: TaskModelSelection?,
        speech: TaskModelSelection?
    ) -> Bool {
        let ids = Set([response?.profileID, transcription?.profileID, speech?.profileID].compactMap { $0 })
        return profiles.contains { ids.contains($0.id) && $0.hasAPIKey }
    }

    private func isExecutableResponseSelection(_ selection: TaskModelSelection?) -> Bool {
        guard let selection,
              let profile = profile(id: selection.profileID)
        else { return false }
        switch profile.type {
        case .openAI:
            return profile.hasAPIKey &&
                Self.supportedAssistantModels.contains { $0.apiValue == selection.model }
        case .hermes:
            return profile.hasAPIKey &&
                profile.hasValidHermesBaseURL &&
                ProviderProfile.normalizedHermesResponseModel(selection.model) == selection.model &&
                (
                    profile.hermesResponseModels.contains(selection.model) ||
                    ProviderProfile.normalizedHermesResponseModel(profile.hermesResponseModel) == selection.model
                )
        case .custom:
            return false
        }
    }

    private func isExecutableTranscriptionSelection(_ selection: TaskModelSelection?) -> Bool {
        guard let selection,
              let profile = profile(id: selection.profileID)
        else { return false }
        return profile.type == .openAI && profile.hasAPIKey &&
            Self.supportedTranscriptionModels.contains { $0.apiValue == selection.model }
    }

    private func isExecutableSpeechSelection(_ selection: TaskModelSelection?) -> Bool {
        guard let selection,
              let profile = profile(id: selection.profileID),
              let capabilities = Self.speechCapabilities(for: profile)
        else { return false }
        return profile.hasAPIKey &&
            capabilities.models.contains { $0.apiValue == selection.model }
    }

    private func defaultResponseSelection() -> TaskModelSelection? {
        guard let profile = firstResponseProfile(withAPIKey: true) else { return nil }
        switch profile.type {
        case .openAI:
            return TaskModelSelection(profileID: profile.id, model: Self.defaultModel)
        case .hermes:
            return TaskModelSelection(profileID: profile.id, model: profile.hermesResponseModel)
        case .custom:
            return nil
        }
    }

    private func defaultTranscriptionSelection() -> TaskModelSelection? {
        guard let profile = firstOpenAIProfile(withAPIKey: true) else { return nil }
        return TaskModelSelection(profileID: profile.id, model: Self.defaultTranscriptionModel)
    }

    private func defaultSpeechSelection() -> TaskModelSelection? {
        guard let profile = firstSpeechProfile(withAPIKey: true),
              let model = Self.speechCapabilities(for: profile)?.models.first?.apiValue
        else { return nil }
        return TaskModelSelection(profileID: profile.id, model: model)
    }

    private enum SelectionTask {
        case response
        case transcription
        case speech

        func supports(_ profile: ProviderProfile) -> Bool {
            switch self {
            case .response:
                return profile.type.supportsResponses
            case .transcription:
                return profile.type.supportsTranscription
            case .speech:
                return ProviderSettings.speechCapabilities(for: profile)?.models.isEmpty == false
            }
        }

        func normalizedModel(_ model: String, profile: ProviderProfile) -> String {
            switch self {
            case .response:
                switch profile.type {
                case .openAI:
                    return ProviderSettings.normalizedOptionValue(
                        model,
                        options: ProviderSettings.supportedAssistantModels,
                        fallback: ProviderSettings.defaultModel
                    )
                case .hermes:
                    return ProviderProfile.normalizedHermesResponseModel(model)
                case .custom:
                    return ProviderSettings.defaultModel
                }
            case .transcription:
                return ProviderSettings.normalizedOptionValue(
                    model,
                    options: ProviderSettings.supportedTranscriptionModels,
                    fallback: ProviderSettings.defaultTranscriptionModel
                )
            case .speech:
                return ProviderSettings.normalizedTTSModel(model, profile: profile)
            }
        }

        func fallbackModel(_ fallback: String, profile: ProviderProfile) -> String {
            switch self {
            case .response where profile.type == .hermes:
                return profile.hermesResponseModel
            case .response, .transcription, .speech:
                return fallback
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
