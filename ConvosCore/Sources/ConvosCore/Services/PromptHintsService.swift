import Foundation

/// Fetches curated agent prompt hints for the agent builder's dice control.
/// A narrow seam over `ConvosAPIClientProtocol` so the in-memory cache model
/// can be driven by a stub in previews and tests without conforming to the
/// full API client surface. Mirrors `SuggestedAgentsServiceProtocol`.
public protocol PromptHintsServiceProtocol: Sendable {
    func promptHints() async throws -> [String]
}

public final class PromptHintsService: PromptHintsServiceProtocol {
    private let apiClient: any ConvosAPIClientProtocol

    public init(apiClient: any ConvosAPIClientProtocol) {
        self.apiClient = apiClient
    }

    public func promptHints() async throws -> [String] {
        try await apiClient.getAgentPromptHints()
    }
}
