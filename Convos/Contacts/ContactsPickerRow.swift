import ConvosCore
import SwiftUI

/// Picker row showing avatar, name, and either a multi-select indicator or
/// an "in chat" badge for members already in the destination conversation.
struct ContactsPickerRow: View {
    let row: ContactsPickerViewModel.Row
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let opacity: Double = row.isAlreadyInChat ? 0.45 : 1.0
        Button(action: onTap) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ContactAvatarView(contact: row.contact)
                    .frame(width: 36.0, height: 36.0)

                ContactsPickerRowText(contact: row.contact)

                Spacer(minLength: 0.0)

                if let roleLabel = row.contact.agentVerification?.roleLabel {
                    Text(roleLabel)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .padding(.horizontal, DesignConstants.Spacing.step2x)
                        .padding(.vertical, DesignConstants.Spacing.stepX)
                        .background(.colorTextSecondary.opacity(0.1), in: .capsule)
                        .accessibilityIdentifier("contacts-picker-role-label-\(row.contact.inboxId)")
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
        .accessibilityIdentifier("contacts-picker-row-\(row.contact.inboxId)")
    }
}

// MARK: - Row text

private struct ContactsPickerRowText: View {
    let contact: Contact

    var body: some View {
        VStack(alignment: .leading, spacing: 2.0) {
            Text(contact.resolvedDisplayName)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)
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
            .font(.title3)
            .foregroundStyle(.colorTextPrimary)
    }

    private var unselectedIndicator: some View {
        Image(systemName: "circle")
            .font(.title3)
            .foregroundStyle(.colorTextTertiary)
    }
}

// MARK: - Previews

#Preview("Variants") {
    let alice = Contact.mock(displayName: "Alice")
    let bob = Contact.mock(displayName: "Bob")
    let carol = Contact.mock(displayName: "Carol")
    let assistant = Contact.mock(
        displayName: "Convo Assistant",
        agentVerification: .verified(.convos)
    )
    return VStack(alignment: .leading, spacing: 12.0) {
        ContactsPickerRow(
            row: .init(id: alice.inboxId, contact: alice, isAlreadyInChat: false),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(id: bob.inboxId, contact: bob, isAlreadyInChat: false),
            isSelected: true,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(id: carol.inboxId, contact: carol, isAlreadyInChat: true),
            isSelected: false,
            onTap: {}
        )
        ContactsPickerRow(
            row: .init(id: assistant.inboxId, contact: assistant, isAlreadyInChat: false),
            isSelected: false,
            onTap: {}
        )
    }
    .padding()
}
