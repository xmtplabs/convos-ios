import Foundation
import GRDB

struct AttachmentLocalState: FetchableRecord, PersistableRecord, Codable, Hashable {
    static let databaseTableName: String = "attachmentLocalState"

    enum Columns {
        static let attachmentKey: Column = Column(CodingKeys.attachmentKey)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let isRevealed: Column = Column(CodingKeys.isRevealed)
        static let revealedAt: Column = Column(CodingKeys.revealedAt)
        static let width: Column = Column(CodingKeys.width)
        static let height: Column = Column(CodingKeys.height)
        static let isHiddenByOwner: Column = Column(CodingKeys.isHiddenByOwner)
    }

    let attachmentKey: String
    let conversationId: String
    let isRevealed: Bool
    let revealedAt: Date?
    let width: Int?
    let height: Int?
    let isHiddenByOwner: Bool

    static let conversationForeignKey: ForeignKey = ForeignKey([Columns.conversationId], to: [DBConversation.Columns.id])
    static let conversation: BelongsToAssociation<AttachmentLocalState, DBConversation> = belongsTo(DBConversation.self, using: conversationForeignKey)

    init(
        attachmentKey: String,
        conversationId: String,
        isRevealed: Bool = true,
        revealedAt: Date? = nil,
        width: Int? = nil,
        height: Int? = nil,
        isHiddenByOwner: Bool = false
    ) {
        self.attachmentKey = attachmentKey
        self.conversationId = conversationId
        self.isRevealed = isRevealed
        self.revealedAt = revealedAt
        self.width = width
        self.height = height
        self.isHiddenByOwner = isHiddenByOwner
    }
}
