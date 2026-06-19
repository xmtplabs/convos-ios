import Combine
import ConvosCore
import SwiftUI

/// In-chat "activating agent" card shown to the creator while a direct build
/// runs (driven by `ConversationViewModel.directBuildGeneration`).
///
/// The backend (PR #309) writes the whole `preview` + `progressPhrases` set in
/// one shot when the generation reaches `running`, so this view paces the
/// reveal client-side to fill the ~30s build: the emoji appears first, then the
/// name, then the description (a few seconds apart), while the caption cycles
/// through the build-narration phrases. Because the content is stable within a
/// phase, the view's timer isn't reset by polls. Handed off to the real agent
/// contact card once the agent joins (the processor drops this card then).
struct AgentActivatingCardView: View {
    let content: AgentActivatingCardContent

    /// Wall-clock ticks since this card (this phase) appeared. Drives the
    /// staggered reveal, the phrase cycling, and the progress pacing.
    @State private var tick: Int = 0

    private let timer: Publishers.Autoconnect<Timer.TimerPublisher> = Timer
        .publish(every: Constant.tickSeconds, on: .main, in: .common)
        .autoconnect()

    /// 0 = nothing, 1 = emoji, 2 = emoji + name, 3 = emoji + name + description.
    private var revealStage: Int {
        switch content.phase {
        case .preparing:
            return 0
        case .finishing:
            return 3
        case .generating:
            // Hold the placeholder for a beat before the first reveal, then
            // emoji -> name -> description, ~`tickSeconds` apart.
            return min(tick, 3)
        }
    }

    private var title: String {
        if revealStage >= 2, let name = content.agentName, !name.isEmpty {
            return name
        }
        return "Activating agent"
    }

    private var hasName: Bool {
        revealStage >= 2 && content.agentName?.isEmpty == false
    }

    private var showsEmoji: Bool {
        revealStage >= 1 && content.emoji?.isEmpty == false
    }

    private var resolvedDescription: String? {
        guard revealStage >= 3, let description = content.agentDescription, !description.isEmpty else {
            return nil
        }
        return description
    }

    /// The reassurance line shown between API phrases (and at the tail). Uses
    /// the agent's name once it has been revealed, else the generic copy.
    private var joinSoonText: String {
        if hasName, let name = content.agentName, !name.isEmpty {
            return "\(name) will join soon"
        }
        return "Agent will join soon"
    }

    /// True only when the caption is currently showing a dynamic API progress
    /// phrase (vs the "<name> will join soon" reassurance line). Mirrors the
    /// `caption` branches so the color can differ.
    private var captionIsProgressPhrase: Bool {
        guard content.phase == .generating,
              progressFraction < Constant.generatingMax,
              !content.progressPhrases.isEmpty else {
            return false
        }
        return tick.isMultiple(of: 2)
    }

    /// Progress phrases use the grayish secondary color; the "will join soon"
    /// reassurance line keeps the lava accent.
    private var captionColor: Color {
        captionIsProgressPhrase ? .colorTextSecondary : Constant.accent
    }

    private var caption: String {
        switch content.phase {
        case .preparing, .finishing:
            return joinSoonText
        case .generating:
            // Once the progress bar plateaus near the end (the client-side proxy
            // for the end of the estimated build time, since estimatedDurationMs
            // isn't wired in yet), stop alternating with API phrases and hold the
            // reassurance line.
            if progressFraction >= Constant.generatingMax {
                return joinSoonText
            }
            guard !content.progressPhrases.isEmpty else { return joinSoonText }
            // Alternate, starting with an API phrase: even ticks show the next
            // API progress phrase, odd ticks show the reassurance line.
            if tick % 2 == 1 {
                return joinSoonText
            }
            return content.progressPhrases[(tick / 2) % content.progressPhrases.count]
        }
    }

    private var progressFraction: Double {
        switch content.phase {
        case .preparing:
            return Constant.preparingFraction
        case .finishing:
            return Constant.finishingFraction
        case .generating:
            return min(Constant.generatingBase + Double(tick) * Constant.generatingStep, Constant.generatingMax)
        }
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            // Cap the card at the message-bubble width (50pt trailing spacer +
            // `bubbleRowWidthCap`), and inset the leading edge by the avatar
            // gutter + row padding so it lines up with incoming message bubbles
            // (which leave room for the sender avatar). The caption stays centered.
            HStack(spacing: 0.0) {
                GlassEffectContainer {
                    card
                }
                Spacer()
                    .frame(minWidth: 50.0)
                    .layoutPriority(-1)
            }
            .bubbleRowWidthCap(alignment: .leading)
            .padding(.leading, Constant.leadingInset)
            Text(caption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(captionColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .transition(.blurReplace)
                .id("agent-activating-caption-\(caption)")
        }
        .onReceive(timer) { _ in
            tick += 1
        }
        .animation(.easeInOut(duration: 0.35), value: revealStage)
        .animation(.easeInOut(duration: 0.35), value: caption)
        .animation(.easeInOut(duration: 0.5), value: progressFraction)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            avatar
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(title)
                    .font(.title2)
                    .foregroundStyle(hasName ? .colorTextPrimary : .colorTextSecondary)
                    .transition(.blurReplace)
                    .id("agent-activating-title-\(title)")
                descriptionArea
            }
            ProgressView(value: progressFraction)
                .tint(Constant.accent)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(DesignConstants.Spacing.step8x)
        .background(.colorBackgroundRaised, in: .rect(cornerRadius: Constant.cornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Constant.cornerRadius))
    }

