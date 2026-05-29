import ConvosCore
import SwiftUI

struct NewConversationView: View {
    let viewModel: NewConversationViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    /// When `true` (the default) the view wraps its content in its own
    /// `NavigationStack` -- the standalone sheet presentation. The Compose
    /// flow sets this `false` so the view is pushed onto the contacts
    /// picker's stack (no nested `NavigationStack`). When pushed the back
    /// button is hidden so the user can't return to the picker; the close
    /// (X) button tears down the whole flow via `onClose` instead.
    var embedsNavigationStack: Bool = true
    /// Closes the entire Compose flow. Set when the view is pushed onto the
    /// picker's stack; when `nil` (standalone sheet) the close button
    /// dismisses via the environment `dismiss`.
    var onClose: (() -> Void)? = nil
    @State private var hasShownScannerOnAppear: Bool = false
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
            ConditionalNavigationStack(embedsStack: embedsNavigationStack) {
                @Bindable var viewModel = viewModel
                Group {
                    if viewModel.showingFullScreenScanner {
                        JoinConversationView(
                            viewModel: viewModel.qrScannerViewModel,
                            allowsDismissal: viewModel.allowsDismissingScanner,
                            onScannedCode: { scannedCode in
                                viewModel.handleScannedCode(scannedCode)
                            }
                        )
                    } else if let conversationViewModel = viewModel.conversationViewModel {
                        ConversationView(
                            viewModel: conversationViewModel,
                            profileSettingsViewModel: profileSettingsViewModel,
                            focusState: focusState,
                            focusCoordinator: coordinator,
                            onScanInviteCode: viewModel.onScanInviteCode,
                            onDeleteConversation: viewModel.deleteConversation,
                            messagesTopBarTrailingItem: viewModel.messagesTopBarTrailingItem,
                            messagesTopBarTrailingItemEnabled: viewModel.messagesTopBarTrailingItemEnabled,
                            messagesTextFieldEnabled: viewModel.messagesTextFieldEnabled
                        ) {
                            EmptyView()
                        }
                    } else {
                        EmptyView()
                    }
                }
                .toolbar {
                    // The close (X) is the only way out in both presentations:
                    // standalone it dismisses the sheet; pushed (Compose flow)
                    // `onClose` tears down the whole flow. Paired with the
                    // hidden back button below so the pushed view can't return
                    // to the picker.
                    if !viewModel.showingFullScreenScanner {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(role: .close) {
                                if let onClose {
                                    onClose()
                                } else {
                                    dismiss()
                                }
                            }
                            .accessibilityIdentifier("close-new-conversation")
                        }
                    }
                }
                .navigationBarBackButtonHidden(!embedsNavigationStack)
                .background(.colorBackgroundSurfaceless)
                .sheet(isPresented: $viewModel.presentingJoinConversationSheet) {
                    JoinConversationView(viewModel: viewModel.qrScannerViewModel, allowsDismissal: true) { scannedCode in
                        viewModel.handleScannedCode(scannedCode)
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
                    } else {
                        InfoView(
                            title: error.title,
                            description: error.description,
                            onDismiss: { viewModel.dismissWithDeletion() }
                        )
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
            viewModel.setDismissAction(dismiss)
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
    }
}

/// Wraps content in a `NavigationStack` only when `embedsStack` is true.
/// Lets a view be presented standalone (its own stack) or pushed onto a
/// host's stack (no nested stack) from the same body.
private struct ConditionalNavigationStack<Content: View>: View {
    let embedsStack: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if embedsStack {
            NavigationStack { content() }
        } else {
            content()
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
    @Previewable @State var profileSettingsViewModel: ProfileSettingsViewModel = .shared
    @Previewable @State var presented: Bool = true
    VStack {
    }
    .sheet(isPresented: $presented) {
        NewConversationView(
            viewModel: viewModel,
            profileSettingsViewModel: profileSettingsViewModel
        )
    }
}
