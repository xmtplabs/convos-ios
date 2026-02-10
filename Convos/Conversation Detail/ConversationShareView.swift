import ConvosCore
import SwiftUI

private struct BackgroundClearView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            // Reach up the view hierarchy and clear the modal container’s background
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct ConversationShareView: View {
    let conversation: Conversation
    let invite: Invite
    @State private var conversationImage: Image = Image("convosIcon")
    @State private var hasAppeared: Bool = false

    var body: some View {
        AutoShareSheetView(
            items: [invite.inviteURLString],
            onDismiss: {
                withAnimation {
                    hasAppeared = false
                }
            },
            backgroundContent: {
                ZStack {
                    BackgroundClearView()

                    if hasAppeared {
                        Color.black.opacity(0.5)
                            .background(.ultraThinMaterial)
                            .ignoresSafeArea()

                        VStack(spacing: 0.0) {
                            VStack(spacing: 0.0) {
                                HStack(alignment: .center) {
                                    Text("Convos code")
                                        .kerning(1.0)

                                    Image("convosIcon")
                                        .renderingMode(.template)
                                        .resizable()
                                        .frame(width: 14.0, height: 14.0)
                                        .foregroundStyle(.colorFillTertiary)

                                    Text("Scan to join")
                                        .kerning(1.0)
                                }
                                .offset(y: 5.0) // qr code is generated with some padding
                                .foregroundStyle(.colorTextSecondary)
                                .textCase(.uppercase)
                                .font(.caption)
                                .frame(height: DesignConstants.Spacing.step10x)

                                if let inviteURL = invite.inviteURL {
                                    QRCodeView(
                                        url: inviteURL,
                                        centerImage: conversationImage
                                    )
                                    .padding([.leading, .trailing, .bottom], DesignConstants.Spacing.step10x)
                                }
                            }
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))

                            Spacer()
                        }
                    }
                }
                .transition(.opacity)
                .animation(.default, value: hasAppeared)
                .cachedImage(for: conversation) { image in
                    if let image {
                        conversationImage = Image(uiImage: image)
                    }
                }
                .onAppear {
                    withAnimation {
                        hasAppeared = true
                    }
                }
            }
        )
    }
}

#Preview {
    ConversationShareView(conversation: .mock(), invite: .mock())
}
