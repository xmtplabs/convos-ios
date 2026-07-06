import Foundation
import GRDB

/// One persisted generation media input. `objectKey` is
/// filled once the eager upload to the agent-templates presigned endpoint
/// completes; `localPath` is a stable copy kept so a resumed build can
/// re-upload if the object key expires before submit. These are plaintext
/// references, not XMTP attachments.
struct StoredGenerationAttachment: Codable, Hashable {
    var objectKey: String?
    let mimeType: String
    let filename: String?
    let localPath: String
}

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
        static let previewAgentName: Column = Column(CodingKeys.previewAgentName)
        static let previewEmoji: Column = Column(CodingKeys.previewEmoji)
        static let previewDescription: Column = Column(CodingKeys.previewDescription)
        static let progressPhrases: Column = Column(CodingKeys.progressPhrases)
        static let attachments: Column = Column(CodingKeys.attachments)
        static let connections: Column = Column(CodingKeys.connections)
        static let variantId: Column = Column(CodingKeys.variantId)
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
    /// In-progress draft identity, persisted so a pending card survives
    /// relaunch. `nil` until a preview lands.
    var previewAgentName: String?
    var previewEmoji: String?
    var previewDescription: String?
    /// JSON-encoded `[String]` of in-progress narration lines.
    var progressPhrases: String?
    /// JSON-encoded `[StoredGenerationAttachment]` of media inputs. `nil` for
    /// text-only builds.
    var attachments: String?
    /// JSON-encoded `[String]` of neutral connection service ids sent in the
    /// generation request. Persisted so a resumed/retried submit sends an
    /// identical body and dedupes. `nil` when no connections.
    var connections: String?
    /// Dev-only agent variant slug captured once at build start. The same value
    /// rides the generation (top-level field), join (`options.variantId`), and
    /// join-status poll (`?variantId=`) calls; reading it off the row keeps all
    /// three consistent even when the build resumes after a relaunch. `nil` for
    /// default builds.
    let variantId: String?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case idempotencyKey, generationId, conversationId, slug, status
        case templateId, prompt
        case errorMessage = "error"
        case previewAgentName, previewEmoji, previewDescription, progressPhrases
        case attachments, connections, variantId
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
        previewAgentName: String? = nil,
        previewEmoji: String? = nil,
        previewDescription: String? = nil,
        progressPhrases: String? = nil,
        attachments: String? = nil,
        connections: String? = nil,
        variantId: String? = nil,
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
        self.previewAgentName = previewAgentName
        self.previewEmoji = previewEmoji
        self.previewDescription = previewDescription
        self.progressPhrases = progressPhrases
        self.attachments = attachments
        self.connections = connections
        self.variantId = variantId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var statusValue: Status {
        Status(rawValue: status) ?? .pending
    }
}
