import ConvosCore
import SwiftUI

/// Per-conversation "contact card" for a verified Convos agent. Renders as
/// the body of the agent's first message group — the surrounding
/// `MessagesGroupView` already provides the sender label and avatar, so this
/// view only owns the rounded-rect card itself: the agent's avatar,
/// display name, and `description` subtitle. While the agent hasn't yet
/// written a `description` into its profile metadata, the subtitle reads
/// "Learning more about my job" with a pulse highlight matching
/// `AgentJoinStatusView`. Once the value arrives, the subtitle
/// blur-replaces to the real text.
struct AgentContactCardView: View {
    let profile: Profile
    let agentDescription: String?

    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false

    private var displayedSubtitle: String {
        if let agentDescription, !agentDescription.isEmpty {
            return agentDescription
        }
        return AgentContactCardView.placeholderSubtitle
    }

    private var hasAgentDescription: Bool {
        agentDescription?.isEmpty == false
    }

    var body: some View {
        // Wrapping the glass surface in a `GlassEffectContainer` gives iOS a
        // stable scope to coordinate the material's backdrop-sampling
        // pipeline. Without a container, a standalone `.glassEffect` inside
        // a `UIHostingConfiguration` cell renders as opaque grey on first
        // mount because the cell is typically laid out off-screen before
        // being scrolled into view — the sampling layer has no backdrop
        // until the cell attaches to the window, and the fallback material
        // colour flashes through during that window. The opacity fade
        // covers the first ~350ms where sampling is still settling.
        GlassEffectContainer {
            glassCard
        }
        .opacity(isAppearing ? 0 : 1)
        .onAppear {
            guard isAppearing, !hasAnimated else { return }
            hasAnimated = true
            withAnimation(.easeInOut(duration: 0.35)) {
                isAppearing = false
            }
        }
    }

    private var glassCard: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            MessageAvatarView(
                profile: profile,
                size: Constant.avatarSize,
                agentVerification: .verified(.convos)
            )
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(profile.displayName)
                    .font(.title2)
                    .foregroundStyle(.colorTextPrimary)
                subtitleText
            }
        }
        .padding(DesignConstants.Spacing.step8x)
        .background(.colorBackgroundRaised, in: .rect(cornerRadius: Constant.cornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Constant.cornerRadius))
    }

    @ViewBuilder
    private var subtitleText: some View {
        if hasAgentDescription {
            Text(displayedSubtitle)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .transition(.blurReplace)
                .id("subtitle-loaded")
        } else {
            PulsingSubtitle(text: displayedSubtitle)
                .transition(.blurReplace)
                .id("subtitle-placeholder")
        }
    }

    private enum Constant {
        static let avatarSize: CGFloat = 40
        static let cornerRadius: CGFloat = 24
    }

    static let placeholderSubtitle: String = "Learning more about my job"
}

/// Opacity pulse that matches `AgentJoinStatusView`'s "Agent is
/// joining…" pacing — fades the secondary subtitle between 0.5 and 1.0 on a
/// 1.2s ease-in-out loop. Animating opacity (instead of `foregroundStyle`)
/// keeps the text's layout metrics fixed, so the pulse doesn't nudge the
/// surrounding card content. The `.animation(_:value:)` modifier scopes the
/// repeat-forever transaction so it doesn't leak into siblings.
private struct PulsingSubtitle: View {
    let text: String
    @State private var isPulsed: Bool = false

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.colorTextSecondary)
            .opacity(isPulsed ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsed)
            .onAppear {
                isPulsed = true
            }
    }
}

#Preview("Placeholder (no description)") {
    AgentContactCardView(
        profile: Profile(
            inboxId: "preview-inbox-1",
            conversationId: "preview-conv-1",
            name: "Tifoso",
            avatar: nil,
            isAgent: true,
            metadata: ["emoji": .string("🚴")]
        ),
        agentDescription: nil
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}

#Preview("Loaded description") {
    AgentContactCardView(
        profile: Profile(
            inboxId: "preview-inbox-2",
            conversationId: "preview-conv-2",
            name: "Tifoso",
            avatar: nil,
            isAgent: true,
            metadata: ["emoji": .string("🚴")]
        ),
        agentDescription: "I'll help you plan your next ride, log mileage, and remember your favorite routes."
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}
