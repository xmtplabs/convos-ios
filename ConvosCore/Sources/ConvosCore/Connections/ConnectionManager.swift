import Foundation
import GRDB

public protocol ConnectionManagerProtocol: Sendable {
    func connect(serviceId: String) async throws -> Connection
    func disconnect(connectionId: String) async throws
    func refreshConnections() async throws -> [Connection]
}

public final class ConnectionManager: ConnectionManagerProtocol, @unchecked Sendable {
    private let apiClient: any ConvosAPIClientProtocol
    private let oauthProvider: any OAuthSessionProvider
    private let databaseWriter: any DatabaseWriter
    private let callbackURLScheme: String

    public init(
        apiClient: any ConvosAPIClientProtocol,
        oauthProvider: any OAuthSessionProvider,
        databaseWriter: any DatabaseWriter,
        callbackURLScheme: String
    ) {
        self.apiClient = apiClient
        self.oauthProvider = oauthProvider
        self.databaseWriter = databaseWriter
        self.callbackURLScheme = callbackURLScheme
    }

    public func connect(serviceId: String) async throws -> Connection {
        let initiation = try await apiClient.initiateConnection(serviceId: serviceId)

        guard let oauthURL = URL(string: initiation.redirectUrl) else {
            throw ConnectionManagerError.invalidOAuthURL
        }

        _ = try await oauthProvider.authenticate(url: oauthURL, callbackURLScheme: callbackURLScheme)

        let completion = try await apiClient.completeConnection(connectionRequestId: initiation.connectionRequestId)

        let connection = Connection(
            id: completion.connectionId,
            serviceId: completion.serviceId,
            serviceName: completion.serviceName,
            provider: .composio,
            composioEntityId: completion.composioEntityId,
            composioConnectionId: completion.composioConnectionId,
            status: ConnectionStatus(rawValue: completion.status) ?? .active,
            connectedAt: Date()
        )

        let dbConnection = DBConnection(from: connection)
        try await databaseWriter.write { db in
            try dbConnection.save(db)
        }

        return connection
    }

    public func disconnect(connectionId: String) async throws {
        try await apiClient.revokeConnection(connectionId: connectionId)

        try await databaseWriter.write { db in
            _ = try DBConnection.deleteOne(db, key: connectionId)
        }
    }

    public func refreshConnections() async throws -> [Connection] {
        let responses = try await apiClient.listConnections()

        let connections: [Connection] = responses.map { response in
            Connection(
                id: response.id,
                serviceId: response.serviceId,
                serviceName: response.serviceName,
                provider: .composio,
                composioEntityId: response.composioEntityId,
                composioConnectionId: response.composioConnectionId,
                status: ConnectionStatus(rawValue: response.status) ?? .active,
                connectedAt: ISO8601DateFormatter().date(from: response.connectedAt) ?? Date()
            )
        }

        try await databaseWriter.write { db in
            try DBConnection.deleteAll(db)
            for connection in connections {
                try DBConnection(from: connection).save(db)
            }
        }

        return connections
    }
}

enum ConnectionManagerError: LocalizedError {
    case invalidOAuthURL

    var errorDescription: String? {
        switch self {
        case .invalidOAuthURL:
            "Invalid OAuth URL received from server"
        }
    }
}
