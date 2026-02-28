import ConvosCore
import SwiftUI

struct MCPAppBubbleView: View {
    let mcpApp: MCPAppContent
    let isOutgoing: Bool

    @State private var contentHeight: CGFloat = 0
    @State private var loadState: LoadState = .loading

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
        // For now, show fallback since we don't have the MCP server connection wired up yet.
        // In M4/M5, this will fetch the ui:// resource via MCPConnectionManager.
        loadState = .error
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
