import ConvosCore
import ConvosMetrics
import SwiftUI
import UIKit

/// The conversation invite-code flow: presents the Scan/Invite toggle screen
/// (`InviteCodeOverlay`) over the conversation. The Invite tab shows the
/// stylized QR encoding the invite URL plus a "Share invite link" button; the
/// Scan tab shows the live viewfinder. A thin wrapper that supplies the
/// conversation metadata, the variant mode, and the share metric hook.
struct ConversationShareOverlay: View {
    let conversation: Conversation
    let invite: Invite
    @Binding var isPresented: Bool
    let topSafeAreaInset: CGFloat
    var coreActions: any CoreActions = NoOpCoreActions()
    /// Variant: presented over an existing convo, or for a brand-new one.
    /// Defaults to `.inConvo` (every current call site is an existing convo).
    var mode: InviteCodeMode = .inConvo
    /// Segment selected on first appearance. Defaults to `.invite`; the in-convo
    /// Invite sheet's viewfinder button requests `.scan`.
    var initialSegment: ScanInviteSegment = .invite
    /// Routes a code decoded on the Scan tab. Nil keeps the Scan tab in
    /// viewfinder-only mode.
    var onScannedCode: ((String) -> Void)?
    /// Tapped on the trailing nav add-people button. Nil hides it.
    var onAddPeople: (() -> Void)?

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
        InviteCodeOverlay(
            conversation: conversation,
            encodedURLString: invite.inviteURLString,
            mode: mode,
            initialSegment: initialSegment,
            isPresented: $isPresented,
            onScannedCode: onScannedCode,
            onShareCompleted: handleShareCompletion,
            onAddPeople: onAddPeople
        )
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
