#if canImport(UIKit)
import SwiftUI

/// One of the "top three" invite actions rendered above the contacts list in
/// the compose picker (see Figma node 4 / `ContactsPickerView`): a 56pt black
/// rounded icon tile, a title, and an optional subtitle. Structurally it
/// mirrors `ContactsPickerRow` (56pt leading tile + name/subtitle column) so
/// the action rows line up with the contact rows beneath them, but it carries
/// a tap action instead of a multi-select checkbox.
///
/// The leading icon is either an SF Symbol (`qrcode`, `square.and.arrow.up`)
/// or a bundled asset image (the custom `addAgentIcon` agent glyph), rendered
/// white-on-black.
public struct ContactsPickerActionRow: View {
    public enum Icon {
        case system(String)
        case asset(String)
    }

    let icon: Icon
    let title: String
    let subtitle: String?
    let accessibilityIdentifier: String
    /// Renders a trailing spinner while the row's action is being prepared
    /// (e.g. the Contacts tab's "Send an invite" waiting on its on-demand
    /// invite). The row stays tappable; repeat taps are the caller's concern.
    let showsProgress: Bool
    let action: () -> Void

    public init(
        icon: Icon,
        title: String,
        subtitle: String? = nil,
        accessibilityIdentifier: String,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsProgress = showsProgress
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                iconTile

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0.0)

                if showsProgress {
                    ProgressView()
                }
            }
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var iconTile: some View {
        iconImage
            .foregroundStyle(.colorTextPrimaryInverted)
            .frame(width: 56.0, height: 56.0)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarger)
                    .fill(.colorTextPrimary)
            )
    }

    @ViewBuilder
    private var iconImage: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.title3)
        case .asset(let name):
            // A bundled template asset renders at its (small) intrinsic size and
            // ignores `.font`, so it has to be resized explicitly to fill the
            // tile like the SF Symbols in the sibling rows do.
            Image(name, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Constant.assetGlyphSize, height: Constant.assetGlyphSize)
        }
    }

    private enum Constant {
        /// Optical size for the bundled `addAgentIcon` glyph so it reads at the
        /// same weight as the SF Symbols in the neighboring rows (which render
        /// at `.title3`) inside the 56pt tile.
        static let assetGlyphSize: CGFloat = 28.0
    }
}

// MARK: - Previews

#Preview("Action rows") {
    VStack(alignment: .leading, spacing: 0.0) {
        ContactsPickerActionRow(
            icon: .system("qrcode"),
            title: "Show an invite code",
            accessibilityIdentifier: "picker-action-show-invite-code",
            action: {}
        )
        ContactsPickerActionRow(
            icon: .system("square.and.arrow.up"),
            title: "Send an invite",
            subtitle: "Via Airdrop, link or app",
            accessibilityIdentifier: "picker-action-send-invite",
            action: {}
        )
        ContactsPickerActionRow(
            icon: .asset("addAgentIcon"),
            title: "Make an agent",
            accessibilityIdentifier: "picker-action-make-agent",
            action: {}
        )
    }
    .padding()
}
#endif
