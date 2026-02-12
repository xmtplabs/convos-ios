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
    let action: () -> Void
    var longPressAction: (() -> Void)?

    init(
        conversation: Conversation,
        conversationImage: Binding<UIImage?>,
        conversationName: String,
        placeholderName: String,
        subtitle: String = "Customize",
        action: @escaping () -> Void,
        longPressAction: (() -> Void)? = nil
    ) {
        self.conversation = conversation
        self._conversationImage = conversationImage
        self.conversationName = conversationName
        self.placeholderName = placeholderName
        self.subtitle = subtitle
        self.action = action
        self.longPressAction = longPressAction
    }

    var title: String {
        guard !conversationName.isEmpty else {
            return placeholderName
        }
        return conversationName
    }

    private var content: some View {
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
                Text(subtitle)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
        }
        .padding(DesignConstants.Spacing.step2x)
    }

    var body: some View {
        if longPressAction != nil {
            content
                .contentShape(.rect)
                .onTapGesture(perform: action)
                .onLongPressGesture(perform: longPressAction ?? {})
        } else {
            Button(action: action) {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityIdentifier("conversation-toolbar-button")
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
