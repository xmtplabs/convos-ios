import SwiftUI

struct DMConversationSheet: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    @FocusState private var focusState: MessagesViewInputFocus?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    var body: some View {
        NavigationStack {
            ConversationView(
                viewModel: viewModel,
                quicknameViewModel: quicknameViewModel,
                focusState: $focusState,
                focusCoordinator: focusCoordinator,
                onScanInviteCode: {},
                onDeleteConversation: {},
                messagesTopBarTrailingItem: .share,
                messagesTopBarTrailingItemEnabled: true,
                messagesTextFieldEnabled: true,
                bottomBarContent: { EmptyView() }
            )
        }
        .background(.colorBackgroundSurfaceless)
        .presentationSizing(.page)
    }
}
