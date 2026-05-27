import ConvosCore
import SwiftUI

/// Picker row showing avatar, name, and either a multi-select indicator or
/// an "in chat" badge for members already in the destination conversation.
/// Renders both human contacts and agent-template contacts; the kind
/// discriminator on `Row` decides the avatar and the trailing badge.
struct ContactsPickerRow: View {
    let row: ContactsPickerViewModel.Row
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let opacity: Double = row.isAlreadyInChat ? 0.45 : 1.0
        Button(action: onTap) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                avatar
                    .frame(width: 56.0, height: 56.0)

                ContactsPickerRowText(
                    displayName: row.resolvedDisplayName,
                    subtitle: row.subtitle
                )

                Spacer(minLength: 0.0)

                if case .agentTemplate = row.kind {
                    AgentBadge()
                        .padding(.trailing, DesignConstants.Spacing.step2x)
                }

                ContactsPickerRowAccessory(
                    isAlreadyInChat: row.isAlreadyInChat,
                    isSelected: isSelected
                )
            }
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        .disabled(row.isAlreadyInChat)
        .accessibilityIdentifier("contacts-picker-row-\(row.id)")
    }

    @ViewBuilder
    private var avatar: some View {
        switch row.kind {
        case .human(let contact):
            ContactAvatarView(contact: contact)
        case .agentTemplate(let agent):
            AgentTemplateAvatarView(agentTemplateContact: agent, emojiPointSize: 28.0)
        }
    }
}

// MARK: - Row text

private struct ContactsPickerRowText: View {
    let displayName: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(displayName)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Row accessory

private struct ContactsPickerRowAccessory: View {
    let isAlreadyInChat: Bool
    let isSelected: Bool

    var body: some View {
        if isAlreadyInChat {
            inChatBadge
        } else if isSelected {
            selectedIndicator
        } else {
            unselectedIndicator
        }
    }

    private var inChatBadge: some View {
        Text("in chat")
            .font(.caption2)
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, 4.0)
            .background(
                Capsule().fill(.colorFillMinimal)
            )
    }

    private var selectedIndicator: some View {
        Image(systemName: "checkmark.circle.fill")
            .resizable()
            .frame(width: 24.0, height: 24.0)
            .foregroundStyle(.colorTextPrimary)
    }

    private var unselectedIndicator: some View {
        Image(systemName: "circle")
            .resizable()
            .frame(width: 24.0, height: 24.0)
            .foregroundStyle(.colorTextTertiary)
    }
}

// MARK: - Previews

#Preview("Variants") {
    let alice = Contact.mock(displayName: "Alice")
    let bob = Contact.mock(displayName: "Bob")
    let carol = Contact.mock(displayName: "Carol")
    let agent = Contact.mock(
        displayName: "Convo Agent",
        agentVerification: .verified(.convos)
    )
    let tifoso = AgentTemplateContact.mock(displayName: "Tifoso", emoji: "🚴")
    VStack(alignment: .leading, spacing: 12.0) {
        ContactsPickerRow(
            row: .init(
                id: "human:\(alice.inboxId)",
                kind: .human(alice),
                isAlreadyInChat: false,
                subtitle: "Bike Trip 2026"
            ),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(
                id: "human:\(bob.inboxId)",
                kind: .human(bob),
                isAlreadyInChat: false,
                subtitle: "DM"
            ),
            isSelected: true,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(
                id: "human:\(carol.inboxId)",
                kind: .human(carol),
                isAlreadyInChat: true,
                subtitle: "Game Night"
            ),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(
                id: "human:\(agent.inboxId)",
                kind: .human(agent),
                isAlreadyInChat: false,
                subtitle: "Convos Agent"
            ),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(
                id: "agent:\(tifoso.templateId)",
                kind: .agentTemplate(tifoso),
                isAlreadyInChat: false,
                subtitle: "Pro cycling expert"
            ),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(
                id: "agent:\(tifoso.templateId)",
                kind: .agentTemplate(tifoso),
                isAlreadyInChat: false,
                subtitle: "Pro cycling expert"
            ),
            isSelected: true,
            onTap: {}
        )
    }
    .padding()
}
