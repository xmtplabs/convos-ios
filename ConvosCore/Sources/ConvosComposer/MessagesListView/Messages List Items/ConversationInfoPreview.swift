#if canImport(UIKit)
import ConvosCore
import SwiftUI

struct ConversationInfoPreview: View {
    let conversation: Conversation
    /// Resolves an inbox to the user's `Contact` so the preview shows
    /// the contact's display name (and the auto-generated DM title
    /// falls back to it) when the per-conversation profile is empty.
    /// Mirrors the resolver threaded through the chat indicator and
    /// system-message cells.
    var memberContactOverride: (String) -> Contact? = { _ in nil }
    /// App-supplied backwards-secrecy explainer sheet content; nil (e.g. in
    /// extension hosts) presents an empty sheet.
    var infoSheetContent: (() -> AnyView)?

    @State private var presentingInfoSheet: Bool = false

    private var resolvedDisplayName: String {
        conversation.computedDisplayName(memberNameOverride: { memberContactOverride($0)?.displayName })
    }

    /// Whether the "earlier messages are hidden" note belongs here.
    ///
    /// Not for the creator: they were there from the first message, so there is
    /// nothing earlier that could have been hidden from them, and telling them
    /// otherwise is confusing rather than reassuring. Not for a convo started
    /// from the contacts picker either (`hidesInviteCard`) - the user just made
    /// it and already knows nothing came before.
    private var showsBackwardsSecrecyNote: Bool {
        !conversation.hidesInviteCard && !conversation.creator.isCurrentUser
    }

    private var accessibilityLabelText: String {
        var parts = [resolvedDisplayName, conversation.membersCountString]
        if showsBackwardsSecrecyNote { parts.append("Earlier messages are hidden for privacy") }
        if let duration = conversation.disappearingMessagesDurationTitle {
            parts.append("Messages disappear after \(duration)")
            if conversation.hasAgent, conversation.participationMode != .paused {
                parts.append("An agent is listening and may save these messages even after they disappear from Convos")
            }
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            VStack {
                VStack(spacing: DesignConstants.Spacing.step2x) {
                    ConversationAvatarView(
                        conversation: conversation,
                        conversationImage: nil
                    )
                    .frame(width: 96.0, height: 96.0)

                    VStack(spacing: DesignConstants.Spacing.stepHalf) {
                        Text(resolvedDisplayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.colorTextPrimary)
                        if let description = conversation.description, !description.isEmpty {
                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.colorTextPrimary)
                        }
                    }
                    .padding(.horizontal, DesignConstants.Spacing.step2x)

                    Text(conversation.membersCountString)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(DesignConstants.Spacing.step6x)
            }
            .frame(maxWidth: 294.0)
            .background(.colorFillMinimal)
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarger))

            if showsBackwardsSecrecyNote {
                let infoAction = { presentingInfoSheet = true }
                Button(action: infoAction) {
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Image(systemName: "backward.circle.fill")
                            .foregroundStyle(.colorFillTertiary)
                            .accessibilityHidden(true)

                        Text("Earlier messages are hidden for privacy")
                            .padding(.vertical, DesignConstants.Spacing.step2x)
                    }
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                }
            }

            if let duration = conversation.disappearingMessagesDurationTitle {
                HStack(alignment: .top, spacing: DesignConstants.Spacing.stepX) {
                    Image(systemName: "timer")
                        .foregroundStyle(.colorFillTertiary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text("Messages disappear after \(duration).")
                        if conversation.hasAgent, conversation.participationMode != .paused {
                            Text("An agent is listening and may save these messages even after they disappear from Convos.")
                        }
                    }
                    .multilineTextAlignment(.leading)
                }
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: 294.0, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityIdentifier("conversation-info-preview")
        .id("convo-info-\(conversation.id)")
        .selfSizingSheet(isPresented: $presentingInfoSheet) {
            infoSheetContent?() ?? AnyView(EmptyView())
        }
    }
}

#Preview {
    ConversationInfoPreview(conversation: .mock())
}
#endif
