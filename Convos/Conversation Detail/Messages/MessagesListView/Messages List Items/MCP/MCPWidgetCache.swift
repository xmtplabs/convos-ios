import ConvosCore
import Foundation

@MainActor
final class MCPWidgetCache {
    static let shared: MCPWidgetCache = .init()

    private var htmlCache: [MCPAppContent: String] = [:]
    private var heightCache: [MCPAppContent: CGFloat] = [:]

    private init() {}

    func cachedHTML(for mcpApp: MCPAppContent) -> String? {
        htmlCache[mcpApp]
    }

    func cachedHeight(for mcpApp: MCPAppContent) -> CGFloat? {
        heightCache[mcpApp]
    }

    func store(html: String, for mcpApp: MCPAppContent) {
        htmlCache[mcpApp] = html
    }

    func storeHeight(_ height: CGFloat, for mcpApp: MCPAppContent) {
        heightCache[mcpApp] = height
    }
}
