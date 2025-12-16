import ConvosCore
import SwiftUI

struct ConversationsView: View {
    @State var viewModel: ConversationsViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel

    @Namespace private var namespace: Namespace.ID
    @State private var presentingAppSettings: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sidebarWidth: CGFloat = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var conversationPendingDeletion: Conversation?

    var focusCoordinator: FocusCoordinator {
        viewModel.focusCoordinator
    }

    var emptyConversationsViewScrollable: some View {
        ScrollView {
            LazyVStack(spacing: 0.0) {
                emptyConversationsView
            }
        }
    }

    var emptyConversationsView: some View {
        ConversationsListEmptyCTA(
            onStartConvo: viewModel.onStartConvo,
            onJoinConvo: viewModel.onJoinConvo
        )
    }

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel.selectedConversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
            sidebarColumnWidth: $sidebarWidth
        ) { focusState, coordinator in
            NavigationSplitView {
                Group {
                    if viewModel.unpinnedConversations.isEmpty && horizontalSizeClass == .compact {
                        emptyConversationsViewScrollable
                    } else {
                        List(viewModel.unpinnedConversations, id: \.id, selection: $viewModel.selectedConversationId) { conversation in
                            if viewModel.unpinnedConversations.first == conversation,
                               viewModel.unpinnedConversations.count == 1 && !viewModel.hasCreatedMoreThanOneConvo &&
                                horizontalSizeClass == .compact {
                                emptyConversationsView
                                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                    .listRowSeparator(.hidden)
                            }

                            ConversationsListItem(conversation: conversation)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        conversationPendingDeletion = conversation
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .tint(.colorCaution)
                                }
                                .confirmationDialog(
                                    "This convo will be deleted immediately.",
                                    isPresented: Binding(
                                        get: { conversationPendingDeletion?.id == conversation.id },
                                        set: { if !$0 { conversationPendingDeletion = nil } }
                                    ),
                                    titleVisibility: .visible
                                ) {
                                    Button("Delete", role: .destructive) {
                                        viewModel.leave(conversation: conversation)
                                        conversationPendingDeletion = nil
                                    }
                                    Button("Cancel", role: .cancel) {
                                        conversationPendingDeletion = nil
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                                        .fill(
                                            conversation.id == viewModel.selectedConversationId ||
                                            conversationPendingDeletion?.id == conversation.id
                                            ? .colorFillMinimal : .clear
                                        )
                                        .padding(.horizontal, DesignConstants.Spacing.step3x)
                                )
                                .listRowInsets(
                                    .init(
                                        top: 0,
                                        leading: 0,
                                        bottom: 0,
                                        trailing: 0
                                    )
                                )
                        }
                        .listStyle(.plain)
                    }
                }
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { newValue in
                    sidebarWidth = newValue.width
                }
                .background(.colorBackgroundPrimary)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConvosToolbarButton(padding: false) {
                            presentingAppSettings = true
                        }
                    }
                    .matchedTransitionSource(
                        id: "app-settings-transition-source",
                        in: namespace
                    )

                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Filter", systemImage: "line.3.horizontal.decrease") {
                            //
                        }
                        .disabled(true)
                    }
                    .matchedTransitionSource(
                        id: "filter-view-transition-source",
                        in: namespace
                    )

                    ToolbarItem(placement: .bottomBar) {
                        Spacer()
                    }

                    ToolbarItem(placement: .bottomBar) {
                        Button("Scan", systemImage: "viewfinder") {
                            viewModel.onJoinConvo()
                        }
                    }
                    .matchedTransitionSource(
                        id: "composer-transition-source",
                        in: namespace
                    )

                    ToolbarItem(placement: .bottomBar) {
                        Button("Compose", systemImage: "square.and.pencil") {
                            viewModel.onStartConvo()
                        }
                    }
                    .matchedTransitionSource(
                        id: "composer-transition-source",
                        in: namespace
                    )
                }
                .toolbar(removing: .sidebarToggle)
            } detail: {
                if let conversationViewModel = viewModel.selectedConversationViewModel {
                    ConversationView(
                        viewModel: conversationViewModel,
                        quicknameViewModel: quicknameViewModel,
                        focusState: focusState,
                        focusCoordinator: coordinator,
                        onScanInviteCode: {},
                        onDeleteConversation: {},
                        confirmDeletionBeforeDismissal: false,
                        messagesTopBarTrailingItem: .share,
                        messagesTopBarTrailingItemEnabled: true,
                        messagesTextFieldEnabled: true,
                        bottomBarContent: { EmptyView() }
                    )
                } else if horizontalSizeClass != .compact {
                    emptyConversationsViewScrollable
                } else {
                    EmptyView()
                }
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .sheet(isPresented: $presentingAppSettings) {
            AppSettingsView(
                viewModel: viewModel.appSettingsViewModel,
                quicknameViewModel: quicknameViewModel,
                onDeleteAllData: viewModel.deleteAllData
            )
            .navigationTransition(
                .zoom(
                    sourceID: "app-settings-transition-source",
                    in: namespace
                )
            )
            .interactiveDismissDisabled(viewModel.appSettingsViewModel.isDeleting)
        }
        .fullScreenCover(item: $viewModel.newConversationViewModel) { newConvoViewModel in
            NewConversationView(
                viewModel: newConvoViewModel,
                quicknameViewModel: quicknameViewModel,
                presentingFullScreen: true
            )
            .background(.colorBackgroundPrimary)
            .interactiveDismissDisabled()
            .navigationTransition(
                .zoom(
                    sourceID: "composer-transition-source",
                    in: namespace
                )
            )
        }
        .selfSizingSheet(isPresented: $viewModel.presentingExplodeInfo) {
            ExplodeInfoView()
                .background(.colorBackgroundRaised)
        }
        .selfSizingSheet(isPresented: $viewModel.presentingMaxNumberOfConvosReachedInfo) {
            MaxedOutInfoView(maxNumberOfConvos: viewModel.maxNumberOfConvos)
                .background(.colorBackgroundRaised)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                viewModel.handleURL(url)
            }
        }
        .onOpenURL { url in
            viewModel.handleURL(url)
        }
    }
}

#Preview {
    let convos = ConvosClient.mock()
    let viewModel = ConversationsViewModel(session: convos.session)
    let quicknameViewModel = QuicknameSettingsViewModel.shared
    ConversationsView(
        viewModel: viewModel,
        quicknameViewModel: quicknameViewModel
    )
}
