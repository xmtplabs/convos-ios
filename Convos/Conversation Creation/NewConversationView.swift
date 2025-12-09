import ConvosCore
import SwiftUI

struct NewConversationView: View {
    let viewModel: NewConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    let presentingFullScreen: Bool
    @State private var hasShownScannerOnAppear: Bool = false
    @State private var presentingDeleteConfirmation: Bool = false
    @State private var presentingJoiningStateInfo: Bool = false
    @State private var sidebarWidth: CGFloat = 0.0
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel.conversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: presentingFullScreen,
            sidebarColumnWidth: $sidebarWidth
        ) { focusState, coordinator in
            NavigationStack {
                @Bindable var viewModel = viewModel
                Group {
                    if viewModel.showingFullScreenScanner {
                        JoinConversationView(
                            viewModel: viewModel.qrScannerViewModel,
                            allowsDismissal: viewModel.allowsDismissingScanner,
                            onScannedCode: { inviteCode in
                                viewModel.joinConversation(inviteCode: inviteCode)
                            }
                        )
                    } else {
                        let conversationViewModel = viewModel.conversationViewModel
                        ConversationView(
                            viewModel: conversationViewModel,
                            quicknameViewModel: quicknameViewModel,
                            focusState: focusState,
                            focusCoordinator: coordinator,
                            onScanInviteCode: viewModel.onScanInviteCode,
                            onDeleteConversation: viewModel.deleteConversation,
                            confirmDeletionBeforeDismissal: viewModel.shouldConfirmDeletingConversation,
                            messagesTopBarTrailingItem: viewModel.messagesTopBarTrailingItem,
                            messagesTopBarTrailingItemEnabled: viewModel.messagesTopBarTrailingItemEnabled,
                            messagesTextFieldEnabled: viewModel.messagesTextFieldEnabled
                        ) {
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(role: .close) {
                                    if viewModel.shouldConfirmDeletingConversation {
                                        presentingDeleteConfirmation = true
                                    } else if viewModel.conversationViewModel.onboardingCoordinator.isWaitingForInviteAcceptance {
                                        presentingJoiningStateInfo = true
                                    } else {
                                        dismiss()
                                    }
                                }
                                .confirmationDialog("This convo will appear on your home screen after someone approves you",
                                                    isPresented: $presentingJoiningStateInfo,
                                                    titleVisibility: .visible) {
                                    Button("Continue") {
                                        dismiss()
                                    }
                                }
                                .confirmationDialog("", isPresented: $presentingDeleteConfirmation) {
                                    Button("Delete", role: .destructive) {
                                        viewModel.deleteConversation()
                                        dismiss()
                                    }

                                    Button("Keep") {
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                }
                .background(.colorBackgroundPrimary)
                .sheet(isPresented: $viewModel.presentingJoinConversationSheet) {
                    JoinConversationView(viewModel: viewModel.qrScannerViewModel, allowsDismissal: true) { inviteCode in
                        viewModel.joinConversation(inviteCode: inviteCode)
                    }
                }
                .selfSizingSheet(item: $viewModel.displayError) { error in
                    InfoView(title: error.title, description: error.description)
                        .background(.colorBackgroundRaised)
                }
            }
        }
        .onAppear {
            // Update coordinator's horizontal size class on appear
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            // Update coordinator's horizontal size class when it changes
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
    }
}

#Preview {
    @Previewable @State var viewModel: NewConversationViewModel = .init(
        session: ConvosClient.mock().session,
        messagingService: MockMessagingService(),
        showingFullScreenScanner: false
    )
    @Previewable @State var quicknameViewModel: QuicknameSettingsViewModel = .shared
    @Previewable @State var presented: Bool = true
    VStack {
    }
    .fullScreenCover(isPresented: $presented) {
        NewConversationView(
            viewModel: viewModel,
            quicknameViewModel: quicknameViewModel,
            presentingFullScreen: true
        )
    }
}
