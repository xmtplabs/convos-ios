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

    private var accessibilityLabelText: String {
        let base = "\(resolvedDisplayName), \(conversation.membersCountString)"
        return conversation.hidesInviteCard
            ? base
            : "\(base). Earlier messages are hidden for privacy"
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

            // Convos started from the contacts picker carry
            // `hidesInviteCard = true` in their local state. The user
            // already knows nothing was here before the convo opened
            // (they just created it from the picker), so the "Earlier
            // messages are hidden" note is noise. Same flag the
            // messages controller uses to skip the QR invite header.
            if !conversation.hidesInviteCard {
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
