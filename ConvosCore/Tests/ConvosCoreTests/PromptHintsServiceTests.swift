@testable import ConvosCore
import Foundation
import Testing

@Suite("PromptHintsService")
struct PromptHintsServiceTests {
    @Test("returns the hints the API client serves")
    func returnsHintsFromAPIClient() async throws {
        let service = PromptHintsService(apiClient: MockAPIClient())
        let hints = try await service.promptHints()
        #expect(!hints.isEmpty)
    }

    @Test("decodes the { hints: [...] } envelope into a flat array")
    func decodesHintsEnvelope() throws {
        let json = Data(#"{"hints":["one","two","three"]}"#.utf8)
        let response = try JSONDecoder().decode(ConvosAPI.AgentPromptHintsResponse.self, from: json)
        #expect(response.hints == ["one", "two", "three"])
    }

    @Test("mock service records call count and serves its hints")
    func mockServiceServesHints() async throws {
        let mock = MockPromptHintsService(hints: ["a", "b"])
        let hints = try await mock.promptHints()
        #expect(hints == ["a", "b"])
        #expect(mock.fetchCount == 1)
    }

    @Test("mock service throws the supplied error")
    func mockServiceThrows() async {
        struct SampleError: Error {}
        let mock = MockPromptHintsService(error: SampleError())
        await #expect(throws: SampleError.self) {
            _ = try await mock.promptHints()
        }
    }
}
