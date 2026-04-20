import Foundation
import GRDB

struct DBConnectionGrant: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "connectionGrant"

    enum Columns {
        static let connectionId: Column = Column(CodingKeys.connectionId)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let serviceId: Column = Column(CodingKeys.serviceId)
        static let grantedAt: Column = Column(CodingKeys.grantedAt)
    }

    let connectionId: String
    let conversationId: String
    let serviceId: String
    let grantedAt: Date
}

extension DBConnectionGrant {
    func toConnectionGrant() -> ConnectionGrant {
        ConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: serviceId,
            grantedAt: grantedAt
        )
    }

    init(from grant: ConnectionGrant) {
        self.connectionId = grant.connectionId
        self.conversationId = grant.conversationId
        self.serviceId = grant.serviceId
        self.grantedAt = grant.grantedAt
    }
}
