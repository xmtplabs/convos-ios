import ConvosCore
import SwiftUI

/// Icon for an ability row: the server-provided image when the manifest
/// carries an icon URL, otherwise a local symbol fallback keyed by
/// ability id (the backend omits icons until its asset story lands).
struct AbilityIconView: View {
    let ability: AbilitiesAPI.Ability

    var body: some View {
        Group {
            if let iconUrl {
                AsyncImage(url: iconUrl) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    symbolImage
                }
            } else {
                symbolImage
            }
        }
        .frame(width: Constant.iconSize, height: Constant.iconSize)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                .fill(Color.colorFillMinimal)
        )
    }

    private var iconUrl: URL? {
        guard let urlString = ability.icon?.iosUrl else { return nil }
        return URL(string: urlString)
    }

    private var symbolImage: some View {
        Image(systemName: Self.symbolName(for: ability.id))
            .font(.headline)
            .foregroundStyle(.colorTextPrimary)
    }

    static func symbolName(for abilityId: String) -> String {
        switch abilityId {
        case "googlecalendar": "calendar"
        case "gmail": "envelope.fill"
        case "spotify": "music.note"
        case "coinbase": "bitcoinsign.circle"
        case "shopify": "bag.fill"
        case "youtube": "play.rectangle.fill"
        default: "sparkles"
        }
    }

    private enum Constant {
        static let iconSize: CGFloat = 40.0
    }
}

/// Capsule badge rendering a server-owned entitlement status.
struct AbilityStatusBadge: View {
    let status: AbilitiesAPI.EntitlementStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(labelColor)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, DesignConstants.Spacing.stepHalf)
            .background(Capsule().fill(Color.colorFillMinimal))
            .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        switch status {
        case .active: "Active"
        case .pendingAuth: "Pending"
        case .needsReauth: "Reconnect"
        case .expired: "Expired"
        case .revoked: "Revoked"
        }
    }

    private var labelColor: Color {
        switch status {
        case .active: .colorGreen
        case .pendingAuth: .colorOrange
        case .needsReauth, .expired, .revoked: .colorCaution
        }
    }
}

#Preview("Badges") {
    VStack(spacing: DesignConstants.Spacing.step2x) {
        AbilityStatusBadge(status: .active)
        AbilityStatusBadge(status: .pendingAuth)
        AbilityStatusBadge(status: .needsReauth)
        AbilityStatusBadge(status: .expired)
        AbilityStatusBadge(status: .revoked)
    }
    .padding(DesignConstants.Spacing.step4x)
}
