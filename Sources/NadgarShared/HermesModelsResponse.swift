import Foundation

public struct HermesModelsResponse: Decodable, Equatable, Sendable {
    public var modelIDs: [String]

    public init(modelIDs: [String]) {
        self.modelIDs = ProviderProfile.normalizedHermesResponseModels(modelIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }

    private struct Model: Decodable {
        var id: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let models = try container.decode([Model].self, forKey: .data)
        self.modelIDs = ProviderProfile.normalizedHermesResponseModels(models.compactMap(\.id))
    }
}
