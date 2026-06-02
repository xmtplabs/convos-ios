import Foundation
import GRDB

/// A message id that a `BuilderBundleManifest` flagged as part of an
/// agent-builder bundle. Persisted so every client (not just the bundle's
/// sender) can filter the brief out of the chat, and so the filter survives
/// relaunch and applies to bundle messages that arrive after the manifest.
struct DBBuilderBundleHiddenMessage: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName: String = "builder_bundle_hidden_message"

    let conversationId: String
    let messageId: String

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let messageId: Column = Column(CodingKeys.messageId)
    }
}
