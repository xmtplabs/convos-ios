import Foundation
import GRDB

struct DBConnection: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName: String = "connection"

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let serviceId: Column = Column(CodingKeys.serviceId)
        static let serviceName: Column = Column(CodingKeys.serviceName)
        static let provider: Column = Column(CodingKeys.provider)
        static let composioEntityId: Column = Column(CodingKeys.composioEntityId)
        static let composioConnectionId: Column = Column(CodingKeys.composioConnectionId)
        static let status: Column = Column(CodingKeys.status)
        static let connectedAt: Column = Column(CodingKeys.connectedAt)
    }

    let id: String
    let serviceId: String
    let serviceName: String
    let provider: String
    let composioEntityId: String
    let composioConnectionId: String
    let status: String
    let connectedAt: Date
}

extension DBConnection {
    func toConnection() -> Connection {
        Connection(
            id: id,
            serviceId: serviceId,
            serviceName: serviceName,
            provider: ConnectionProvider(rawValue: provider) ?? .composio,
            composioEntityId: composioEntityId,
            composioConnectionId: composioConnectionId,
            status: ConnectionStatus(rawValue: status) ?? .active,
            connectedAt: connectedAt
        )
    }

    init(from connection: Connection) {
        self.id = connection.id
        self.serviceId = connection.serviceId
        self.serviceName = connection.serviceName
        self.provider = connection.provider.rawValue
        self.composioEntityId = connection.composioEntityId
        self.composioConnectionId = connection.composioConnectionId
        self.status = connection.status.rawValue
        self.connectedAt = connection.connectedAt
    }
}
