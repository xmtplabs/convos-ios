import Foundation

public enum MCPTransportType: Sendable, Codable, Equatable {
    case http(endpoint: URL)
    case stdio(command: String, arguments: [String])
}

public struct MCPServerConfiguration: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let transportType: MCPTransportType
    public let supportsUI: Bool

    public init(
        id: String,
        name: String,
        transportType: MCPTransportType,
        supportsUI: Bool = false
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.supportsUI = supportsUI
    }
}
