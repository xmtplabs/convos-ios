import ConvosCore
import ConvosCoreiOS
import SwiftUI

/// The conversation "Convos code" share flow: a QR card encoding the invite
/// URL with the conversation image in the center, presented over
/// `ConversationInfoView` with the native share sheet behind it. A thin
/// wrapper over the reusable `QRCodeCardOverlay`.
struct ConversationShareOverlay: View {
    let conversation: Conversation
    let invite: Invite
    @Binding var isPresented: Bool
    let topSafeAreaInset: CGFloat

    @State private var conversationImage: Image = Image("convosOrangeIcon")
    /// Whether a real conversation image loaded. Drives the QR center: a real
    /// image renders as-is; otherwise the convos placeholder is tinted to
    /// contrast the dark center chip.
    @State private var hasConversationImage: Bool = false

    var body: some View {
        QRCodeCardOverlay(
            encodedURLString: invite.inviteURLString,
            isPresented: $isPresented,
            topPadding: topSafeAreaInset + DesignConstants.Spacing.step4x,
            header: {
                HStack(alignment: .center) {
                    Text("Convos code")
                        .kerning(1.0)
                    Image("convosOrangeIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14.0, height: 14.0)
                        .foregroundStyle(.colorFillTertiary)
                    Text("Scan to join")
                        .kerning(1.0)
                }
            },
            center: {
                centerChip
            }
        )
        .cachedImage(for: conversation) { image in
            if let image {
                conversationImage = Image(uiImage: image)
                hasConversationImage = true
            }
        }
    }

    private var centerChip: some View {
        ZStack {
            Rectangle()
                .fill(.colorTextPrimary)
            if hasConversationImage {
                conversationImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                GeometryReader { proxy in
                    let inset: CGFloat = min(proxy.size.width, proxy.size.height) * 0.2
                    Image("convosOrangeIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .padding(inset)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small))
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true
    ZStack {
        Color.gray.ignoresSafeArea()
        Text("Conversation Content")

        if isPresented {
            ConversationShareOverlay(
                conversation: .mock(),
                invite: .mock(),
                isPresented: $isPresented,
                topSafeAreaInset: 59.0
            )
        }
    }
}
