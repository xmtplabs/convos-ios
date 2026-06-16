import Foundation
import GRDB

/// Persistent record of an in-flight (or finished) agent-template generation
/// kicked off by the direct builder flow. The repository owns this row and is
/// its single writer; persisting it before the network call means a build
/// survives sheet dismissal and app restart, and the repository can resume
/// polling or re-issue the invite on relaunch instead of orphaning it.
///
/// Keyed by the client-generated `idempotencyKey` so the row is stable before
/// the server responds; the server's `generationId` is filled in after the
/// submit. `status` mirrors the server lifecycle plus client-only `submitting`
/// (pre-POST) and `invited` (generation done, agent-join issued) states.
struct DBAgentTemplateGeneration: Codable, FetchableRecord, PersistableRecord, Hashable, Identifiable {
    static let databaseTableName: String = "agentTemplateGeneration"

    enum Columns {
        static let idempotencyKey: Column = Column(CodingKeys.idempotencyKey)
        static let generationId: Column = Column(CodingKeys.generationId)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let slug: Column = Column(CodingKeys.slug)
        static let status: Column = Column(CodingKeys.status)
        static let templateId: Column = Column(CodingKeys.templateId)
        static let prompt: Column = Column(CodingKeys.prompt)
        static let errorMessage: Column = Column(CodingKeys.errorMessage)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    /// Client-side lifecycle. `submitting` is the pre-`POST` state. `pending`
    /// and `running` mirror the server. `done` means the template exists;
    /// `invited` means the agent-join was issued; `failed` is terminal failure.
    enum Status: String, Codable {
        case submitting
        case pending
        case running
        case done
        case invited
        case failed

        var isTerminal: Bool {
            self == .invited || self == .failed
        }
    }

    var id: String { idempotencyKey }

    let idempotencyKey: String
    /// Server generation id, `nil` until the submit response lands.
    var generationId: String?
    let conversationId: String
    let slug: String
    var status: String
    var templateId: String?
    let prompt: String
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case idempotencyKey, generationId, conversationId, slug, status
        case templateId, prompt
        case errorMessage = "error"
        case createdAt, updatedAt
    }

    init(
        idempotencyKey: String,
        generationId: String?,
        conversationId: String,
        slug: String,
        status: Status,
        templateId: String?,
        prompt: String,
        errorMessage: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.idempotencyKey = idempotencyKey
        self.generationId = generationId
        self.conversationId = conversationId
        self.slug = slug
        self.status = status.rawValue
        self.templateId = templateId
        self.prompt = prompt
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var statusValue: Status {
        Status(rawValue: status) ?? .pending
    }
}
