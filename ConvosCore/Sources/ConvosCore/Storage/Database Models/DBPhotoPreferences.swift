import Foundation
import GRDB

struct DBPhotoPreferences: FetchableRecord, PersistableRecord, Codable, Hashable {
    static let databaseTableName: String = "photoPreferences"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
        static let sendReadReceipts: Column = Column(CodingKeys.sendReadReceipts)
    }

    let conversationId: String
    var updatedAt: Date
    var sendReadReceipts: Bool?

    static let conversation: BelongsToAssociation<DBPhotoPreferences, DBConversation> = belongsTo(DBConversation.self)
}

extension DBPhotoPreferences {
    func with(sendReadReceipts: Bool?) -> DBPhotoPreferences {
        DBPhotoPreferences(
            conversationId: conversationId,
            updatedAt: Date(),
            sendReadReceipts: sendReadReceipts
        )
    }

    static func defaultPreferences(for conversationId: String) -> DBPhotoPreferences {
        DBPhotoPreferences(
            conversationId: conversationId,
            updatedAt: Date(),
            sendReadReceipts: nil
        )
    }
}
