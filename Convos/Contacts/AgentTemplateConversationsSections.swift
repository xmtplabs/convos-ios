import ConvosCore
import SwiftUI

/// The "Convos with you" / "someone else added them" sections on the agent
/// contact card. Lists conversations that already contain this agent
/// template, split by who added the agent, reusing `ConversationsListItem`
/// for each row. Render only when there is content (see `isEmpty`).
struct AgentTemplateConversationsSections: View {
    let conversations: AgentTemplateConversations

    var body: some View {
        if !conversations.isEmpty {
            VStack(spacing: DesignConstants.Spacing.step6x) {
                if !conversations.addedByCurrentUser.isEmpty {
                    AgentTemplateConversationsSection(
                        header: "Convos with you",
                        conversations: conversations.addedByCurrentUser,
                        footer: "You added them · Using your credits",
                        showsPrivacyNote: true
                    )
                }
                if !conversations.addedByOthers.isEmpty {
                    AgentTemplateConversationsSection(
                        header: nil,
                        conversations: conversations.addedByOthers,
                        footer: "Someone else added them",
                        showsPrivacyNote: false
                    )
                }
            }
        }
    }
}

/// One grouped section: an optional header label, a rounded card of
/// conversation rows separated by dividers (plus an optional privacy note),
/// and a footer caption.
private struct AgentTemplateConversationsSection: View {
    let header: String?
    let conversations: [Conversation]
    let footer: String
    let showsPrivacyNote: Bool

    private static var privacyNote: String {
        "For privacy, agents cannot share memories, context or skills between conversations."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            if let header {
                Text(header)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.leading, DesignConstants.Spacing.step2x)
            }

            VStack(spacing: 0.0) {
                ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
                    if index > 0 {
                        Divider()
                            .padding(.leading, DesignConstants.Spacing.step4x)
                    }
                    ConversationsListItem(conversation: conversation)
                }

                if showsPrivacyNote {
                    Text(Self.privacyNote)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignConstants.Spacing.step4x)
                        .background(
                            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                                .fill(.colorFillMinimal)
                        )
                        .padding(DesignConstants.Spacing.step4x)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                    .fill(.colorBackgroundRaised)
            )

            Text(footer)
                .font(.caption2)
                .foregroundStyle(.colorTextTertiary)
                .padding(.leading, DesignConstants.Spacing.step2x)
        }
    }
}
