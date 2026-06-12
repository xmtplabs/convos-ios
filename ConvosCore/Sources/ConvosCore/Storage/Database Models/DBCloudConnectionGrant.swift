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
        static let backendGrantId: Column = Column(CodingKeys.backendGrantId)
        static let bundleIds: Column = Column(CodingKeys.bundleIds)
        static let serviceVersion: Column = Column(CodingKeys.serviceVersion)
    }

    let connectionId: String
    let conversationId: String
    let serviceId: String
    let grantedToInboxId: String
    let grantedAt: Date
    /// Id of the backend ConnectionGrant record created when this grant was
    /// pushed to the server. Nil when the push hasn't happened or failed;
    /// backend revocation is skipped for those rows.
    let backendGrantId: String?
    /// Permission-bundle ids this grant authorizes (catalog ids like
    /// "calendar.events", stored as JSON). Nil for rows that predate bundles
    /// or whose service isn't in the catalog (legacy whole-toolkit grants).
    let bundleIds: [String]?
    /// Catalog service version the bundles were granted against. Nil when no
    /// catalog entry existed at push time.
    let serviceVersion: Int?

    init(
        connectionId: String,
        conversationId: String,
        serviceId: String,
        grantedToInboxId: String,
        grantedAt: Date,
        backendGrantId: String? = nil,
        bundleIds: [String]? = nil,
        serviceVersion: Int? = nil
    ) {
        self.connectionId = connectionId
        self.conversationId = conversationId
        self.serviceId = serviceId
        self.grantedToInboxId = grantedToInboxId
        self.grantedAt = grantedAt
        self.backendGrantId = backendGrantId
        self.bundleIds = bundleIds
        self.serviceVersion = serviceVersion
    }
}

extension DBCloudConnectionGrant {
    func toConnectionGrant() -> CloudConnectionGrant {
        CloudConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: serviceId,
            grantedToInboxId: grantedToInboxId,
            grantedAt: grantedAt,
            bundleIds: bundleIds
        )
    }

    init(from grant: CloudConnectionGrant) {
        self.connectionId = grant.connectionId
        self.conversationId = grant.conversationId
        self.serviceId = grant.serviceId
        self.grantedToInboxId = grant.grantedToInboxId
        self.grantedAt = grant.grantedAt
        self.backendGrantId = nil
        self.bundleIds = grant.bundleIds
        self.serviceVersion = nil
    }
}
