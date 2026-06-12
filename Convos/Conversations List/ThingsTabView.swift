import ConvosComposer
import ConvosCore
import SwiftUI

/// Cross-conversation "Things" tab. Renders a grid of the most
/// recent agent-sent HTML attachment from every conversation, with the
/// conversation's display name + unread dot under each preview square.
/// See [[ThingsOverviewViewModel]] for the data layer and
/// [[ThingPreviewCell]] for the cell.
///
/// Layout spec (from the design):
/// - 24pt outer horizontal margins
/// - 18pt between columns
/// - 12pt between rows (and 12pt top/bottom outer padding)
/// - 2 columns in compact width (iPhone); in regular width (iPad) the
///   column count grows with the available width, capped at 5, so cells
///   stay close to their iPhone size instead of stretching
///
/// Tapping a cell pushes the conversation detail onto this tab's own
/// `NavigationStack` (via `pushedConversations`), so the user stays on
/// the Things tab when they tap the back button. The path is bound up
/// to `MainTabView` so the bottom chrome can hide while a conversation
/// is pushed on either tab.
///
/// The tab is wrapped in `ConversationPresenter` so the same
/// app-indicator <-> conversation-indicator morph used on the Chats
/// tab plays here too. The presenter's `viewModel` is derived from
/// `pushedConversations.last`, so pushing a cell flips the indicator
/// from the leading app pill to the centered conversation pill, and
/// popping back flips it the other way.
struct ThingsTabView: View {
    let appIndicatorContext: AppIndicatorContext
    @Bindable var conversationsViewModel: ConversationsViewModel
    @Binding var pushedItems: [ThingOverviewItem]
    /// Fired on every scroll tick with the grid's current Y offset.
    /// `MainTabView` aggregates this with the Chats tab's offset to drive
    /// the builder bar's expand/collapse state.
    var onScrollOffsetChange: ((CGFloat) -> Void)?
    /// Invoked when the user taps "Explore agents in Contacts" in the empty
    /// state. The shell switches to the Contacts tab and scrolls it to the
    /// "Suggested agents" section. Nil hides the link (e.g. previews).
    var onSeeSuggestedAgents: (() -> Void)?
    @State private var viewModel: ThingsOverviewViewModel
    @State private var pushedConvoVM: ConversationViewModel?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var sidebarColumnWidth: CGFloat = 0
    @State private var gridWidth: CGFloat = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Namespace private var localNamespace: Namespace.ID

    init(
        appIndicatorContext: AppIndicatorContext,
        conversationsViewModel: ConversationsViewModel,
        pushedItems: Binding<[ThingOverviewItem]>,
        onScrollOffsetChange: ((CGFloat) -> Void)? = nil,
        onSeeSuggestedAgents: (() -> Void)? = nil
    ) {
        self.appIndicatorContext = appIndicatorContext
        self.conversationsViewModel = conversationsViewModel
        _pushedItems = pushedItems
        self.onScrollOffsetChange = onScrollOffsetChange
        self.onSeeSuggestedAgents = onSeeSuggestedAgents
        _viewModel = State(initialValue: ThingsOverviewViewModel(session: conversationsViewModel.session))
    }

    private var columns: [GridItem] {
        let column = GridItem(.flexible(), spacing: Constant.interColumnSpacing)
        return Array(repeating: column, count: columnCount)
    }

    /// 2 columns in compact width. In regular width (iPad), fit as many
    /// columns of at least `minRegularCellWidth` as the measured grid
    /// width allows, capped at `maxColumnCount`. Cells stay square via
    /// `ThingPreviewCell`'s aspect ratio regardless of column width.
    private var columnCount: Int {
        guard horizontalSizeClass == .regular, gridWidth > 0 else {
            return Constant.compactColumnCount
        }
        let available: CGFloat = max(0, gridWidth - 2 * Constant.outerHorizontalPadding)
        let cellPlusSpacing: CGFloat = Constant.minRegularCellWidth + Constant.interColumnSpacing
        let fitting = Int((available + Constant.interColumnSpacing) / cellPlusSpacing)
        return min(max(fitting, Constant.compactColumnCount), Constant.maxColumnCount)
    }

    var body: some View {
        content
            .navigationDestination(item: thingsPushedItemBinding) { item in
                ThingDetailView(item: item)
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

    /// Single-optional bridge from `pushedItems` (array used by parent
    /// shell to track "is something pushed?") to SwiftUI's
    /// `navigationDestination(item:)`. Push by appending; pop happens
    /// when SwiftUI sets the binding back to nil (back swipe / button).
    private var thingsPushedItemBinding: Binding<ThingOverviewItem?> {
        Binding(
            get: { pushedItems.last },
            set: { newValue in
                if let newValue {
                    if pushedItems.last?.id != newValue.id {
                        pushedItems.append(newValue)
                    }
                } else {
                    if !pushedItems.isEmpty {
                        pushedItems.removeLast()
                    }
                }
            }
        )
    }

    /// Keep `pushedConvoVM` in lockstep with the navigation stack so the
    /// outer `ConversationPresenter` can show the conversation indicator
    /// (centered) while a things item is pushed and the app indicator
    /// (leading) when popped back.
    private func syncPushedConvoVM(with path: [ThingOverviewItem]) {
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
                        ThingPreviewCell(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Constant.outerHorizontalPadding)
            .padding(.vertical, Constant.outerVerticalPadding)
        }
        .background(.colorBackgroundSurfaceless)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newValue in
            gridWidth = newValue
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newValue in
            onScrollOffsetChange?(newValue)
        }
    }

    /// New-user CTA shown while no conversation has produced things yet.
    /// Mirrors the chats-tab empty state's structure exactly (shared
    /// [[EmptyStateCTAView]] scaffold) so switching tabs never shifts the
    /// "Make an agent" button or the surrounding components.
    private var emptyState: some View {
        ThingsEmptyStateView(
            onMakeAgent: { conversationsViewModel.onStartAgent() },
            onExploreAgents: onSeeSuggestedAgents
        )
    }

    // Compose button now lives in `MainTabView.sharedTopBar`.

    private enum Constant {
        static let outerHorizontalPadding: CGFloat = 24.0
        static let outerVerticalPadding: CGFloat = 12.0
        static let interColumnSpacing: CGFloat = 18.0
        static let interRowSpacing: CGFloat = 12.0
        static let compactColumnCount: Int = 2
        static let maxColumnCount: Int = 5
        /// Roughly the cell width of the 2-column layout on an iPhone,
        /// so regular-width cells never render smaller than iPhone cells.
        static let minRegularCellWidth: CGFloat = 140.0
    }
}
