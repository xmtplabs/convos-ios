import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactsPickerSelectedPills` renders the row of selected-contact pills
// that sits directly below the `ContactsPickerSearchBar` in
// `ContactsPickerView`. Each pill shows the contact's avatar and display
// name with a trailing x hint; tapping anywhere on the pill removes the
// contact from the selection. Pills wrap to multiple rows when they
// overflow the available width (via the private `SelectedPillsFlowLayout`
// below), so the full selection is always visible.
//
// The view is presentation-only: `contacts` (the current selection) and
// `onRemove` (the deselect callback) come from the caller. It renders
// nothing when `contacts` is empty so the search bar sits flush against
// the list.

/// Wrapping row of selected-contact pills shown below the picker search bar.
/// Tapping anywhere on a pill removes the contact from the selection.
/// Renders human pills and agent-template pills in one flow row; both kinds
/// share the same capsule shape with the kind-appropriate avatar inside.
struct ContactsPickerSelectedPills: View {
    let humans: [Contact]
    let agentTemplates: [AgentTemplateContact]
    let onRemoveHuman: (String) -> Void
    let onRemoveAgentTemplate: (String) -> Void

    private var isEmpty: Bool {
        humans.isEmpty && agentTemplates.isEmpty
    }

    var body: some View {
        if !isEmpty {
            SelectedPillsFlowLayout(
                horizontalSpacing: DesignConstants.Spacing.step2x,
                verticalSpacing: DesignConstants.Spacing.step2x
            ) {
                ForEach(humans, id: \.inboxId) { contact in
                    SelectedContactPill(
                        contact: contact,
                        onRemove: removeHumanAction(for: contact.inboxId)
                    )
                }
                ForEach(agentTemplates, id: \.templateId) { agent in
                    SelectedAgentTemplatePill(
                        agentTemplateContact: agent,
                        onRemove: removeAgentTemplateAction(for: agent.templateId)
                    )
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.bottom, DesignConstants.Spacing.step2x)
            .accessibilityIdentifier("contacts-picker-selected-pills")
        }
    }

    private func removeHumanAction(for inboxId: String) -> () -> Void {
        { onRemoveHuman(inboxId) }
    }

    private func removeAgentTemplateAction(for templateId: String) -> () -> Void {
        { onRemoveAgentTemplate(templateId) }
    }
}

// MARK: - Pill

private struct SelectedContactPill: View {
    let contact: Contact
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ContactAvatarView(contact: contact)
                    .frame(width: Constant.avatarSize, height: Constant.avatarSize)

                Text(truncatedDisplayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .lineLimit(1)

                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimaryInverted.opacity(Constant.removeIconOpacity))
            }
            .padding(DesignConstants.Spacing.step3x)
            .background(
                Capsule().fill(.colorTextPrimary)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(contact.resolvedDisplayName)")
        .accessibilityIdentifier("contacts-picker-pill-\(contact.inboxId)")
    }

    /// Caps the pill's visible name so the trailing x stays in-bounds even
    /// for unusually long display names. The cap is character-based (rather
    /// than width-based) for predictable layout across locales and dynamic
    /// type sizes; tune `Constant.maxDisplayNameLength` to widen or tighten.
    private var truncatedDisplayName: String {
        let name = contact.resolvedDisplayName
        let limit = Constant.maxDisplayNameLength
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)) + "\u{2026}"
    }

    private enum Constant {
        static let avatarSize: CGFloat = 24.0
        static let removeIconOpacity: Double = 0.6
        static let maxDisplayNameLength: Int = 20
    }
}

// MARK: - Agent template pill

private struct SelectedAgentTemplatePill: View {
    let agentTemplateContact: AgentTemplateContact
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                AgentTemplateAvatarView(
                    agentTemplateContact: agentTemplateContact,
                    emojiPointSize: 14.0
                )
                .frame(width: Constant.avatarSize, height: Constant.avatarSize)

                Text(truncatedDisplayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .lineLimit(1)

                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimaryInverted.opacity(Constant.removeIconOpacity))
            }
            .padding(DesignConstants.Spacing.step3x)
            .background(
                Capsule().fill(.colorTextPrimary)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(agentTemplateContact.resolvedDisplayName)")
        .accessibilityIdentifier("contacts-picker-agent-pill-\(agentTemplateContact.templateId)")
    }

    private var truncatedDisplayName: String {
        let name = agentTemplateContact.resolvedDisplayName
        let limit = Constant.maxDisplayNameLength
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)) + "\u{2026}"
    }

    private enum Constant {
        static let avatarSize: CGFloat = 24.0
        static let removeIconOpacity: Double = 0.6
        static let maxDisplayNameLength: Int = 20
    }
}

// MARK: - Layout

/// Private wrapping layout used by `ContactsPickerSelectedPills` to flow
/// pills onto multiple rows when they overflow the available width. Kept
/// private because the project's shared `FlowLayout` (in `Shared Views/`)
/// is excluded from the Convos target's build; this duplicates just the
/// behavior we need.
private struct SelectedPillsFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth: CGFloat = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0.0
        var totalHeight: CGFloat = 0.0
        var rowHeight: CGFloat = 0.0
        var hasItemOnRow: Bool = false

        for subview in subviews {
            let size: CGSize = subview.sizeThatFits(.unspecified)
            let needsWrap: Bool = hasItemOnRow && (rowWidth + horizontalSpacing + size.width > maxWidth)
            if needsWrap {
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
                hasItemOnRow = true
            } else {
                if hasItemOnRow {
                    rowWidth += horizontalSpacing
                }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
                hasItemOnRow = true
            }
        }

        let resolvedWidth: CGFloat = proposal.width ?? rowWidth
        return CGSize(width: resolvedWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxX: CGFloat = bounds.maxX
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0.0
        var hasItemOnRow: Bool = false

        for subview in subviews {
            let size: CGSize = subview.sizeThatFits(.unspecified)
            let needsWrap: Bool = hasItemOnRow && (x + horizontalSpacing + size.width > maxX)
            if needsWrap {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0.0
                hasItemOnRow = false
            }
            if hasItemOnRow {
                x += horizontalSpacing
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
            hasItemOnRow = true
        }
    }
}

// MARK: - Previews

#Preview("Few pills") {
    ContactsPickerSelectedPills(
        humans: [
            .mock(displayName: "Zed"),
            .mock(displayName: "Andy"),
        ],
        agentTemplates: [],
        onRemoveHuman: { _ in },
        onRemoveAgentTemplate: { _ in }
    )
    .padding()
    .background(.colorBackgroundRaisedSecondary)
}

#Preview("Humans + agents") {
    ContactsPickerSelectedPills(
        humans: [
            .mock(displayName: "Alice"),
            .mock(displayName: "Bob"),
        ],
        agentTemplates: [
            .mock(displayName: "Tifoso", emoji: "🚴"),
            .mock(displayName: "Trip Planner", emoji: "🗺️"),
        ],
        onRemoveHuman: { _ in },
        onRemoveAgentTemplate: { _ in }
    )
    .padding()
    .background(.colorBackgroundRaisedSecondary)
}

#Preview("Many pills (wrap)") {
    ContactsPickerSelectedPills(
        humans: [
            .mock(displayName: "Alice"),
            .mock(displayName: "Bob"),
            .mock(displayName: "Carol"),
            .mock(displayName: "Daniel"),
            .mock(displayName: "Evelyn"),
            .mock(displayName: "Frederick"),
            .mock(displayName: "Genevieve"),
            .mock(displayName: "Hieronymus"),
        ],
        agentTemplates: [],
        onRemoveHuman: { _ in },
        onRemoveAgentTemplate: { _ in }
    )
    .padding()
    .background(.colorBackgroundRaisedSecondary)
}

#Preview("Empty (renders nothing)") {
    ContactsPickerSelectedPills(
        humans: [],
        agentTemplates: [],
        onRemoveHuman: { _ in },
        onRemoveAgentTemplate: { _ in }
    )
    .padding()
    .background(.colorBackgroundRaisedSecondary)
}

#Preview("Long names truncate") {
    ContactsPickerSelectedPills(
        humans: [
            .mock(displayName: "Alice"),
            .mock(displayName: "Fitzwilliam-Bartholomew Maximilian Featherington"),
            .mock(displayName: "Rumpelstiltskin"),
        ],
        agentTemplates: [
            .mock(displayName: "Globe-Trotting Adventure Concierge", emoji: "🌍"),
        ],
        onRemoveHuman: { _ in },
        onRemoveAgentTemplate: { _ in }
    )
    .padding()
    .background(.colorBackgroundRaisedSecondary)
}
