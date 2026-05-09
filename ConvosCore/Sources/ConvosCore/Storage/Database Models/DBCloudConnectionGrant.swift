import Foundation
import GRDB

struct DBCloudConnectionGrant: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "connectionGrant"

    enum Columns {
        static let connectionId: Column = Column(CodingKeys.connectionId)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let serviceId: Column = Column(CodingKeys.serviceId)
        static let grantedToInboxId: Column = Column(CodingKeys.grantedToInboxId)
        static let grantedAt: Column = Column(CodingKeys.grantedAt)
    }

    let connectionId: String
    let conversationId: String
    let serviceId: String
    let grantedToInboxId: String
    let grantedAt: Date
}

extension DBCloudConnectionGrant {
    func toConnectionGrant() -> CloudConnectionGrant {
        CloudConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: serviceId,
            grantedToInboxId: grantedToInboxId,
            grantedAt: grantedAt
        )
    }

    init(from grant: CloudConnectionGrant) {
        self.connectionId = grant.connectionId
        self.conversationId = grant.conversationId
        self.serviceId = grant.serviceId
        self.grantedToInboxId = grant.grantedToInboxId
        self.grantedAt = grant.grantedAt
    }
}
