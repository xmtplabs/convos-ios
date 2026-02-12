import ConvosCore
import SwiftUI

struct ConversationInfoPreview: View {
    let conversation: Conversation

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
                        Text(conversation.displayName)
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

            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "clock.fill")
                    .accessibilityHidden(true)

                Text("Earlier messages are hidden for privacy")
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.displayName), \(conversation.membersCountString). Earlier messages are hidden for privacy")
        .accessibilityIdentifier("conversation-info-preview")
        .id("convo-info-\(conversation.id)")
    }
}

#Preview {
    ConversationInfoPreview(conversation: .mock())
}
