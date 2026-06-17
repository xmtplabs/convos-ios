import Combine
import ConvosCore
import SwiftUI

/// In-chat "activating agent" card shown to the creator while a direct build
/// runs (driven by `ConversationViewModel.directBuildGeneration`).
///
/// The backend (PR #309) writes the whole `preview` + `progressPhrases` set in
/// one shot when the generation reaches `running`, so this view paces the
/// reveal client-side to fill the ~30s build: the name appears first, then the
/// emoji, then the description (a few seconds apart), while the caption cycles
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

    /// 0 = nothing, 1 = name, 2 = name + emoji, 3 = name + emoji + description.
    private var revealStage: Int {
        switch content.phase {
        case .preparing:
            return 0
        case .finishing:
            return 3
        case .generating:
            // Hold the placeholder for a beat before revealing the name, then
            // name -> emoji -> description, ~`tickSeconds` apart.
            return min(tick, 3)
        }
    }

    private var title: String {
        if revealStage >= 1, let name = content.agentName, !name.isEmpty {
            return name
        }
        return "Activating agent"
    }

    private var hasName: Bool {
        revealStage >= 1 && content.agentName?.isEmpty == false
    }

    private var showsEmoji: Bool {
        revealStage >= 2 && content.emoji?.isEmpty == false
    }

    private var resolvedDescription: String? {
        guard revealStage >= 3, let description = content.agentDescription, !description.isEmpty else {
            return nil
        }
        return description
    }

    private var caption: String {
        switch content.phase {
        case .finishing:
            if let name = content.agentName, !name.isEmpty {
                return "\(name) will be great in groupchats"
            }
            return "Agent will join soon"
        case .preparing:
            return "Agent will join soon"
        case .generating:
            guard !content.progressPhrases.isEmpty else { return "Agent will join soon" }
            return content.progressPhrases[tick % content.progressPhrases.count]
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
            card
            Text(caption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Constant.accent)
                .multilineTextAlignment(.center)
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
                if let description = resolvedDescription {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.colorTextSecondary)
                        .transition(.blurReplace)
                        .id("agent-activating-description")
                }
            }
            ProgressView(value: progressFraction)
                .tint(Constant.accent)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(DesignConstants.Spacing.step8x)
        .background(.colorBackgroundRaised, in: .rect(cornerRadius: Constant.cornerRadius))
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
        static let accent: Color = .orange
        static let cornerRadius: CGFloat = 24
        static let avatarSize: CGFloat = 64
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
