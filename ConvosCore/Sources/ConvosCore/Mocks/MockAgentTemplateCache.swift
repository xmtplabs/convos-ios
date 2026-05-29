import Foundation

public final class MockAgentTemplateCacheWriter: AgentTemplateCacheWriterProtocol, @unchecked Sendable {
    public init() {}

    public func upsert(_ response: ConvosAPI.AgentTemplateResponse, fetchedAt: Date) async throws {}
}
