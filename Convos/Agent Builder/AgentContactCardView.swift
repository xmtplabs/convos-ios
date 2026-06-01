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
///
/// Visual styling of an `AgentContactCardView`. `.standard` is the in-chat /
/// post-Make appearance (40pt avatar, `.title2` name, `.body` summary).
/// `.hero` is the larger "browse" variant -- bigger avatar, larger bolded
/// name with tight letter-spacing, smaller footnote-style summary, and almost
/// no gap between the two text lines.
enum AgentContactCardStyle {
    case standard
    case hero
}

struct AgentContactCardView: View {
    let profile: Profile
    let agentDescription: String?
    var style: AgentContactCardStyle = .standard
    /// Optional explicit size. When set, the card sizes itself to this width
    /// instead of relying on its intrinsic size or an outer `.frame` from the
    /// caller -- required where every card must be exactly the same width (e.g.
    /// a paged carousel that snaps centers).
    var cardSize: CGSize?

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

    private var avatarSize: CGFloat {
        switch style {
        case .standard: return Constant.standardAvatarSize
        case .hero: return Constant.heroAvatarSize
        }
    }

    private var displayNameFont: Font {
        switch style {
        case .standard: return .title2
        case .hero: return Constant.heroDisplayNameFont
        }
    }

    private var displayNameTracking: CGFloat {
        switch style {
        case .standard: return 0
        case .hero: return Constant.heroDisplayNameTracking
        }
    }

    private var subtitleFont: Font {
        switch style {
        case .standard: return .body
        case .hero: return .footnote
        }
    }

    private var titleSubtitleSpacing: CGFloat {
        switch style {
        case .standard: return DesignConstants.Spacing.stepX
        case .hero: return Constant.heroTitleSubtitleSpacing
        }
    }

    /// `nil` lets the subtitle expand to whatever its content needs; the
    /// `.hero` variant pins it at a fixed line count with `reservesSpace: true`
    /// so every card has the same intrinsic height regardless of summary
    /// length (and longer summaries tail-truncate cleanly).
    private var subtitleLineLimit: Int? {
        switch style {
        case .standard: return nil
        case .hero: return Constant.heroSubtitleLineLimit
        }
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
        // Only constrain width -- height stays intrinsic. With the subtitle
        // pinned to a fixed line count in `.hero`, every card has identical
        // intrinsic height.
        .frame(width: cardSize?.width)
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
                size: avatarSize,
                agentVerification: .verified(.convos)
            )
            VStack(alignment: .leading, spacing: titleSubtitleSpacing) {
                Text(profile.displayName)
                    .font(displayNameFont)
                    .tracking(displayNameTracking)
                    .lineSpacing(0)
                    .foregroundStyle(.colorTextPrimary)
                subtitleText
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(DesignConstants.Spacing.step8x)
        .background(.colorBackgroundRaised, in: .rect(cornerRadius: Constant.cornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Constant.cornerRadius))
    }

    @ViewBuilder
    private var subtitleText: some View {
        if hasAgentDescription {
            Text(displayedSubtitle)
                .font(subtitleFont)
                .foregroundStyle(.colorTextSecondary)
                .modifier(SubtitleLineLimitModifier(lineLimit: subtitleLineLimit))
                .transition(.blurReplace)
                .id("subtitle-loaded")
        } else {
            PulsingSubtitle(text: displayedSubtitle, font: subtitleFont)
                .modifier(SubtitleLineLimitModifier(lineLimit: subtitleLineLimit))
                .transition(.blurReplace)
                .id("subtitle-placeholder")
        }
    }

    private enum Constant {
        static let standardAvatarSize: CGFloat = 40
        /// 74pt "hero" avatar -- reads as a browse-target rather than a
        /// chat-row thumbnail.
        static let heroAvatarSize: CGFloat = 74
        static let cornerRadius: CGFloat = 24
        /// Hero display-name typography: SF Pro Bold 40pt with -1pt letter
        /// spacing.
        static let heroDisplayNameFont: Font = .system(size: 40, weight: .bold)
        static let heroDisplayNameTracking: CGFloat = -1
        /// Hero variant collapses the gap between name and summary to 2pt --
        /// the two lines should read as one unit.
        static let heroTitleSubtitleSpacing: CGFloat = 2
        /// Hero variant reserves space for a 2-line summary so every card has
        /// the same intrinsic height regardless of summary length.
        static let heroSubtitleLineLimit: Int = 2
    }

    static let placeholderSubtitle: String = "Learning more about my job"
}

/// Applies `.lineLimit(_:Int, reservesSpace: true).truncationMode(.tail)` when
/// a line count is provided. The `reservesSpace` overload doesn't accept
/// `Int?`, so we branch via a `ViewModifier` rather than passing the optional
/// directly.
private struct SubtitleLineLimitModifier: ViewModifier {
    let lineLimit: Int?

    func body(content: Content) -> some View {
        if let lineLimit {
            content
                .lineLimit(lineLimit, reservesSpace: true)
                .truncationMode(.tail)
        } else {
            content
        }
    }
}

/// Opacity pulse that matches `AgentJoinStatusView`'s "Agent is
/// joining…" pacing — fades the secondary subtitle between 0.5 and 1.0 on a
/// 1.2s ease-in-out loop. Animating opacity (instead of `foregroundStyle`)
/// keeps the text's layout metrics fixed, so the pulse doesn't nudge the
/// surrounding card content. The `.animation(_:value:)` modifier scopes the
/// repeat-forever transaction so it doesn't leak into siblings.
private struct PulsingSubtitle: View {
    let text: String
    var font: Font = .body
    @State private var isPulsed: Bool = false

    var body: some View {
        Text(text)
            .font(font)
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
