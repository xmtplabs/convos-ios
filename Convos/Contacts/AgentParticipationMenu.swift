import SwiftUI

// MARK: - Agent participation

/// How much an agent talks in a specific conversation. The owner/members pick a
/// level; the agent keeps *working* at every level short of leaving — only how
/// much it *speaks* changes.
///
/// NOTE (spec, 2026-07-20): product planning trimmed this to three live levels —
/// `speakFreely`, `mentionsOnly`, `paused`. `listenOnly` (+ its "mute for…"
/// duration) and `leaveRoom` are rendered here to match the current Figma while
/// the final set is decided; gate them behind `Self.liveCases` when we lock it.
enum AgentParticipationLevel: String, CaseIterable, Identifiable {
    case speakFreely
    case mentionsOnly
    case listenOnly
    case paused
    case leaveRoom

    var id: String { rawValue }

    /// The subset shipping in v1 per the current spec. Swap the menu's data
    /// source to this to drop Listen-only + Leave-the-room without touching layout.
    static let liveCases: [AgentParticipationLevel] = [.speakFreely, .mentionsOnly, .paused]

    var title: String {
        switch self {
        case .speakFreely: "Speak freely"
        case .mentionsOnly: "Mentions only"
        case .listenOnly: "Listen only"
        case .paused: "Paused"
        case .leaveRoom: "Leave the room"
        }
    }

    var caption: String {
        switch self {
        case .speakFreely: "Chime in any time"
        case .mentionsOnly: "Speak when you see your name"
        case .listenOnly: "Mute for …"
        case .paused: "Offline, uses no credits"
        case .leaveRoom: "Until invited back"
        }
    }

    /// Opens a follow-up step (the duration picker) rather than selecting inline.
    var hasDisclosure: Bool { self == .listenOnly }
}

/// The floating "Agent participation" menu: a frosted card of levels with a
/// leading check on the current one and a disclosure on any level that opens a
/// follow-up step. Presentation-agnostic — drop it in a popover, a sheet, or a
/// `.contextMenu`-style overlay from the agent's profile.
struct AgentParticipationMenu: View {
    let levels: [AgentParticipationLevel]
    let selection: AgentParticipationLevel
    let onSelect: (AgentParticipationLevel) -> Void

    init(
        levels: [AgentParticipationLevel] = AgentParticipationLevel.allCases,
        selection: AgentParticipationLevel,
        onSelect: @escaping (AgentParticipationLevel) -> Void
    ) {
        self.levels = levels
        self.selection = selection
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            Text("Agent participation")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
                ForEach(levels) { level in
                    row(for: level)
                }
            }
        }
        .padding(.vertical, DesignConstants.Spacing.step6x)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLargest, style: .continuous)
                .fill(.regularMaterial)
        )
        // Tight, single-direction lift — reads as a floating menu, not a halo.
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 6)
    }

    private func row(for level: AgentParticipationLevel) -> some View {
        Button {
            onSelect(level)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step3x) {
                // Fixed check gutter so titles align whether or not selected.
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .opacity(level == selection ? 1 : 0)
                    .frame(width: DesignConstants.Spacing.step6x, alignment: .leading)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(level.title)
                        .font(.title3.weight(.regular))
                        .foregroundStyle(.colorTextPrimary)
                    Text(level.caption)
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                }

                Spacer(minLength: DesignConstants.Spacing.step2x)

                if level.hasDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                }
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

/// The trimmed three-level set (current spec) — same layout, no Listen-only /
/// Leave-the-room.
#Preview("Participation menu (3-level spec)") {
    struct Harness: View {
        @State private var selection: AgentParticipationLevel = .mentionsOnly
        var body: some View {
            ZStack {
                Color(.systemGray5).ignoresSafeArea()
                AgentParticipationMenu(
                    levels: AgentParticipationLevel.liveCases,
                    selection: selection
                ) { selection = $0 }
                .frame(maxWidth: 360)
                .padding()
            }
        }
    }
    return Harness()
}
