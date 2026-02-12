import ConvosCore
import SwiftUI

struct NewConversationView: View {
    let viewModel: NewConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    @State private var hasShownScannerOnAppear: Bool = false
    @State private var presentingJoiningStateInfo: Bool = false
    @State private var sidebarWidth: CGFloat = 0.0
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel.conversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: false,
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
                    } else if let conversationViewModel = viewModel.conversationViewModel {
                        ConversationView(
                            viewModel: conversationViewModel,
                            quicknameViewModel: quicknameViewModel,
                            focusState: focusState,
                            focusCoordinator: coordinator,
                            onScanInviteCode: viewModel.onScanInviteCode,
                            onDeleteConversation: viewModel.deleteConversation,
                            messagesTopBarTrailingItem: viewModel.messagesTopBarTrailingItem,
                            messagesTopBarTrailingItemEnabled: viewModel.messagesTopBarTrailingItemEnabled,
                            messagesTextFieldEnabled: viewModel.messagesTextFieldEnabled
                        ) {
                        }
                    } else {
                        EmptyView()
                    }
                }
                .toolbar {
                    if !viewModel.showingFullScreenScanner {
                        ToolbarItem(placement: .topBarLeading) {
                            let closeAction = {
                                if viewModel.conversationViewModel?.onboardingCoordinator.isWaitingForInviteAcceptance == true {
                                    presentingJoiningStateInfo = true
                                } else {
                                    dismiss()
                                }
                            }
                            Button(role: .close, action: closeAction)
                                .confirmationDialog("This convo will appear on your home screen after someone approves you",
                                                    isPresented: $presentingJoiningStateInfo,
                                                    titleVisibility: .visible) {
                                    Button("Continue") {
                                        dismiss()
                                    }
                                }
                        }
                    }
                }
                .background(.colorBackgroundSurfaceless)
                .sheet(isPresented: $viewModel.presentingJoinConversationSheet) {
                    JoinConversationView(viewModel: viewModel.qrScannerViewModel, allowsDismissal: true) { inviteCode in
                        viewModel.joinConversation(inviteCode: inviteCode)
                    }
                }
                .selfSizingSheet(item: $viewModel.displayError) { error in
                    if let retryAction = error.retryAction {
                        ErrorSheetWithRetry(
                            title: error.title,
                            description: error.description,
                            onRetry: { viewModel.retryAction(retryAction) },
                            onCancel: { viewModel.dismissWithDeletion() }
                        )
                        .background(.colorBackgroundRaised)
                    } else {
                        InfoView(
                            title: error.title,
                            description: error.description,
                            onDismiss: { viewModel.dismissWithDeletion() }
                        )
                        .background(.colorBackgroundRaised)
                    }
                }
            }
        }
        .onAppear {
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
            viewModel.setDismissAction(dismiss)
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
    }
}

private struct ErrorSheetWithRetry: View {
    let title: String
    let description: String
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(title)
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text(description)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    onRetry()
                } label: {
                    Text("Try again")
                }
                .convosButtonStyle(.rounded(fullWidth: true))
                .accessibilityIdentifier("error-retry-button")

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                }
                .convosButtonStyle(.text)
                .accessibilityIdentifier("error-cancel-button")
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
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
    .sheet(isPresented: $presented) {
        NewConversationView(
            viewModel: viewModel,
            quicknameViewModel: quicknameViewModel
        )
    }
}
