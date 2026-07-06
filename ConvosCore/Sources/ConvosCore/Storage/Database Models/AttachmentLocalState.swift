import Foundation
import GRDB

struct AttachmentLocalState: FetchableRecord, PersistableRecord, Codable, Hashable {
    static let databaseTableName: String = "attachmentLocalState"

    enum Columns {
        static let attachmentKey: Column = Column(CodingKeys.attachmentKey)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let width: Column = Column(CodingKeys.width)
        static let height: Column = Column(CodingKeys.height)
        static let mimeType: Column = Column(CodingKeys.mimeType)
        static let waveformLevels: Column = Column(CodingKeys.waveformLevels)
        static let duration: Column = Column(CodingKeys.duration)
    }

    let attachmentKey: String
    let conversationId: String
    let width: Int?
    let height: Int?
    let mimeType: String?
    let waveformLevels: String?
    let duration: Double?

    static let conversationForeignKey: ForeignKey = ForeignKey([Columns.conversationId], to: [DBConversation.Columns.id])
    static let conversation: BelongsToAssociation<AttachmentLocalState, DBConversation> = belongsTo(DBConversation.self, using: conversationForeignKey)

    init(
        attachmentKey: String,
        conversationId: String,
        width: Int? = nil,
        height: Int? = nil,
        mimeType: String? = nil,
        waveformLevels: String? = nil,
        duration: Double? = nil
    ) {
        self.attachmentKey = attachmentKey
        self.conversationId = conversationId
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.waveformLevels = waveformLevels
        self.duration = duration
    }
}
