import Foundation
import GRDB

public protocol AgentTemplateCacheWriterProtocol: Sendable {
    /// Upserts the cached canonical identity for a template (most-recent
    /// fetch wins). Called by `AgentTemplateCacheCoordinator` after a
    /// successful `GET /api/v2/agent-templates/{id}`.
    func upsert(_ response: ConvosAPI.AgentTemplateResponse, fetchedAt: Date) async throws
}

final class AgentTemplateCacheWriter: AgentTemplateCacheWriterProtocol {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func upsert(_ response: ConvosAPI.AgentTemplateResponse, fetchedAt: Date) async throws {
        let row = DBAgentTemplate(
            templateId: response.id,
            agentName: response.agentName,
            emoji: response.emoji,
            avatarURL: response.avatarUrl,
            publishedURL: response.publishedUrl,
            fetchedAt: fetchedAt
        )
        try await databaseWriter.write { db in
            try row.save(db, onConflict: .replace)
        }
    }
}