    /// Fixed-height description slot. A hidden sizer reserves a constant
    /// `descriptionLineCount`-line block from the moment the card appears
    /// (an empty `Text` collapses even with `reservesSpace`, so the sizer holds
    /// real placeholder content instead), and the real description is overlaid
    /// on top. The card's height therefore never changes when the description
    /// blur-fades in.
    private var descriptionArea: some View {
        ZStack(alignment: .topLeading) {
            Text(Constant.descriptionPlaceholder)
                .font(.body)
                .lineLimit(Constant.descriptionLineCount, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .hidden()
            if let description = resolvedDescription {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(Constant.descriptionLineCount)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.blurReplace)
                    .id("agent-activating-description")
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Constant.accent)
            avatarGlyph
        }
        .frame(width: Constant.avatarSize, height: Constant.avatarSize)
    }

    @ViewBuilder
    private var avatarGlyph: some View {
        if showsEmoji, let emoji = content.emoji {
            Text(emoji)
                .font(.system(size: Constant.avatarSize * 0.5))
                .transition(.blurReplace)
                .id("agent-activating-emoji-\(emoji)")
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: Constant.avatarSize * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private enum Constant {
        /// The verified-Convos-agent color (`#fc4f38`), matching the avatar
        /// background + name color of `AgentContactCardView` /
        /// `AgentVerification.avatarBackgroundColor` so the activating card and
        /// the finished card read as the same agent.
        static let accent: Color = .colorLava
        static let cornerRadius: CGFloat = 24
        /// Leading inset for the avatar gutter (`avatarWidth` = `smallAvatar +
        /// step2x`), aligning the card with incoming message bubbles. The row's
        /// `step4x` leading already comes from the cell's `.padding(.horizontal)`,
        /// so it is not added again here.
        static let leadingInset: CGFloat = DesignConstants.ImageSizes.smallAvatar
            + DesignConstants.Spacing.step2x
        /// Matches the in-chat agent contact card's avatar
        /// (`AgentContactCardView` `.standard` `standardAvatarSize` = 40), so the
        /// loading avatar and the finished card's avatar read as the same size.
        static let avatarSize: CGFloat = 40
        /// Lines reserved for the description so the card holds a fixed height
        /// before the text reveals (generated descriptions cap at ~140 chars).
        static let descriptionLineCount: Int = 5
        /// Non-empty filler for the hidden description sizer. Enough wrappable
        /// text to fill `descriptionLineCount` lines regardless of
        /// `reservesSpace` quirks with empty strings.
        static let descriptionPlaceholder: String = String(repeating: "reserved ", count: 23)
        /// Seconds between reveal/phrase steps. ~2.5s comfortably fills a ~30s
        /// build and finishes the reveal in the first ~5s of `running`.
        static let tickSeconds: TimeInterval = 2.5
        static let preparingFraction: Double = 0.12
        static let generatingBase: Double = 0.3
        static let generatingStep: Double = 0.08
        static let generatingMax: Double = 0.85
        static let finishingFraction: Double = 0.95
    }
}

#Preview("Preparing") {
    AgentActivatingCardView(
        content: AgentActivatingCardContent(
            id: "preview-0",
            phase: .preparing,
            agentName: nil,
            emoji: nil,
            agentDescription: nil,
            progressPhrases: []
        )
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}

#Preview("Generating") {
    AgentActivatingCardView(
        content: AgentActivatingCardContent(
            id: "preview-1",
            phase: .generating,
            agentName: "Boots",
            emoji: "⚽️",
            agentDescription: "Your family weekend sidekick and US Futsal tournament guide for Martinez, CA",
            progressPhrases: ["Reading your idea…", "Sketching a personality…", "Choosing a name…"]
        )
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}

#Preview("Finishing") {
    AgentActivatingCardView(
        content: AgentActivatingCardContent(
            id: "preview-2",
            phase: .finishing,
            agentName: "Boots",
            emoji: "⚽️",
            agentDescription: "Your family weekend sidekick and US Futsal tournament guide for Martinez, CA",
            progressPhrases: ["Almost ready…"]
        )
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}
