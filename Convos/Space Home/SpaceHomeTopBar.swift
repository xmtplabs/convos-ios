import ConvosComposer
import ConvosCore
import SwiftUI

/// Space Home's top chrome: the profile mark, the Space capsule, and compose.
///
/// The capsule in the middle is the one that does something unusual - it opens
/// the conversations list as a sheet dropped from the top, so the list is
/// somewhere you look rather than somewhere you go. Everything either side of
/// it is an ordinary button.
///
/// Laid out as a centre with two overlaid edges rather than an `HStack` of
/// three, so the capsule is centred on the *screen* and not on the space left
/// between its neighbours. The two circles are the same size, so the
/// difference is invisible today and would appear the moment either edge grew
/// - a second trailing button, or a longer subtitle.
struct SpaceHomeTopBar: View {
    let profileImage: UIImage?
    /// The Space's name. "Your Space" until the user renames it.
    let spaceTitle: String
    /// Plan name, or the low-power bolt - the same subtitle the app indicator
    /// carries, because it is the same fact about the same account.
    let subtitle: AppIndicatorSubtitle
    let onProfile: () -> Void
    let onSpace: () -> Void
    let onCompose: () -> Void

    var body: some View {
        ZStack {
            spaceCapsule
            HStack(spacing: 0) {
                profileButton
                Spacer(minLength: DesignConstants.Spacing.step2x)
                composeButton
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .accessibilityIdentifier("space-home-top-bar")
    }

    private var profileButton: some View {
        let action = { onProfile() }
        return Button(action: action) {
            ZStack {
                Circle().fill(Color.colorFillMinimal)
                Image("convosOrangeIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(height: Constant.markHeight)
            }
            .frame(width: Constant.circleSize, height: Constant.circleSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .clipShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
        .hoverEffect(.lift)
        .accessibilityLabel("Profile and settings")
        .accessibilityIdentifier("space-home-profile-button")
    }

    private var spaceCapsule: some View {
        let action = { onSpace() }
        return Button(action: action) {
            VStack(spacing: 0) {
                Text(spaceTitle)
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                subtitleView
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .hoverEffect(.lift)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spaceTitle), \(subtitle.accessibilityText). Opens your convos")
        .accessibilityIdentifier("space-home-space-capsule")
    }

    @ViewBuilder
    private var subtitleView: some View {
        switch subtitle {
        case .text(let value):
            Text(value)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        case let .symbol(systemName, tint, label):
            HStack(spacing: DesignConstants.Spacing.stepHalf) {
                Image(systemName: systemName)
                Text(label)
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(tint)
        }
    }

    private var composeButton: some View {
        let action = { onCompose() }
        return Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: Constant.plusSize, weight: .medium))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.circleSize, height: Constant.circleSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .clipShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
        .hoverEffect(.lift)
        .accessibilityLabel("New convo")
        .accessibilityIdentifier("space-home-compose-button")
    }

    private enum Constant {
        static let circleSize: CGFloat = 44.0
        static let markHeight: CGFloat = 20.0
        static let plusSize: CGFloat = 17.0
    }
}

#Preview("Basic") {
    SpaceHomeTopBar(
        profileImage: nil,
        spaceTitle: "Your Space",
        subtitle: .text("Basic"),
        onProfile: {},
        onSpace: {},
        onCompose: {}
    )
    .padding(.vertical, DesignConstants.Spacing.step6x)
    .background(Color.colorBackgroundSurfaceless)
}

#Preview("No power") {
    SpaceHomeTopBar(
        profileImage: nil,
        spaceTitle: "Your Space",
        subtitle: .symbol(systemName: "bolt.fill", tint: .colorLava, accessibilityLabel: "No power"),
        onProfile: {},
        onSpace: {},
        onCompose: {}
    )
    .padding(.vertical, DesignConstants.Spacing.step6x)
    .background(Color.colorBackgroundSurfaceless)
}
