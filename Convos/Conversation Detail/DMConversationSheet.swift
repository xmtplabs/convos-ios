import SwiftUI

struct DMConversationDestinationView: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    @State private var sidebarWidth: CGFloat = 0.0
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: false,
            sidebarColumnWidth: $sidebarWidth
        ) { focusState, coordinator in
            ConversationView(
                viewModel: viewModel,
                quicknameViewModel: quicknameViewModel,
                focusState: focusState,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {},
                messagesTopBarTrailingItem: .share,
                messagesTopBarTrailingItemEnabled: true,
                messagesTextFieldEnabled: true
            ) {
                EmptyView()
            }
            .background(.colorBackgroundSurfaceless)
        }
    }
}
