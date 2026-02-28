import ConvosCore
import SwiftUI

struct MCPAppBubbleView: View {
    let mcpApp: MCPAppContent
    let isOutgoing: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0
    @State private var loadState: LoadState = .loading
    @State private var bridge: MCPAppBridge?

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: DesignConstants.Spacing.stepX) {
            appContent
                .frame(maxWidth: Constant.maxWidth)
                .frame(height: max(contentHeight, Constant.minHeight))
                .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                        .strokeBorder(.colorBorderSubtle, lineWidth: 1.0)
                )

            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "app.badge")
                    .font(.caption2)
                    .foregroundStyle(.colorTextTertiary)
                Text(mcpApp.serverName)
                    .font(.caption2)
                    .foregroundStyle(.colorTextTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
        switch loadState {
        case .loading:
            loadingView
        case .loaded(let html):
            MCPAppWebView(
                htmlContent: html,
                baseURL: nil,
                allowedDomains: [],
                bridge: bridge,
                contentHeight: $contentHeight
            )
        case .error:
            fallbackView
        }
    }

    private var loadingView: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            ProgressView()
            Text(mcpApp.fallbackText)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignConstants.Spacing.step4x)
        .task {
            await loadResource()
        }
    }

    private var fallbackView: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.colorTextTertiary)
            Text(mcpApp.fallbackText)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(5)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignConstants.Spacing.step4x)
    }

    private func loadResource() async {
        let hostContext = MCPAppHostContext(
            theme: colorScheme == .dark ? "dark" : "light",
            displayMode: "inline",
            availableDisplayModes: ["inline"],
            platform: "mobile"
        )
        let appBridge = MCPAppBridge(mcpApp: mcpApp, hostContext: hostContext)

        if let toolInput = mcpApp.toolInput, let inputData = toolInput.data(using: .utf8),
           let inputDict = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] {
            appBridge.sendToolInput(inputDict)
        }

        if let toolResult = mcpApp.toolResult, let resultData = toolResult.data(using: .utf8),
           let resultDict = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            let resultValue = jsonValueFromDict(resultDict)
            appBridge.sendToolResult(resultValue)
        }

        bridge = appBridge

        // Resource fetching will be wired in a future milestone when MCPConnectionManager
        // can resolve ui:// URIs. For now, show fallback.
        loadState = .error
    }

    private func jsonValueFromDict(_ dict: [String: Any]) -> JSONValue {
        .object(dict.mapValues { value -> JSONValue in
            switch value {
            case is NSNull:
                return .null
            case let bool as Bool:
                return .bool(bool)
            case let int as Int:
                return .int(int)
            case let double as Double:
                return .double(double)
            case let string as String:
                return .string(string)
            case let array as [Any]:
                return .array(array.map { item in
                    if let d = item as? [String: Any] { return jsonValueFromDict(d) }
                    if let s = item as? String { return .string(s) }
                    if let i = item as? Int { return .int(i) }
                    return .null
                })
            case let nested as [String: Any]:
                return jsonValueFromDict(nested)
            default:
                return .null
            }
        })
    }

    private enum LoadState {
        case loading
        case loaded(String)
        case error
    }

    private enum Constant {
        static let maxWidth: CGFloat = 300
        static let minHeight: CGFloat = 60
    }
}

#Preview("MCP App Bubble - Fallback") {
    MCPAppBubbleView(
        mcpApp: MCPAppContent(
            resourceURI: "ui://weather/forecast",
            serverName: "Weather App",
            fallbackText: "Current weather: 72F, Sunny in San Francisco"
        ),
        isOutgoing: false
    )
    .padding()
}
