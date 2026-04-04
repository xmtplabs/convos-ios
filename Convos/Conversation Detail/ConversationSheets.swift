import SwiftUI

struct ConversationSheets: ViewModifier {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $viewModel.presentingNewConversationForInvite) { inviteVM in
                NewConversationView(
                    viewModel: inviteVM,
                    quicknameViewModel: quicknameViewModel
                )
                .background(.colorBackgroundSurfaceless)
            }
            .sheet(item: $viewModel.presentingDMConversation) { dmViewModel in
                DMConversationSheet(viewModel: dmViewModel, quicknameViewModel: quicknameViewModel)
            }
    }
}
