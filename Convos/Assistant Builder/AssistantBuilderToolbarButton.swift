import ConvosCore
import SwiftUI

/// Capsule indicator at the top of the AssistantBuilderView. Mirrors
/// `ConversationToolbarButton`'s visual structure (avatar + name + subtitle)
/// but shows the assistant-specific data: assistant avatar (not the group's
/// emoji), assistant name (or "New assistant" placeholder), and a "Draft"
/// subtitle.
struct AssistantBuilderToolbarButton: View {
    let assistantProfile: Profile?
    let assistantVerification: AgentVerification
    let assistantName: String
    let placeholderName: String
    let subtitle: String

    var title: String {
        assistantName.isEmpty ? placeholderName : assistantName
    }

    var body: some View {
        HStack(spacing: 0.0) {
            avatar
                .frame(width: 36.0, height: 36.0)

            VStack(alignment: .leading, spacing: 0.0) {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: 160.0, alignment: .leading)
                    .font(.callout.weight(.medium))
                    .truncationMode(.tail)
                    .foregroundStyle(.colorTextPrimary)
                    .fixedSize()
                Text(subtitle)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
        }
        .padding(DesignConstants.Spacing.step2x)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityIdentifier("assistant-builder-toolbar-button")
    }

    /// Same component path the conversation indicator uses, just sourced from
    /// a single `Profile` instead of a `Conversation`. Before the assistant
    /// joins, falls through `AvatarView` directly with a hammer placeholder
    /// to signal "still being built."
    @ViewBuilder
    private var avatar: some View {
        if let assistantProfile {
            ProfileAvatarView(
                profile: assistantProfile,
                profileImage: nil,
                useSystemPlaceholder: false,
                agentVerification: assistantVerification
            )
        } else {
            AvatarView(
                fallbackName: "",
                cacheableObject: Profile.empty(),
                placeholderImage: nil,
                placeholderImageName: "hammer.fill"
            )
        }
    }
}

#Preview("placeholder (no assistant yet)") {
    AssistantBuilderToolbarButton(
        assistantProfile: nil,
        assistantVerification: .unverified,
        assistantName: "",
        placeholderName: "New assistant",
        subtitle: "Draft"
    )
    .clipShape(.capsule)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding()
}

#Preview("named assistant") {
    AssistantBuilderToolbarButton(
        assistantProfile: .empty(inboxId: "agent-1"),
        assistantVerification: .verified(.convos),
        assistantName: "Travel Buddy",
        placeholderName: "New assistant",
        subtitle: "Draft"
    )
    .clipShape(.capsule)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding()
}
