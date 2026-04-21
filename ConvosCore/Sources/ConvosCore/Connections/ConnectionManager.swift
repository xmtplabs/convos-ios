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

    public func connect(serviceId canonicalServiceId: String) async throws -> Connection {
        let redirectUri = "\(callbackURLScheme)://connections/callback"
        let toolkitSlug = ConnectionServiceNaming.composioToolkitSlug(for: canonicalServiceId)

        let initiation = try await apiClient.initiateConnection(
            serviceId: toolkitSlug,
            redirectUri: redirectUri
        )

        guard let oauthURL = URL(string: initiation.redirectUrl) else {
            throw ConnectionManagerError.invalidOAuthURL
        }

        _ = try await oauthProvider.authenticate(url: oauthURL, callbackURLScheme: callbackURLScheme)

        let completion = try await apiClient.completeConnection(connectionRequestId: initiation.connectionRequestId)

        // Backend echoes whatever slug Composio returns; normalise back to canonical.
        let canonicalFromResponse = ConnectionServiceNaming.canonicalService(fromComposioSlug: completion.serviceId)
        let finalCanonical = canonicalFromResponse == completion.serviceId ? canonicalServiceId : canonicalFromResponse

        let connection = Connection(
            id: completion.connectionId,
            serviceId: finalCanonical,
            serviceName: displayName(for: completion.serviceName, fallbackFrom: finalCanonical),
            provider: .composio,
            composioEntityId: completion.composioEntityId,
            composioConnectionId: completion.composioConnectionId,
            status: ConnectionStatus.from(composioStatus: completion.status),
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
            let canonical = ConnectionServiceNaming.canonicalService(fromComposioSlug: response.serviceId)
            return Connection(
                id: response.connectionId,
                serviceId: canonical,
                serviceName: displayName(for: response.serviceName, fallbackFrom: canonical),
                provider: .composio,
                composioEntityId: response.composioEntityId,
                composioConnectionId: response.composioConnectionId,
                status: ConnectionStatus.from(composioStatus: response.status),
                connectedAt: Date()
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

    private func displayName(for serviceName: String, fallbackFrom serviceId: String) -> String {
        let base = serviceName.isEmpty ? serviceId : serviceName
        return base
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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

extension ConnectionStatus {
    static func from(composioStatus raw: String) -> ConnectionStatus {
        switch raw.uppercased() {
        case "ACTIVE", "INITIATED", "INITIALIZING":
            return .active
        case "EXPIRED":
            return .expired
        case "FAILED", "INACTIVE":
            return .revoked
        default:
            return .active
        }
    }
}
