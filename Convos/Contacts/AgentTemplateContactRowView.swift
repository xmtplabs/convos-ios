import ConvosCore
import SwiftUI

/// Compact row for an agent-template contact in the alphabetical contacts
/// list. Mirrors `ContactRowView`'s layout - avatar, name - and tags the
/// row with an Agent badge so it reads distinctly from a human row.
struct AgentTemplateContactRowView: View {
    let agentTemplateContact: AgentTemplateContact

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            AgentTemplateAvatarView(agentTemplateContact: agentTemplateContact)
                .frame(width: 32, height: 32)

            Text(agentTemplateContact.resolvedDisplayName)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)

            Spacer()

            AgentBadge()
        }
        .padding(.vertical, 2.0)
        .accessibilityIdentifier("agent-template-row-\(agentTemplateContact.templateId)")
    }
}

/// The "Agent" capsule tag shared by the agent-template list row and the
/// standalone agent-template contact card. Matches the verified-agent
/// role-label capsule styling `ContactRowView` already uses.
struct AgentBadge: View {
    var body: some View {
        Text("Agent")
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .background(.colorTextSecondary.opacity(0.1), in: .capsule)
    }
}

/// Avatar for an agent-template contact: the template emoji centered in a
/// neutral circle. The emoji is the template's stable visual identity - a
/// running instance's avatar is encrypted per-conversation and not
/// available to a non-scoped browse row. Falls back to a name monogram
/// when no emoji has been observed. `emojiPointSize` lets the caller scale
/// from the 32pt list row up to the 140pt card header.
struct AgentTemplateAvatarView: View {
    let agentTemplateContact: AgentTemplateContact
    var emojiPointSize: CGFloat = 18.0

    var body: some View {
        Circle()
            .fill(.colorFillMinimal)
            .overlay {
                Text(symbol)
                    .font(.system(size: emojiPointSize))
            }
    }

    private var symbol: String {
        if let emoji = agentTemplateContact.emoji, !emoji.isEmpty {
            return emoji
        }
        let trimmed = agentTemplateContact.resolvedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "🤖" }
        return String(first).uppercased()
    }
}

#Preview {
    VStack(alignment: .leading) {
        AgentTemplateContactRowView(
            agentTemplateContact: .mock(displayName: "Tifoso", emoji: "🚴")
        )
        AgentTemplateContactRowView(
            agentTemplateContact: .mock(displayName: "Trip Planner", emoji: "🗺️")
        )
        AgentTemplateContactRowView(
            agentTemplateContact: .mock(displayName: nil, emoji: nil)
        )
    }
    .padding()
}
