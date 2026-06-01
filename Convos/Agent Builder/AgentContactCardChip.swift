import ConvosCore
import SwiftUI

/// A compact, display-only contact-card chip for a shared agent. Renders a
/// scaled-down rendering of the hero contact-card layout (emoji avatar above a
/// bold name above a tail-truncated summary) inside an attachment-style chip
/// container, with an X to remove.
///
/// Used as the composer attachment chip when an agent-share link is pasted
/// into the message input (the parallel of the invite chip). It is hand-built
/// rather than reusing `AgentContactCardView` because nesting a `glassEffect`
/// inside the composer's outer glass surface renders the inner one blank --
/// the backdrop-sampling pipeline can't resolve a stable material when the
/// parent is already a glass surface. Lifted from PR #868's private
/// `remixAgentBadge` and promoted to a real, data-driven component.
struct AgentContactCardChip: View {
    let displayName: String
    let emoji: String?
    let summary: String?
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            card
            removeButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-share-chip")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Metric.avatarToTextSpacing) {
            avatar
            VStack(alignment: .leading, spacing: Metric.nameToSummarySpacing) {
                Text(displayName)
                    .font(.system(size: Metric.nameFontSize, weight: .bold))
                    .tracking(Metric.nameTracking)
                    .foregroundStyle(.colorTextPrimary)
                Text(summary ?? AgentContactCardView.placeholderSubtitle)
                    .font(.system(size: Metric.summaryFontSize))
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metric.innerPadding)
        .frame(width: Metric.badgeWidth, height: Metric.badgeHeight)
        .background(.colorBackgroundRaised, in: .rect(cornerRadius: Metric.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.cornerRadius)
                .stroke(.colorFillMinimal, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var avatar: some View {
        if let emoji, !emoji.isEmpty {
            EmojiAvatarView(emoji: emoji, agentVerification: .verified(.convos))
                .frame(width: Metric.avatarSize, height: Metric.avatarSize)
        } else {
            MonogramView(name: displayName, agentVerification: .verified(.convos))
                .frame(width: Metric.avatarSize, height: Metric.avatarSize)
                .clipShape(Circle())
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.black)
                .clipShape(.circle)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
        }
        .padding(.top, -DesignConstants.Spacing.stepX)
        .padding(.trailing, -DesignConstants.Spacing.stepX)
        .accessibilityLabel("Remove shared agent")
        .accessibilityIdentifier("agent-share-chip-remove-button")
    }

    /// A 2x scaling of a ~30%-scale hero contact card (a hero card is
    /// ~354x232, so ~30% ~= 106x70, doubled ~= 220x144). Every metric is
    /// scaled uniformly so the chip keeps the hero card's aspect ratio and
    /// internal proportions.
    private enum Metric {
        static let badgeWidth: CGFloat = 220
        static let badgeHeight: CGFloat = 144
        static let cornerRadius: CGFloat = 24
        static let innerPadding: CGFloat = 16
        static let avatarSize: CGFloat = 44
        static let avatarToTextSpacing: CGFloat = 8
        static let nameToSummarySpacing: CGFloat = 2
        static let nameFontSize: CGFloat = 22
        static let nameTracking: CGFloat = -0.6
        static let summaryFontSize: CGFloat = 14
    }
}

#Preview("Resolved") {
    AgentContactCardChip(
        displayName: "Tifoso",
        emoji: "🚴",
        summary: "I'll help you plan your next ride, log mileage, and remember your favorite routes.",
        onRemove: {}
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}

#Preview("Resolving (no summary)") {
    AgentContactCardChip(
        displayName: "Agent",
        emoji: nil,
        summary: nil,
        onRemove: {}
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}
