#if canImport(UIKit)
import ConvosCore
import SwiftUI
import UIKit

struct MessagesEmptyStateCellContent: View {
    let item: MessagesListItemType
    let onInvitePeople: () -> Void

    @State private var keyboardHeight: CGFloat = 0.0

    var body: some View {
        Group {
            switch item {
            case .groupEmptyState(let isInviteEnabled):
                GroupEmptyStateView(
                    isInviteEnabled: isInviteEnabled,
                    hidesText: keyboardHeight > 0.0,
                    onInvite: onInvitePeople
                )
            case .agentDmInfo(_, let variant):
                AgentDmEmptyStateView(
                    variant: variant,
                    hidesText: keyboardHeight > 0.0
                )
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                keyboardHeight = 0.0
            }
        }
    }
}
#endif
