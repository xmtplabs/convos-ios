import Foundation
import MCP

public enum MCPConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(serverName: String, protocolVersion: String)
    case failed(String)
}

public struct MCPServerCapabilities: Sendable, Equatable {
    public let supportsResources: Bool
    public let supportsTools: Bool
    public let supportsPrompts: Bool
    public let supportsUI: Bool

    public init(
        supportsResources: Bool = false,
        supportsTools: Bool = false,
        supportsPrompts: Bool = false,
        supportsUI: Bool = false
    ) {
        self.supportsResources = supportsResources
        self.supportsTools = supportsTools
        self.supportsPrompts = supportsPrompts
        self.supportsUI = supportsUI
    }
}

public struct MCPDiscoveredResource: Sendable, Equatable, Identifiable {
    public let id: String
    public let uri: String
    public let name: String
    public let title: String?
    public let description: String?
    public let mimeType: String?

    public var isUIResource: Bool {
        uri.hasPrefix("ui://")
    }

    public init(
        uri: String,
        name: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil
    ) {
        self.id = uri
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
    }
}

public struct MCPResourceContent: Sendable, Equatable {
    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let blob: String?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }
}

public protocol MCPConnectionManaging: Actor {
    var state: MCPConnectionState { get }
    var serverCapabilities: MCPServerCapabilities? { get }
    var discoveredResources: [MCPDiscoveredResource] { get }

    func connect() async throws
    func disconnect() async
    func listResources() async throws -> [MCPDiscoveredResource]
    func readResource(uri: String) async throws -> [MCPResourceContent]
}

public actor MCPConnectionManager: MCPConnectionManaging {
    private let configuration: MCPServerConfiguration
    private var client: Client?
    private var transport: (any Transport)?

    public private(set) var state: MCPConnectionState = .disconnected
    public private(set) var serverCapabilities: MCPServerCapabilities?
    public private(set) var discoveredResources: [MCPDiscoveredResource] = []

    public init(configuration: MCPServerConfiguration) {
        self.configuration = configuration
    }

    public func connect() async throws {
        guard case .disconnected = state else { return }

        state = .connecting

        do {
            let transport = try createTransport()
            self.transport = transport

            let client = Client(name: "Convos", version: "1.0.0")
            self.client = client

            let result = try await client.connect(transport: transport)

            let capabilities = mapCapabilities(result.capabilities)
            self.serverCapabilities = capabilities

            state = .connected(
                serverName: result.serverInfo.name,
                protocolVersion: result.protocolVersion
            )

            Log.info("[MCP] Connected to \(result.serverInfo.name) (protocol \(result.protocolVersion))")

            if capabilities.supportsUI {
                Log.info("[MCP] Server supports MCP Apps UI")
            }
        } catch {
            state = .failed(error.localizedDescription)
            Log.error("[MCP] Connection failed: \(error)")
            throw error
        }
    }

    public func disconnect() async {
        if let client {
            await client.disconnect()
        }
        client = nil
        transport = nil
        serverCapabilities = nil
        discoveredResources = []
        state = .disconnected
        Log.info("[MCP] Disconnected from \(configuration.name)")
    }

    public func listResources() async throws -> [MCPDiscoveredResource] {
        guard let client else {
            throw MCPConnectionError.notConnected
        }

        var allResources: [MCPDiscoveredResource] = []
        var cursor: String?

        repeat {
            let (resources, nextCursor) = try await client.listResources(cursor: cursor)
            let mapped = resources.map { resource in
                MCPDiscoveredResource(
                    uri: resource.uri,
                    name: resource.name,
                    title: resource.title,
                    description: resource.description,
                    mimeType: resource.mimeType
                )
            }
            allResources.append(contentsOf: mapped)
            cursor = nextCursor
        } while cursor != nil

        self.discoveredResources = allResources
        Log.info("[MCP] Discovered \(allResources.count) resources (\(allResources.filter(\.isUIResource).count) UI)")
        return allResources
    }

    public func readResource(uri: String) async throws -> [MCPResourceContent] {
        guard let client else {
            throw MCPConnectionError.notConnected
        }

        let contents = try await client.readResource(uri: uri)
        return contents.map { content in
            MCPResourceContent(
                uri: content.uri,
                mimeType: content.mimeType,
                text: content.text,
                blob: content.blob
            )
        }
    }

    private func createTransport() throws -> any Transport {
        switch configuration.transportType {
        case .http(let endpoint):
            return HTTPClientTransport(endpoint: endpoint)
        case .stdio:
            throw MCPConnectionError.stdioNotSupportedOnIOS
        }
    }

    private func mapCapabilities(_ capabilities: Server.Capabilities) -> MCPServerCapabilities {
        MCPServerCapabilities(
            supportsResources: capabilities.resources != nil,
            supportsTools: capabilities.tools != nil,
            supportsPrompts: capabilities.prompts != nil,
            supportsUI: configuration.supportsUI
        )
    }
}

public enum MCPConnectionError: Error, LocalizedError {
    case notConnected
    case stdioNotSupportedOnIOS
    case serverNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to MCP server"
        case .stdioNotSupportedOnIOS:
            "Stdio transport is not supported on iOS"
        case .serverNotFound(let name):
            "MCP server not found: \(name)"
        }
    }
}
