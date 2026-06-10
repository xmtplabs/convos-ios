import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import SwiftUI
import UIKit

/// The conversation "Convos code" share flow: a QR card encoding the invite
/// URL with the conversation image in the center, presented over
/// `ConversationInfoView` with the native share sheet behind it. A thin
/// wrapper over the reusable `QRCodeCardOverlay`.
struct ConversationShareOverlay: View {
    let conversation: Conversation
    let invite: Invite
    @Binding var isPresented: Bool
    let topSafeAreaInset: CGFloat
    var coreActions: any CoreActions = NoOpCoreActions()

    @State private var conversationImage: Image = Image("convosOrangeIcon")
    /// Whether a real conversation image loaded. Drives the QR center: a real
    /// image renders as-is; otherwise the convos placeholder is tinted to
    /// contrast the dark center chip.
    @State private var hasConversationImage: Bool = false
    @State private var navState: ShareInviteNavigatorImpl = .init()
    @State private var navigator: ShareInviteCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = ShareInviteCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        QRCodeCardOverlay(
            encodedURLString: invite.inviteURLString,
            isPresented: $isPresented,
            topPadding: topSafeAreaInset + DesignConstants.Spacing.step4x,
            onShareCompleted: handleShareCompletion,
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
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
    }

    private func handleShareCompletion(activityType: UIActivity.ActivityType?, completed: Bool, error: Error?) {
        let target: ShareTarget = Self.shareTarget(for: activityType, completed: completed)
        let memberCount: Int = conversation.members.count
        let hasAssistant: Bool = conversation.members.contains { $0.isAgent }
        let hasExpiration: Bool = invite.expiresAt != nil
        let expiresAfterUse: Bool = invite.expiresAfterUse
        let isSuccess: Bool = completed && error == nil
        let actions: any CoreActions = coreActions
        Task {
            await actions.sharedConversation(
                memberCount: memberCount,
                hasAssistant: hasAssistant,
                shareTarget: target,
                hasExpiration: hasExpiration,
                expiresAfterUse: expiresAfterUse,
                isSuccess: isSuccess
            )
        }
    }

    private static func shareTarget(for activityType: UIActivity.ActivityType?, completed: Bool) -> ShareTarget {
        guard let activityType else { return completed ? .other : .cancelled }
        switch activityType {
        case .copyToPasteboard: return .copy
        case .message: return .messages
        case .mail: return .mail
        case .airDrop: return .airdrop
        default: return .other
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
