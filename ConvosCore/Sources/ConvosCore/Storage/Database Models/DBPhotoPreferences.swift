import Foundation
import GRDB

struct DBPhotoPreferences: FetchableRecord, PersistableRecord, Codable, Hashable {
    static let databaseTableName: String = "photoPreferences"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let autoReveal: Column = Column(CodingKeys.autoReveal)
        static let hasRevealedFirst: Column = Column(CodingKeys.hasRevealedFirst)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let conversationId: String
    var autoReveal: Bool
    var hasRevealedFirst: Bool
    var updatedAt: Date

    static let conversation: BelongsToAssociation<DBPhotoPreferences, DBConversation> = belongsTo(DBConversation.self)
}

extension DBPhotoPreferences {
    func with(autoReveal: Bool) -> DBPhotoPreferences {
        DBPhotoPreferences(
            conversationId: conversationId,
            autoReveal: autoReveal,
            hasRevealedFirst: hasRevealedFirst,
            updatedAt: Date()
        )
    }

    func with(hasRevealedFirst: Bool) -> DBPhotoPreferences {
        DBPhotoPreferences(
            conversationId: conversationId,
            autoReveal: autoReveal,
            hasRevealedFirst: hasRevealedFirst,
            updatedAt: Date()
        )
    }

    static func defaultPreferences(for conversationId: String) -> DBPhotoPreferences {
        DBPhotoPreferences(
            conversationId: conversationId,
            autoReveal: false,
            hasRevealedFirst: false,
            updatedAt: Date()
        )
    }
}
