import Foundation

public actor MCPServerRegistry {
    public static let shared: MCPServerRegistry = .init()

    private var connections: [String: MCPConnectionManager] = [:]

    private init() {}

    public func register(configuration: MCPServerConfiguration) async throws {
        let manager = MCPConnectionManager(configuration: configuration)
        try await manager.connect()
        connections[configuration.name] = manager
    }

    public func readResource(serverName: String, uri: String) async throws -> String? {
        guard let manager = connections[serverName] else {
            throw MCPConnectionError.serverNotFound(serverName)
        }

        let contents = try await manager.readResource(uri: uri)
        return contents.first?.text
    }

    public func disconnect(serverName: String) async {
        guard let manager = connections[serverName] else { return }
        await manager.disconnect()
        connections.removeValue(forKey: serverName)
    }

    public func disconnectAll() async {
        for (_, manager) in connections {
            await manager.disconnect()
        }
        connections.removeAll()
    }
}
