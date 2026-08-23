import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

struct NewConversationView: View {
    let viewModel: NewConversationViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    /// When `true` (the default) the view wraps its content in its own
    /// `NavigationStack` -- the standalone sheet presentation. Pushed
    /// presentations set this `false` so the view lands on the host's stack
    /// (no nested `NavigationStack`). What happens to the back button then
    /// depends on `onClose`: the Compose flow passes one, which hides the
    /// back button (no returning to the picker) and routes the close (X)
    /// through the flow tear-down; pushes without `onClose` (the contact
    /// card's "Convos with you" rows) keep the system back button and show
    /// no X.
    var embedsNavigationStack: Bool = true
    /// Closes the entire Compose flow. Set when the view is pushed onto the
    /// picker's stack; when `nil` (standalone sheet) the close button
    /// dismisses via the environment `dismiss`.
    var onClose: (() -> Void)?
    /// Whether the conversation indicator should inset below the device's
    /// top safe area. Sheet presentations (every call site except the
    /// contact card's pushed conversation) keep the default `false` -- a
    /// sheet's top edge already sits below the status bar, so the indicator
    /// only needs its small fixed padding. A full-screen push extends under
    /// the status bar, so its entry point passes `true` to keep the
    /// indicator out of the status bar (mirrors the Chats tab's pushed
    /// conversation, which sets this on its own `ConversationPresenter`).
    var insetsTopSafeArea: Bool = false
    @State private var hasShownScannerOnAppear: Bool = false
    @State private var sidebarWidth: CGFloat = 0.0
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var navState: NewConversationNavigatorImpl = .init()
    @State private var navigator: NewConversationCollector?
    /// True while the conversation's Home tab has a page pushed. The
    /// conversation view puts its own back button in the leading slot then, so
    /// this view's close (X) stands down and the bar keeps one leading button
    /// that pops pages until the home is back at its root.
    @State private var isBrowsingHome: Bool = false

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = NewConversationCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private func handleConversationIdChanged(from oldId: String?, to newId: String?) {
        guard oldId == nil, let newId else { return }
        navigator?.navigateTo(conversation: ConversationNavigatorArgs(conversationId: newId))
    }

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel.conversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: insetsTopSafeArea,
            sidebarColumnWidth: $sidebarWidth,
            // The shell renders the centered indicator for pushed flows (see
            // `MainTabView.activeConvoVM`). Standalone sheets have no shell,
            // so their presenter owns the indicator.
            rendersConversationIndicator: embedsNavigationStack
        ) { focusBinding, coordinator in
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
                            focusState: focusBinding,
                            focusCoordinator: coordinator,
                            onScanInviteCode: viewModel.onScanInviteCode,
                            onDeleteConversation: viewModel.deleteConversation,
                            messagesTopBarTrailingItem: viewModel.messagesTopBarTrailingItem,
                            messagesTopBarTrailingItemEnabled: viewModel.messagesTopBarTrailingItemEnabled,
                            messagesTextFieldEnabled: viewModel.messagesTextFieldEnabled,
                            onScannedInviteCode: viewModel.handleScannedCode,
                            onInviteShared: viewModel.markInviteShared,
                            onHomeBrowsingChanged: { isBrowsingHome = $0 },
                            bottomBarContent: { EmptyView() }
                        )
                    } else {
                        EmptyView()
                    }
                }
                .toolbar {
                    // Standalone, the close (X) dismisses the sheet; pushed
                    // by the Compose flow, `onClose` tears the whole flow
                    // down (paired with the hidden back button below so the
                    // pushed view can't return to the picker). Pushed without
                    // `onClose`, the system back button is the way out, so no
                    // X is rendered. While the Home tab is browsing, the
                    // conversation's own back button owns the leading slot.
                    if !viewModel.showingFullScreenScanner && !isBrowsingHome && (embedsNavigationStack || onClose != nil) {
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
                // `isBrowsingHome` also hides it: while Context has browser
                // pages pushed, `ConversationView` puts its own pop-a-page
                // back button in the leading slot. That view's own
                // `navigationBarBackButtonHidden` can't win here - this
                // modifier is the outer one on the same destination - so
                // without the check both back buttons render side by side.
                .navigationBarBackButtonHidden((!embedsNavigationStack && onClose != nil) || isBrowsingHome)
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
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
        .onChange(of: viewModel.conversationViewModel?.conversation.id) { oldId, newId in
            handleConversationIdChanged(from: oldId, to: newId)
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
