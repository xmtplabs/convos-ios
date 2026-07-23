#if canImport(UIKit)
import SwiftUI

// MARK: - Agent participation

/// How much the agents in a conversation talk. Members pick a level; the agents
/// keep *working* at every level short of Pause — only how much they *speak*
/// changes.
///
/// The level belongs to the conversation, not to one agent: a room holding
/// several agents has a single setting that governs all of them, and an agent
/// that joins later inherits it.
public enum AgentParticipationLevel: String, CaseIterable, Identifiable, Sendable {
    case speakFreely
    case mentionsOnly
    case paused

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .speakFreely: "Speak freely"
        case .mentionsOnly: "Mentions only"
        case .paused: "Pause"
        }
    }

    public var caption: String {
        switch self {
        case .speakFreely: "Chime in any time"
        case .mentionsOnly: "Speak when you see your name"
        case .paused: "Go offline, use no credits"
        }
    }

    /// The mark for this level. It carries the level on its own in the
    /// composer, where there is no room for the title — so each one has to read
    /// as its own idea at a glance: sound, a name, a stop.
    public var iconSystemName: String {
        switch self {
        case .speakFreely: "speaker.wave.2"
        case .mentionsOnly: "at"
        case .paused: "pause.circle"
        }
    }

    /// Wire value for the control plane (speak / mention / paused).
    public var wireMode: String {
        switch self {
        case .speakFreely: "speak"
        case .mentionsOnly: "mention"
        case .paused: "paused"
        }
    }

    /// The level a conversation is in until someone sets one. Matches the
    /// control plane's default, so an unset room and an explicit Speak freely
    /// render identically — because they behave identically.
    public static let `default`: AgentParticipationLevel = .speakFreely

    public init?(wireMode: String) {
        switch wireMode {
        case "speak": self = .speakFreely
        case "mention": self = .mentionsOnly
        case "paused": self = .paused
        default: return nil
        }
    }
}

/// The floating "Agent participation" menu: a frosted card of levels with a
/// leading check on the current one. Presentation-agnostic — drop it in a
/// popover, a sheet, or an overlay from the composer or the agent's profile.
public struct AgentParticipationMenu: View {
    let selection: AgentParticipationLevel
    /// Draws the frosted card + shadow around the rows. Set `false` when the
    /// host already provides a surface (e.g. inside a sheet) so the panel isn't
    /// a redundant card-in-a-card.
    let showsBackground: Bool
    let onSelect: (AgentParticipationLevel) -> Void

    public init(
        selection: AgentParticipationLevel,
        showsBackground: Bool = true,
        onSelect: @escaping (AgentParticipationLevel) -> Void
    ) {
        self.selection = selection
        self.showsBackground = showsBackground
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            Text("Agent participation")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
                ForEach(AgentParticipationLevel.allCases) { level in
                    row(for: level)
                }
            }
        }
        .padding(showsBackground ? DesignConstants.Spacing.step6x : 0)
        .background {
            if showsBackground {
                RoundedRectangle(
                    cornerRadius: DesignConstants.CornerRadius.mediumLargest,
                    style: .continuous
                )
                .fill(.regularMaterial)
            }
        }
        // Tight, single-direction lift — reads as a floating menu, not a halo.
        // Only when it's a standalone card; a sheet provides its own elevation.
        .shadow(
            color: showsBackground ? .black.opacity(0.12) : .clear,
            radius: showsBackground ? 18 : 0,
            x: 0,
            y: showsBackground ? 6 : 0
        )
    }

    private func row(for level: AgentParticipationLevel) -> some View {
        Button {
            onSelect(level)
        } label: {
            HStack(alignment: .center, spacing: DesignConstants.Spacing.step3x) {
                // The icon is the same mark the composer bubble shows, so the
                // control the member taps and the level they picked are visibly
                // the same thing.
                Image(systemName: level.iconSystemName)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: DesignConstants.Spacing.step8x, alignment: .center)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(level.title)
                        .font(.title3.weight(.regular))
                        .foregroundStyle(.colorTextPrimary)
                    Text(level.caption)
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                }

                Spacer(minLength: DesignConstants.Spacing.step2x)

                // Fixed check gutter so every row's text sits on the same axis
                // whether or not it is the selected one.
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .opacity(level == selection ? 1 : 0)
                    .frame(width: DesignConstants.Spacing.step6x, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level.title)
        .accessibilityHint(level.caption)
        .accessibilityAddTraits(level == selection ? .isSelected : [])
    }
}

// MARK: - Previews

/// Interactive: tap a level and the check moves. Backed by a mock chat gradient
/// so the frosted material has something real to refract (glass over a flat
/// fill reads as a plain blurred box).
#Preview("Participation menu (interactive)") {
    struct Harness: View {
        @State private var selection: AgentParticipationLevel = .speakFreely
        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [.blue.opacity(0.25), .purple.opacity(0.15), .orange.opacity(0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                AgentParticipationMenu(selection: selection) { selection = $0 }
                    .frame(maxWidth: 360)
                    .padding()
            }
        }
    }
    return Harness()
}
#endif
