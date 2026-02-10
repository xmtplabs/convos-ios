import ConvosCore
import PhotosUI
import SwiftUI

struct ConversationToolbarButton: View {
    let conversation: Conversation
    @Binding var conversationImage: UIImage?
    @Environment(\.dismiss) private var dismiss: DismissAction

    let conversationName: String
    let placeholderName: String
    let subtitle: String
    let scheduledExplosionDate: Date?
    let action: () -> Void

    init(
        conversation: Conversation,
        conversationImage: Binding<UIImage?>,
        conversationName: String,
        placeholderName: String,
        subtitle: String = "Customize",
        scheduledExplosionDate: Date? = nil,
        action: @escaping () -> Void
    ) {
        self.conversation = conversation
        self._conversationImage = conversationImage
        self.conversationName = conversationName
        self.placeholderName = placeholderName
        self.subtitle = subtitle
        self.scheduledExplosionDate = scheduledExplosionDate
        self.action = action
    }

    var title: String {
        guard !conversationName.isEmpty else {
            return placeholderName
        }
        return conversationName
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let expiresAt = scheduledExplosionDate {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(ExplosionDurationFormatter.countdown(until: expiresAt, from: context.date))
                    .lineLimit(1)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.colorCaution)
            }
        } else {
            Text(subtitle)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 0.0) {
                ConversationAvatarView(
                    conversation: conversation,
                    conversationImage: conversationImage
                )
                .frame(width: 36.0, height: 36.0)

                VStack(alignment: .leading, spacing: 0.0) {
                    Text(title)
                        .lineLimit(1)
                        .frame(maxWidth: 140.0, alignment: .leading)
                        .font(.callout.weight(.medium))
                        .truncationMode(.tail)
                        .foregroundStyle(.colorTextPrimary)
                        .fixedSize()
                    subtitleView
                }
                .padding(.horizontal, DesignConstants.Spacing.step2x)
            }
            .padding(DesignConstants.Spacing.step2x)
        }
    }
}

#Preview {
    @Previewable @State var conversation: Conversation = .mock()
    @Previewable @State var conversationImage: UIImage?

    VStack {
        ConversationToolbarButton(conversation: conversation,
                                  conversationImage: $conversationImage,
                                  conversationName: "The Convo",
                                  placeholderName: "Untitled") {}
    }
}
