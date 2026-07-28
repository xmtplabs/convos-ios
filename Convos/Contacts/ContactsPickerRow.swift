import ConvosCore
import SwiftUI

/// Picker row showing avatar, name, and either a multi-select indicator or
/// an "in chat" badge for members already in the destination conversation.
struct ContactsPickerRow: View {
    let row: ContactsPickerViewModel.Row
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let isDisabled: Bool = row.isAlreadyInChat
        let opacity: Double = isDisabled ? DesignConstants.Opacity.subdued : 1.0
        Button(action: onTap) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ContactAvatarView(contact: row.contact)
                    .frame(
                        width: DesignConstants.ImageSizes.listAvatar,
                        height: DesignConstants.ImageSizes.listAvatar
                    )

                ContactsPickerRowText(contact: row.contact, subtitle: row.subtitle)

                Spacer(minLength: 0.0)

                if row.contact.isVerifiedAgent {
                    RoleLabelPill(label: "Agent")
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
        .disabled(isDisabled)
        .accessibilityIdentifier("contacts-picker-row-\(row.contact.inboxId)")
    }
}

// MARK: - Row text

private struct ContactsPickerRowText: View {
    let contact: Contact
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(contact.resolvedDisplayName)
                .convosTextStyle(.body)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .convosTextStyle(.supporting)
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
        ConvosBadge(label: "in chat", tone: .subtle, size: .compact)
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
    return VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
        ContactsPickerRow(
            row: .init(id: alice.inboxId, contact: alice, isAlreadyInChat: false, subtitle: "Bike Trip 2026"),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(id: bob.inboxId, contact: bob, isAlreadyInChat: false, subtitle: "DM"),
            isSelected: true,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(id: carol.inboxId, contact: carol, isAlreadyInChat: true, subtitle: "Game Night"),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(id: agent.inboxId, contact: agent, isAlreadyInChat: false, subtitle: "Convos Agent"),
            isSelected: false,
            onTap: {}
        )
    }
    .padding()
}
