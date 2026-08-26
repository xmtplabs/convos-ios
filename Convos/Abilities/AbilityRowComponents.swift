import ConvosCore
import SwiftUI

/// Icon for an ability row: the server-provided image when the manifest
/// carries an icon URL, otherwise a local symbol fallback keyed by
/// ability id (the backend omits icons until its asset story lands).
///
/// The server image is resolved through `AbilityIconLoader`, not `AsyncImage`.
/// `AsyncImage` begins every instance in its empty phase and reaches the
/// loaded phase asynchronously even when the bytes are already in `URLCache`,
/// so each new instance - a list re-render, a sheet, a detail push - showed
/// the symbol placeholder for at least a frame before the colored icon
/// replaced it. Reading the memory cache during `body` instead means a
/// previously seen icon is on screen in the first frame.
struct AbilityIconView: View {
    let ability: AbilitiesAPI.Ability
    /// Defaults preserve every existing call site's 40pt chip.
    var iconSize: CGFloat = Constant.iconSize
    /// Defaults preserve every existing call site's filled background.
    var showsBackground: Bool = true
    /// Set once the loader resolves the icon from disk or the network. A
    /// memory hit never needs it: `displayImage` finds that directly.
    @State private var loadedIcon: UIImage?

    var body: some View {
        iconContent
            .frame(width: iconSize, height: iconSize)
            .background(backgroundChip)
            .task(id: iconUrl) { await loadIcon() }
    }

    @ViewBuilder
    private var iconContent: some View {
        if let displayImage {
            Image(uiImage: displayImage)
                .resizable()
                .scaledToFit()
        } else {
            symbolImage
        }
    }

    /// The freshly loaded icon, else whatever the memory cache already holds.
    /// The cache read is an in-memory lookup, cheap enough for `body`, and is
    /// what removes the placeholder frame on a warm cache.
    private var displayImage: UIImage? {
        if let loadedIcon { return loadedIcon }
        guard let iconUrl else { return nil }
        return AbilityIconLoader.cachedIcon(for: iconUrl)
    }

    private func loadIcon() async {
        guard let iconUrl else { return }
        loadedIcon = await AbilityIconLoader.icon(for: iconUrl)
    }

    @ViewBuilder
    private var backgroundChip: some View {
        if showsBackground {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                .fill(Color.colorFillMinimal)
        }
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
            // A one-word status must never hyphenate: at accessibility text
            // sizes the capsule wrapped "Active" into "Ac-tive". The row's
            // title column is the flexible one, not this.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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

/// Capsule badge for client-derived presentation states ("Not connected")
/// with no server-owned entitlement status behind them. Visually matches
/// `AbilityStatusBadge` in a neutral color, so the UI never has to
/// fabricate a server status just to render a badge.
struct AbilityNeutralBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, DesignConstants.Spacing.stepHalf)
            .background(Capsule().fill(Color.colorFillMinimal))
            .accessibilityLabel("Status: \(label)")
    }
}

#Preview("Badges") {
    VStack(spacing: DesignConstants.Spacing.step2x) {
        AbilityStatusBadge(status: .active)
        AbilityStatusBadge(status: .pendingAuth)
        AbilityStatusBadge(status: .needsReauth)
        AbilityStatusBadge(status: .expired)
        AbilityStatusBadge(status: .revoked)
        AbilityNeutralBadge(label: "Not connected")
    }
    .padding(DesignConstants.Spacing.step4x)
}
