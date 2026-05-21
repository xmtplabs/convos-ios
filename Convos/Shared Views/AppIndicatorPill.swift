import ConvosCore
import SwiftUI

/// Leading-edge top-bar pill used by [[AdaptiveAppIndicator]] when no
/// conversation is selected. Mirrors the visual style of
/// `ConversationToolbarButton` (avatar + title + subtitle stacked inside a
/// glass capsule) so the leading->centered indicator transition stays
/// continuous — see `AdaptiveAppIndicator.swift` for the dispatch.
///
/// Shows the user's profile avatar when set, otherwise falls back to the
/// `convosOrangeIcon` asset. Title is currently the static "Convos" string;
/// subtitle is the placeholder "Plus" stand-in for subscription state until
/// a real subscription model is wired in.
struct AppIndicatorPill: View {
    let profileImage: UIImage?
    let title: String
    let subtitle: String
    let action: () -> Void

    init(
        profileImage: UIImage?,
        title: String = "Convos",
        subtitle: String = "Plus",
        action: @escaping () -> Void = {}
    ) {
        self.profileImage = profileImage
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityIdentifier("app-indicator-pill")
    }

    private var content: some View {
        HStack(spacing: 0) {
            avatar
                .frame(width: Constant.avatarSize, height: Constant.avatarSize)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
        }
        .padding(DesignConstants.Spacing.step2x)
    }

    @ViewBuilder
    private var avatar: some View {
        if let profileImage {
            Image(uiImage: profileImage)
                .resizable()
                .scaledToFill()
        } else {
            GeometryReader { geometry in
                let side: CGFloat = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Circle()
                        .fill(Color.colorFillMinimal)
                    Image("convosOrangeIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.55, height: side * 0.55)
                }
                .frame(width: side, height: side)
            }
            .aspectRatio(1.0, contentMode: .fit)
        }
    }

    private enum Constant {
        static let avatarSize: CGFloat = 36.0
    }
}

#Preview("With avatar") {
    AppIndicatorPill(profileImage: nil)
        .padding()
        .background(Color.colorBackgroundSurfaceless)
}

#Preview("Fallback icon") {
    AppIndicatorPill(profileImage: nil, title: "Convos", subtitle: "Plus")
        .padding()
        .background(Color.colorBackgroundSurfaceless)
}
