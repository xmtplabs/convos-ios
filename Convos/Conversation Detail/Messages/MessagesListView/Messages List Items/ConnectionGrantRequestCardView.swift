import ConvosCore
import SwiftUI

struct ConnectionGrantRequestCardView: View {
    let request: ConnectionGrantRequest
    let conversationId: String

    @Environment(\.openURL) private var openURL: OpenURLAction

    private var serviceInfo: ConnectionServiceInfo? {
        ConnectionServiceCatalog.info(for: request.service)
    }

    private var displayName: String {
        ConnectionServiceCatalog.displayName(for: request.service, fallback: request.service)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                icon

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text("Connect \(displayName)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text(request.reason)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 0)
            }

            let action = { openGrantLink() }
            Button(action: action) {
                Text("Open Settings")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignConstants.Spacing.step3x)
                    .background(
                        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                            .fill(Color.colorFillPrimary)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                .fill(Color.colorBackgroundSurfaceless)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                        .stroke(Color.colorBorderSubtle, lineWidth: 1)
                )
        )
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var icon: some View {
        Image(systemName: serviceInfo?.iconSystemName ?? "link")
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(serviceInfo?.iconBackgroundColor ?? .gray)
            )
    }

    private func openGrantLink() {
        let scheme = ConfigManager.shared.appUrlScheme
        var components = URLComponents()
        components.scheme = scheme
        components.host = "connections"
        components.path = "/grant"
        components.queryItems = [
            URLQueryItem(name: "service", value: request.service),
            URLQueryItem(name: "conversationId", value: conversationId),
        ]
        if let url = components.url {
            openURL(url)
        }
    }
}
