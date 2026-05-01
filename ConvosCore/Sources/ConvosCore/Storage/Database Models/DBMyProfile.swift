import Foundation
import GRDB

/// The local user's intended global profile, keyed by `inboxId`.
struct DBMyProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "myProfile"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let imageData: Column = Column(CodingKeys.imageData)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    let name: String?
    let imageData: Data?
    let metadata: ProfileMetadata?
    let updatedAt: Date

    init(
        inboxId: String,
        name: String? = nil,
        imageData: Data? = nil,
        metadata: ProfileMetadata? = nil,
        updatedAt: Date = Date()
    ) {
        self.inboxId = inboxId
        self.name = name
        self.imageData = imageData
        self.metadata = metadata
        self.updatedAt = updatedAt
    }
}
