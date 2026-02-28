import Foundation

public enum MCPAppDisplayMode: String, Codable, Hashable, Sendable {
    case inline
    case modal
    case panel
    case popover
}

public struct MCPAppContent: Codable, Hashable, Sendable {
    public let resourceURI: String
    public let serverName: String
    public let displayMode: MCPAppDisplayMode
    public let fallbackText: String
    public let toolName: String?
    public let toolInput: String?
    public let toolResult: String?

    public init(
        resourceURI: String,
        serverName: String,
        displayMode: MCPAppDisplayMode = .inline,
        fallbackText: String,
        toolName: String? = nil,
        toolInput: String? = nil,
        toolResult: String? = nil
    ) {
        self.resourceURI = resourceURI
        self.serverName = serverName
        self.displayMode = displayMode
        self.fallbackText = fallbackText
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolResult = toolResult
    }
}
