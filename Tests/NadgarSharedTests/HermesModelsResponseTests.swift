import Foundation
import Testing
@testable import NadgarShared

struct HermesModelsResponseTests {
    @Test func decodesOpenAICompatibleModelsList() throws {
        let data = """
        {
          "object": "list",
          "data": [
            { "id": " Hermes-Agent " },
            { "id": "gpt-oss" },
            { "id": "HERMES-AGENT" },
            { "object": "model" },
            { "id": "" }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(HermesModelsResponse.self, from: data)

        #expect(response.modelIDs == ["hermes-agent", "gpt-oss"])
    }

    @Test func decodesEmptyModelsList() throws {
        let data = """
        {
          "data": []
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(HermesModelsResponse.self, from: data)

        #expect(response.modelIDs.isEmpty)
    }

    @Test func invalidModelsShapeThrows() {
        let data = """
        {
          "models": []
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HermesModelsResponse.self, from: data)
        }
    }
}
