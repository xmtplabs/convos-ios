import ConvosCore
import SwiftUI

/// Cross-conversation "Stuff" tab. Renders a two-column grid of the most
/// recent agent-sent HTML attachment from every conversation, with the
/// conversation's display name + unread dot under each preview square.
/// See [[StuffOverviewViewModel]] for the data layer and
/// [[StuffPreviewCell]] for the cell.
///
/// Layout spec (from the design):
/// - 24pt outer horizontal margins
/// - 18pt between columns
/// - 12pt between rows (and 12pt top/bottom outer padding)
///
/// Tapping a cell pushes the conversation detail onto this tab's own
/// `NavigationStack` (via `pushedConversations`), so the user stays on
/// the Stuff tab when they tap the back button. The path is bound up
/// to `MainTabView` so the bottom chrome can hide while a conversation
/// is pushed on either tab.
///
/// The tab is wrapped in `ConversationPresenter` so the same
/// app-indicator <-> conversation-indicator morph used on the Chats
/// tab plays here too. The presenter's `viewModel` is derived from
/// `pushedConversations.last`, so pushing a cell flips the indicator
/// from the leading app pill to the centered conversation pill, and
/// popping back flips it the other way.
struct StuffTabView: View {
    let appIndicatorContext: AppIndicatorContext
    @Bindable var conversationsViewModel: ConversationsViewModel
    @Binding var pushedItems: [StuffOverviewItem]
    /// Fired on every scroll tick with the grid's current Y offset.
    /// `MainTabView` aggregates this with the Chats tab's offset to drive
    /// the builder bar's expand/collapse state.
    var onScrollOffsetChange: ((CGFloat) -> Void)?
    @State private var viewModel: StuffOverviewViewModel
    @State private var pushedConvoVM: ConversationViewModel?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var sidebarColumnWidth: CGFloat = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Namespace private var localNamespace: Namespace.ID

    init(
        appIndicatorContext: AppIndicatorContext,
        conversationsViewModel: ConversationsViewModel,
        pushedItems: Binding<[StuffOverviewItem]>,
        onScrollOffsetChange: ((CGFloat) -> Void)? = nil
    ) {
        self.appIndicatorContext = appIndicatorContext
        self.conversationsViewModel = conversationsViewModel
        _pushedItems = pushedItems
        self.onScrollOffsetChange = onScrollOffsetChange
        _viewModel = State(initialValue: StuffOverviewViewModel(session: conversationsViewModel.session))
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: Constant.interColumnSpacing),
            GridItem(.flexible(), spacing: Constant.interColumnSpacing),
        ]
    }

    var body: some View {
        ConversationPresenter(
            viewModel: pushedConvoVM,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
            sidebarColumnWidth: $sidebarColumnWidth,
            appIndicatorContext: appIndicatorContext
        ) { _, _ in
            NavigationStack(path: $pushedItems) {
                content
                    .toolbar { trailingToolbar }
                    .navigationDestination(for: StuffOverviewItem.self) { item in
                        StuffDetailView(item: item)
                    }
            }
        }
        .onChange(of: pushedItems) { _, newPath in
            syncPushedConvoVM(with: newPath)
        }
        .onAppear {
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
            syncPushedConvoVM(with: pushedItems)
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            focusCoordinator.horizontalSizeClass = newValue
        }
    }

    /// Keep `pushedConvoVM` in lockstep with the navigation stack so the
    /// outer `ConversationPresenter` can show the conversation indicator
    /// (centered) while a stuff item is pushed and the app indicator
    /// (leading) when popped back.
    private func syncPushedConvoVM(with path: [StuffOverviewItem]) {
        guard let item = path.last else {
            pushedConvoVM = nil
            return
        }
        guard pushedConvoVM?.conversation.id != item.conversation.id else { return }
        pushedConvoVM = ConversationViewModel.createSync(
            conversation: item.conversation,
            session: conversationsViewModel.session
        )
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Constant.interRowSpacing) {
                ForEach(viewModel.items) { item in
                    Button {
                        pushedItems.append(item)
                    } label: {
                        StuffPreviewCell(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Constant.outerHorizontalPadding)
            .padding(.vertical, Constant.outerVerticalPadding)
        }
        .background(.colorBackgroundSurfaceless)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newValue in
            onScrollOffsetChange?(newValue)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.colorTextSecondary)
            Text("When agents make stuff, it will show up here.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step8x)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.colorBackgroundSurfaceless)
    }

    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ComposeToolbarButton(
                viewModel: conversationsViewModel,
                transitionNamespace: appIndicatorContext.transitionNamespace,
                fallbackNamespace: localNamespace
            )
        }
    }

    private enum Constant {
        static let outerHorizontalPadding: CGFloat = 24.0
        static let outerVerticalPadding: CGFloat = 12.0
        static let interColumnSpacing: CGFloat = 18.0
        static let interRowSpacing: CGFloat = 12.0
    }
}
