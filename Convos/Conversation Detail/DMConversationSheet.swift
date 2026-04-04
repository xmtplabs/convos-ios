import SwiftUI

struct DMConversationSheet: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    @State private var sidebarWidth: CGFloat = 0.0
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: false,
            sidebarColumnWidth: $sidebarWidth
        ) { focusState, coordinator in
            NavigationStack {
                ConversationView(
                    viewModel: viewModel,
                    quicknameViewModel: quicknameViewModel,
                    focusState: focusState,
                    focusCoordinator: coordinator,
                    onScanInviteCode: {},
                    onDeleteConversation: { dismiss() },
                    messagesTopBarTrailingItem: .share,
                    messagesTopBarTrailingItemEnabled: true,
                    messagesTextFieldEnabled: true
                ) {
                    EmptyView()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) {
                            dismiss()
                        }
                        .accessibilityIdentifier("close-dm-conversation")
                    }
                }
                .background(.colorBackgroundSurfaceless)
            }
        }
    }
}
