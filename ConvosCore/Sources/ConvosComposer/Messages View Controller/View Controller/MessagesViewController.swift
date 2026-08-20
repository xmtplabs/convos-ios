#if canImport(UIKit)
import Combine
import ConvosCore
import DifferenceKit
import Foundation
import Observation
import SwiftUI
import UIKit

/// A gesture recognizer that fires immediately on touch without interfering with other gestures
private class ImmediateTouchGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        state = .recognized
    }
}

/// Controls how the messages list's leading "empty state" content is presented.
/// `.standard` shows either the invite QR (for the creator of an unlocked,
/// non-full conversation) or the `ConversationInfoPreview`. `.hidden`
/// suppresses the QR but still renders the "Invite members" affordance —
/// used by the Agent Builder so the underlying chat doesn't flash a QR
/// while the user is still drafting. `.suppressed` hides every leading
/// affordance (QR, invite chip, info preview) — used by read-only
/// surfaces where the user has no permission to add members.
public enum MessagesHeaderMode {
    case standard
    case hidden
    case suppressed
}

public final class MessagesViewController: UIViewController {
    struct MessagesState {
        let conversation: Conversation
        let messages: [MessagesListItemType]
        let invite: Invite
        let hasLoadedAllMessages: Bool
        let headerMode: MessagesHeaderMode
        /// Set by the Agent Builder commit path. When present, the cell
        /// builder filters out messages before `summary.cutoffDate` and
        /// prepends an `.agentBuilderSummary` cell.
        let agentBuilderSummary: AgentBuilderSummary?
        let agentBuilderTransitionNamespace: Namespace.ID?
        let htmlAttachmentTransitionNamespace: Namespace.ID?

        init(
            conversation: Conversation,
            messages: [MessagesListItemType],
            invite: Invite,
            hasLoadedAllMessages: Bool,
            headerMode: MessagesHeaderMode = .standard,
            agentBuilderSummary: AgentBuilderSummary? = nil,
            agentBuilderTransitionNamespace: Namespace.ID? = nil,
            htmlAttachmentTransitionNamespace: Namespace.ID? = nil
        ) {
            self.conversation = conversation
            self.messages = messages
            self.invite = invite
            self.hasLoadedAllMessages = hasLoadedAllMessages
            self.headerMode = headerMode
            self.agentBuilderSummary = agentBuilderSummary
            self.agentBuilderTransitionNamespace = agentBuilderTransitionNamespace
            self.htmlAttachmentTransitionNamespace = htmlAttachmentTransitionNamespace
        }
    }

    private enum ReactionTypes {
        case delayedUpdate
    }

    private enum InterfaceActions {
        case changingKeyboardFrame
        case changingContentInsets
        case changingFrameSize
        case sendingMessage
        case scrollingToTop
        case scrollingToBottom
        case updatingCollectionInIsolation
        case determiningBottomBarHeight
    }

    private enum ControllerActions {
        case loadingInitialMessages
        case loadingPreviousMessages
        case updatingCollection
    }

    // MARK: - Properties

    private var currentInterfaceActions: SetActor<Set<InterfaceActions>, ReactionTypes> = SetActor()
    private var currentControllerActions: SetActor<Set<ControllerActions>, ReactionTypes> = SetActor()

    internal let collectionView: UICollectionView
    private var messagesLayout: MessagesCollectionLayout = MessagesCollectionLayout()

    private let dataSource: MessagesCollectionDataSource

    private var animator: ManualAnimator?

    private var isUserInitiatedScrolling: Bool {
        collectionView.isDragging || collectionView.isDecelerating
    }

    private var isFirstStateUpdate: Bool = true
    private var hasPendingInterrupt: Bool = false
    /// True from init until the view has fully appeared (the open transition
    /// finished). While set, bar-height inset changes re-anchor instantly
    /// instead of animating - see `applyBottomInsetInstantly`.
    private var isSettlingInitialLayout: Bool = true
    private var previousLastMessageId: String?
    private var previousFocusState: MessagesViewInputFocus?
    private var pendingScrollToBottomAfterKeyboard: Bool = false

    /// Whether the user is near the bottom of the scroll view (within one screen height)
    private var isNearBottom: Bool {
        distanceFromBottom <= collectionView.frame.height
    }

    private var distanceFromBottom: CGFloat {
        let contentHeight = collectionView.contentSize.height
        let scrollViewHeight = collectionView.frame.height
        let currentOffset = collectionView.contentOffset.y
        let bottomInset = collectionView.adjustedContentInset.bottom
        return contentHeight - (currentOffset + scrollViewHeight - bottomInset)
    }

    /// Whether the list sat at the very bottom the last time the content
    /// offset changed. Unlike a live distance check, this is not fooled by
    /// in-place content growth at the bottom (which changes the content size
    /// but not the offset), so it answers "was the user pinned before this
    /// update?" -- the gate for the re-pin scroll that reveals such growth.
    /// Scrolling up flips it false via `scrollViewDidScroll`; programmatic
    /// scrolls to the bottom flip it back.
    private var isPinnedToBottom: Bool = true

    // MARK: - Public

    var state: MessagesState? {
        didSet {
            guard let state = state else {
                processUpdates(
                    for: .empty(),
                    with: [],
                    invite: .empty,
                    hasLoadedAllMessages: false,
                    animated: true,
                    requiresIsolatedProcess: false) {}
                return
            }

            let animated = oldValue?.conversation.id == state.conversation.id
            dataSource.conversationId = state.conversation.id
            headerMode = state.headerMode
            agentBuilderSummary = state.agentBuilderSummary
            agentBuilderTransitionNamespace = state.agentBuilderTransitionNamespace
            htmlAttachmentTransitionNamespace = state.htmlAttachmentTransitionNamespace
            processUpdates(
                for: state.conversation,
                with: state.messages,
                invite: state.invite,
                hasLoadedAllMessages: state.hasLoadedAllMessages,
                animated: animated,
                requiresIsolatedProcess: true) { [currentControllerActions] in
                    let currentLastMessageId = state.messages.lastMessageId
                    let isNewMessage = currentLastMessageId != self.previousLastMessageId
                    self.previousLastMessageId = currentLastMessageId

                    // Apply any pending deferred inset before reading
                    // inset-dependent scroll heuristics below (`isNearBottom`)
                    // or anchoring; this completion runs via the main queue,
                    // never re-entrantly inside a UIKit layout pass.
                    self.flushPendingBottomBarInsetUpdate()
                    let isInitialLoad = currentControllerActions.options.contains(.loadingInitialMessages)
                    let nearBottom = self.isNearBottom
                    let userScrolling = self.isUserInitiatedScrolling
                    if isInitialLoad {
                        currentControllerActions.options.remove(.loadingInitialMessages)
                        self.collectionView.layoutIfNeeded()
                        self.scrollToBottom(animated: false)
                        self.startObservingFocus()
                    } else if isNewMessage {
                        if let lastGroup = state.messages.last, lastGroup.isMessagesGroupSentByCurrentUser {
                            self.scrollToBottom()
                        } else if nearBottom && !userScrolling {
                            self.scrollToBottom()
                        }
                    } else if self.isPinnedToBottom && !userScrolling {
                        // Re-pin after in-place growth at the bottom (e.g. a
                        // message appending to the last group or a reaction
                        // landing on it). The growth renders below the fold
                        // unanimated (see MessagesGroupView's animatedGroup
                        // mirror); this scroll reveals it. Gated on the
                        // pinned flag, not a live distance check, so a user
                        // who scrolled up to read is never pulled back down
                        // by receipts, reactions, or typing changes. No-ops
                        // when the list is already at the bottom.
                        self.scrollToBottom()
                    }
                }
            isFirstStateUpdate = false
        }
    }

    var bottomBarHeight: CGFloat = 0.0 {
        didSet {
            if bottomBarHeight != oldValue {
                scheduleBottomBarInsetUpdate()
            }

            if bottomBarHeight > 0.0 {
                currentInterfaceActions.options.remove(.determiningBottomBarHeight)
            }
        }
    }

    /// `bottomBarHeight` is only written from `updateUIViewController`, which can run
    /// synchronously inside an in-flight UIKit layout pass (e.g. a sheet's keyboard
    /// relayout in `UISheetPresentationController`, which wraps it in
    /// `performWithoutAnimation`). Animating inset changes and forcing collection view
    /// layout re-entrantly from there crashes in UIKit's
    /// `_updateLayoutAttributesForExistingVisibleViewsFadingForBoundsChange:` assertion,
    /// because `restoreContentOffset` suppresses layout attributes while the collection
    /// view is mid bounds change. In that scope (animations disabled) the update is
    /// deferred to the next run loop tick; rapid changes coalesce into one update.
    /// Everywhere else the update applies synchronously - see
    /// `scheduleBottomBarInsetUpdate`.
    ///
    /// Bottom-anchored positioning that runs while a deferred update is pending must
    /// not compute against the stale inset; `flushPendingBottomBarInsetUpdate` applies
    /// it first via the non-animated direct path.
    private var hasPendingBottomBarInsetUpdate: Bool = false
    private var pendingContextMenuInsetFallback: DispatchWorkItem?
    private var pendingComposerSettleFallback: DispatchWorkItem?
    private var pendingComposerBottomInset: CGFloat?

    private func scheduleBottomBarInsetUpdate() {
        // While the open transition is settling, the bar's measurement often
        // arrives inside a `performWithoutAnimation` scope (SwiftUI updating
        // the representable mid-transition), which the deferral branch below
        // would postpone by a runloop tick - long enough for the list to
        // paint anchored against the stale inset and then visibly snap when
        // the initial load's completion flushes (the conversation-open
        // flicker). Apply synchronously instead: the settling path routes to
        // `applyBottomInsetInstantly`, which is plain property assignments
        // and safe inside an in-flight layout pass.
        if isSettlingInitialLayout {
            hasPendingBottomBarInsetUpdate = false
            updateBottomInsetForBottomBarHeight()
            return
        }
        // The deferral below exists only for the crash scenario above, whose
        // necessary ingredient is an enclosing `performWithoutAnimation`
        // scope (the inset change becomes a non-animated bounds change and
        // UIKit takes the fade-for-bounds-change path). When animations are
        // enabled we are not in that scope, so the inset applies
        // synchronously - keeping bottom-anchored positioning atomic with
        // the height change that triggered it. Deferring in that case made
        // the conversation-open layout re-anchor once per runloop tick as
        // the bottom bar measured, which read as a scroll flicker.
        if UIView.areAnimationsEnabled {
            hasPendingBottomBarInsetUpdate = false
            updateBottomInsetForBottomBarHeight()
            return
        }
        guard !hasPendingBottomBarInsetUpdate else { return }
        hasPendingBottomBarInsetUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingBottomBarInsetUpdate = false
            self.updateBottomInsetForBottomBarHeight()
        }
    }

    /// Synchronously applies a deferred bottom-bar inset update, if one is
    /// pending, using the same non-animated direct path as
    /// `applyDeferredBottomInset` (no animated bounds change, no forced
    /// collection view layout, so it stays safe inside an in-flight UIKit
    /// layout pass).
    ///
    /// Bottom-anchored positioning (the initial load's restore-to-bottom and
    /// `scrollToBottom`) reads `adjustedContentInset.bottom` at computation
    /// time. With the inset application deferred a runloop tick, those
    /// computations would otherwise use a stale inset and land the list short
    /// of the real bottom, then visibly re-anchor once per tick as the
    /// deferred updates apply - the "conversation opens slightly scrolled up,
    /// then jumps" flicker. Flushing first keeps every paint self-consistent.
    private func flushPendingBottomBarInsetUpdate() {
        guard hasPendingBottomBarInsetUpdate else { return }
        hasPendingBottomBarInsetUpdate = false
        applyDeferredBottomInset()
    }

    /// Silently applies the current bar-height inset target, preserving the
    /// content offset. Plain property assignments only, so it stays safe
    /// inside an in-flight UIKit layout pass. A shrink while pinned to the
    /// bottom (outside the open transition) is converted into the
    /// composer-collapse deferral instead: applying it here would leave the
    /// offset past the new maximum and UIKit would clamp it down in a hard
    /// jump; the deferral applies it clamp-free once the content has grown.
    private func applyDeferredBottomInset() {
        let targetInset: CGFloat
        // The keyboard math below measures how far the keyboard overlaps this
        // list, which presumes the list owns the screen. A host that renders no
        // bar of its own - the conversation sheet - positions its chrome
        // against the keyboard itself and rises with it, so the keyboard never
        // overlaps the list and the clearance it was handed is already the
        // whole answer.
        if let lastKeyboardFrameChange, hasBottomBar {
            targetInset = calculateNewBottomInset(for: lastKeyboardFrameChange)
        } else {
            targetInset = bottomBarHeight
        }
        guard abs(collectionView.contentInset.bottom - targetInset) > 0.5 else { return }
        if targetInset < collectionView.contentInset.bottom, isPinnedToBottom, !isSettlingInitialLayout {
            deferBottomInset(to: targetInset)
            return
        }
        let offset = collectionView.contentOffset
        UIView.performWithoutAnimation {
            collectionView.contentInset.bottom = targetInset
            collectionView.verticalScrollIndicatorInsets.bottom = targetInset
            collectionView.contentOffset = offset
        }
    }

    /// Hosts that don't render a bottom bar (e.g. the thinking detail sheet)
    /// set this to false so the controller doesn't sit on its initial state
    /// update waiting for a `bottomBarHeight > 0` that will never arrive.
    /// The chat path leaves it true and clears the gate via `bottomBarHeight`
    /// once the composer measures.
    var hasBottomBar: Bool = true {
        didSet {
            if !hasBottomBar {
                currentInterfaceActions.options.remove(.determiningBottomBarHeight)
            }
            guard isViewLoaded else { return }
            applyContentInsetAdjustmentBehavior()
        }
    }

    /// Extra top inset (in points) added to the controller's safe area, used
    /// when the host floats a bar over the collection view rather than
    /// installing it through `safeAreaBar(edge: .top)`. The collection view's
    /// `contentInsetAdjustmentBehavior = .always` picks the value up via
    /// `view.safeAreaInsets.top`, so newest-message bottom anchoring lands
    /// below the floating bar while the collection view itself still spans
    /// the full host (older content scrolls under the bar visually without
    /// being clipped). Default 0 preserves the chat path, which floats its
    /// top pill via the parent ConversationPresenter and relies on a leading
    /// `.invite` / `.conversationInfo` cell to occupy the area behind it.
    var topContentInset: CGFloat = 0.0 {
        didSet {
            guard topContentInset != oldValue else { return }
            additionalSafeAreaInsets.top = topContentInset
        }
    }

    /// How much of this view's top the host clips away, for a host that hands
    /// the list a taller frame than it shows: the conversation sheet holds the
    /// transcript at one height and reveals more of it as the sheet grows, so a
    /// detent change never resizes the list.
    ///
    /// Applied as a top content inset, which puts the content where it would sit
    /// if the frame really were the visible height - a short conversation starts
    /// at the visible top edge rather than up in the clipped region, scrolling up
    /// stops there rather than dragging content into it, and the scroll indicator
    /// stays inside the part the reader can see.
    ///
    /// Safe to track continuously through a drag: a top inset does not shift
    /// `contentOffset`, so a list pinned to its newest message stays pinned while
    /// this moves. It goes straight onto the collection view rather than through
    /// `additionalSafeAreaInsets` like `topContentInset`, because the hosts that
    /// set it run `contentInsetAdjustmentBehavior == .never` and would never see
    /// a safe-area change.
    var clippedTopOverflow: CGFloat = 0.0 {
        didSet {
            guard clippedTopOverflow != oldValue, isViewLoaded else { return }
            applyClippedTopOverflow()
        }
    }

    /// Fired with the transcript's content height whenever it changes. See
    /// `reportContentHeightIfChanged`.
    var onContentHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedContentHeight: CGFloat?

    private var lastKeyboardFrameChange: KeyboardInfo?

    var onUserInteraction: (() -> Void)?

    var focusCoordinator: FocusCoordinator? {
        didSet {
            guard focusCoordinator != nil, oldValue == nil else { return }
            if !isFirstStateUpdate {
                startObservingFocus()
            }
        }
    }

    /// Call this when user taps send to immediately scroll to bottom before message appears
    /// `animated: false` is for a host resetting the list while it is not being
    /// looked at - the conversation sheet parking a transcript it has collapsed
    /// over - where an animated scroll would be visible motion for no reason.
    func scrollToBottomForSend(animated: Bool = true) {
        scrollToBottom(animated: animated)
    }

    // MARK: - Initialization

    init() {
        self.dataSource = MessagesCollectionViewDataSource()
        self.collectionView = MessagesCollectionView(
            frame: .zero,
            collectionViewLayout: messagesLayout
        )
        currentControllerActions.options.insert(.loadingInitialMessages)
        currentInterfaceActions.options.insert(.determiningBottomBarHeight)
        super.init(nibName: nil, bundle: nil)
    }

    var onTapInvite: ((MessageInvite) -> Void)?
    var onTapAgentShare: ((MessageAgentShare) -> Void)?
    var agentShareResolver: any AgentShareResolving = MockAgentShareResolver() {
        didSet { dataSource.agentShareResolver = agentShareResolver }
    }
    var inviteMembershipResolver: any InviteMembershipResolving = NoopInviteMembershipResolver() {
        didSet { dataSource.inviteMembershipResolver = inviteMembershipResolver }
    }
    var onTapAvatar: ((ConversationMember) -> Void)?
    var onLoadPreviousMessages: (() -> Void)?
    var onReaction: ((String, String) -> Void)?
    var onToggleReaction: ((String, String) -> Void)?
    var onTapReactions: ((AnyMessage) -> Void)?
    var onTapReadReceipts: ((MessagesGroup) -> Void)?
    var onTapThinkingIndicator: ((ThinkingSessionDescriptor) -> Void)?
    var onReply: ((AnyMessage) -> Void)?
    /// When nil, the data source forwards nil into `CellConfig` so the bubble's
    /// "Read more" detail button is suppressed (nil-handler => no button). The
    /// `didSet` re-applies that mapping whenever the host wires or clears the
    /// handler, after the data source has been created during setup.
    var onOpenMessageDetail: ((AnyMessage) -> Void)? {
        didSet { applyOpenMessageDetailToDataSource() }
    }
    var onToggleMessageExpanded: ((String) -> Void)?
    /// Message ids whose long-body inline expansion is on. Owned by the VM and
    /// pushed in each render so expansion survives cell reuse; forwarded to the
    /// data source so reconfigured cells read the current set.
    var expandedMessageIds: Set<String> = [] {
        didSet {
            guard expandedMessageIds != oldValue else { return }
            dataSource.expandedMessageIds = expandedMessageIds
            // A change to the set alone produces no DifferenceKit changeset
            // (the messages are identical), so the visible cell would not
            // re-render. Reconfigure the cells whose expansion flipped so the
            // hosted SwiftUI bubble rebuilds from the updated config.
            reconfigureCells(forMessageIds: expandedMessageIds.symmetricDifference(oldValue))
        }
    }
    var contextMenuState: MessageContextMenuState = .init() {
        didSet { dataSource.contextMenuState = contextMenuState }
    }

    var messageAgentReceiptStore: MessageAgentReceiptStore = .init() {
        didSet { dataSource.messageAgentReceiptStore = messageAgentReceiptStore }
    }

    var onPhotoDimensionsLoaded: ((String, Int, Int) -> Void)?
    var onAgentOutOfCredits: (() -> Void)?
    /// Drives the in-stream "lost power" cell. Set from
    /// `MessagesViewRepresentable` off
    /// `ConversationViewModel.agentPowerDepletedByInboxId` — the backend's
    /// OWNER-computed per-agent power signal, keyed by agent inboxId. The
    /// viewer's own wallet is never an input; an agent missing from the map
    /// is unknown and renders nothing. When this changes while a
    /// state is already applied, we replay the last processed state so the
    /// cell appears / disappears without needing the messages publisher to
    /// emit again.
    var agentPowerDepletedByInboxId: [String: Bool] = [:] {
        didSet {
            dataSource.agentPowerDepletedByInboxId = agentPowerDepletedByInboxId
            guard oldValue != agentPowerDepletedByInboxId, isViewLoaded, let state else { return }
            // The sender-label bolt lives inside `.messages` cells whose items
            // don't change when the map flips, so the state replay below
            // carries no DifferenceKit changeset for them — an already-visible
            // group would keep rendering the stale bolt until cell reuse.
            // Reconfigure the groups sent by the agents whose signal changed
            // before replaying (the replay only inserts/removes the standalone
            // lost-power cells).
            let changedInboxIds: Set<String> = Set(oldValue.keys)
                .union(agentPowerDepletedByInboxId.keys)
                .filter { oldValue[$0] != agentPowerDepletedByInboxId[$0] }
            reconfigureCells(forSenderInboxIds: changedInboxIds)
            self.state = state
        }
    }
    var agentBuilderSummaryProvider: ((AgentBuilderCardContent) -> AnyView)? {
        didSet { dataSource.agentBuilderSummaryProvider = agentBuilderSummaryProvider }
    }
    var currentUserProfileImage: (() -> UIImage?)? {
        didSet { dataSource.currentUserProfileImage = currentUserProfileImage }
    }
    var backwardsSecrecyInfoSheet: (() -> AnyView)? {
        didSet { dataSource.backwardsSecrecyInfoSheet = backwardsSecrecyInfoSheet }
    }
    var onTapUpdateMember: ((ConversationMember) -> Void)?
    var onTapCapabilityConnect: ((CapabilityConnectPrompt) -> Void)?
    var onRetryMessage: ((AnyMessage) -> Void)?
    var onDeleteMessage: ((AnyMessage) -> Void)?
    var onRetryAgentJoin: (() -> Void)?
    var onInviteAgent: (() -> Void)?
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?
    var profileSheetForMember: ((ConversationMember) -> AnyView)?
    var memberContactOverride: ((String) -> Contact?)?

    var headerMode: MessagesHeaderMode = .standard {
        didSet { dataSource.headerMode = headerMode }
    }

    var agentBuilderSummary: AgentBuilderSummary?
    var agentBuilderTransitionNamespace: Namespace.ID? {
        didSet { dataSource.agentBuilderTransitionNamespace = agentBuilderTransitionNamespace }
    }
    var htmlAttachmentTransitionNamespace: Namespace.ID? {
        didSet { dataSource.htmlAttachmentTransitionNamespace = htmlAttachmentTransitionNamespace }
    }
    /// Called with the loaded HTML file URL when the user taps an HTML
    /// bubble. SwiftUI subscribes (via `MessagesViewRepresentable`) so it
    /// can drive the post-tap attachment preview presentation with
    /// a matched-geometry zoom transition. When `nil`, falls back to the
    /// plain file preview path below.
    var onPresentHTMLAttachmentPreview: ((HydratedAttachment, URL, ConversationMember, Date) -> Void)?
    /// Called with the loaded file URL when the user taps a non-HTML file
    /// bubble. The host supplies the presentation (the app shows its
    /// attachment preview sheet); when nil, tapping a file does nothing.
    var onPresentFileAttachmentPreview: ((HydratedAttachment, URL, ConversationMember, Date) -> Void)?

    var isAgentJoinPending: Bool = false {
        didSet { dataSource.isAgentJoinPending = isAgentJoinPending }
    }

    private var currentReactionMessageId: String?
    private var reactionCancellable: AnyCancellable?

    deinit {
        KeyboardListener.shared.remove(delegate: self)
    }

    @available(*, unavailable, message: "Use init(messageController:) instead")
    override convenience init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        fatalError()
    }

    @available(*, unavailable, message: "Use init(messageController:) instead")
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Reconfigures the visible message cells that contain any of the given
    /// message ids. Used when the long-body expansion set flips, since that
    /// change carries no DifferenceKit changeset on its own.
    /// Forwards the host's optional detail handler to the data source, keeping
    /// it nil when the host wired none so the bubble's "Read more" detail button
    /// is suppressed. Called at setup and from `onOpenMessageDetail.didSet`, so
    /// it stays correct regardless of whether the host sets the handler before
    /// or after the data source is created.
    private func applyOpenMessageDetailToDataSource() {
        dataSource.onOpenMessageDetail = onOpenMessageDetail.map { _ in
            { [weak self] message in self?.onOpenMessageDetail?(message) }
        }
    }

    private func reconfigureCells(forMessageIds messageIds: Set<String>) {
        guard !messageIds.isEmpty else { return }
        var indexPaths: [IndexPath] = []
        for (sectionIndex, section) in dataSource.sections.enumerated() {
            for (itemIndex, cell) in section.cells.enumerated() {
                guard case .messages(let group) = cell else { continue }
                let groupContainsChangedId = group.messages.contains { message in
                    messageIds.contains(message.messageId)
                }
                if groupContainsChangedId {
                    indexPaths.append(IndexPath(item: itemIndex, section: sectionIndex))
                }
            }
        }
        guard !indexPaths.isEmpty else { return }
        collectionView.reconfigureItems(at: indexPaths)
        // The custom layout only builds `.itemReconfigure` height-diff items
        // from cells stashed by its own `reconfigureItems`, so pair the
        // collection-view call with the layout call (matching the DifferenceKit
        // reconfigure path) or the cell height is not re-measured when a long
        // message expands or collapses.
        messagesLayout.reconfigureItems(at: indexPaths)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        setupCollectionView()
        setupUI()
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        handleViewTransition(to: size, with: coordinator)
        super.viewWillTransition(to: size, with: coordinator)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isSettlingInitialLayout = false
        messagesLayout.compensatesAllSelfSizingGrowth = false
    }

    /// `clippedTopOverflow` can be handed over before this view has loaded, where
    /// its own setter cannot apply it. Re-asserting each pass closes that gap and
    /// costs nothing: it returns immediately once the inset already matches.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyClippedTopOverflow()
    }

    /// The SwiftUI bottom bar mounts into the safe area a render pass or two
    /// after the list's first bottom anchor during the open transition, which
    /// silently grows `adjustedContentInset.bottom` without re-anchoring -
    /// the list paints short of the bottom until something else scrolls it.
    /// Re-anchor arithmetically while settling; `scrollToBottom(animated:
    /// false)` is plain property assignments, safe mid-layout.
    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard isSettlingInitialLayout, isViewLoaded, !isUserInitiatedScrolling else { return }
        scrollToBottom(animated: false)
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Drop the flag so an interrupted keyboard transition doesn't surface a
        // stale scroll-to-bottom on the next appearance.
        pendingScrollToBottomAfterKeyboard = false
    }

    // MARK: - Private Setup Methods

    private func setupUI() {
        view.backgroundColor = .clear
        KeyboardListener.shared.add(delegate: self)
    }

    private func startObservingFocus() {
        guard let coordinator = focusCoordinator else { return }

        withObservationTracking {
            _ = coordinator.currentFocus
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleFocusChange()
            }
        }
    }

    private func handleFocusChange() {
        guard let coordinator = focusCoordinator else { return }

        let oldFocus = previousFocusState
        let newFocus = coordinator.currentFocus
        previousFocusState = newFocus

        if oldFocus == nil && newFocus == .message {
            scrollToBottom()
        }

        startObservingFocus()
    }

    /// Called from MessagesView via the representable when SwiftUI's @FocusState
    /// transitions into the composer. The synchronous scrollToBottom typically no-ops
    /// because the keyboard hasn't yet expanded the bottom inset; setting the pending
    /// flag lets keyboardDidChangeFrame re-anchor once the keyboard frame settles.
    func messageInputDidBecomeFocused() {
        pendingScrollToBottomAfterKeyboard = true
        scrollToBottom()
    }

    private func setupCollectionView() {
        collectionView.frame = view.bounds
        configureMessagesLayout()
        setupCollectionViewInstance()
        configureCollectionViewConstraints()
        configureCollectionViewBehavior()
    }

    private func configureMessagesLayout() {
        messagesLayout.settings.interItemSpacing = 0.0
        messagesLayout.settings.interSectionSpacing = 0.0
        messagesLayout.settings.additionalInsets = UIEdgeInsets(
            top: 0.0,
            left: 0.0,
            bottom: 0.0,
            right: 0.0
        )
        messagesLayout.keepContentOffsetAtBottomOnBatchUpdates = true
        messagesLayout.processOnlyVisibleItemsOnAnimatedBatchUpdates = true
        // Covers bottom growth that never produces a state update (e.g. an
        // attachment finishing its async load while the list sits at the
        // bottom); state-driven growth is re-pinned by the state-update
        // completion, and scrollToBottom no-ops if that already ran.
        messagesLayout.onOutOfBandBottomGrowth = { [weak self] in
            guard let self,
                  isPinnedToBottom,
                  !isUserInitiatedScrolling,
                  !currentControllerActions.options.contains(.loadingInitialMessages),
                  // Growth from a state update is revealed by that update's
                  // completion; scrolling here too would restart it mid-flight.
                  !currentControllerActions.options.contains(.updatingCollection) else { return }
            scrollToBottom()
        }
    }

    private func setupCollectionViewInstance() {
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
    }

    private func configureCollectionViewConstraints() {
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureCollectionViewBehavior() {
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = dataSource
        collectionView.delegate = self
        (collectionView as? MessagesCollectionView)?.onDidLayoutSubviews = { [weak self] in
            self?.reportContentHeightIfChanged()
        }
        messagesLayout.delegate = dataSource
        collectionView.keyboardDismissMode = .interactive

        collectionView.contentInset = .init(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
        collectionView.scrollIndicatorInsets = collectionView.contentInset
        applyContentInsetAdjustmentBehavior()
        collectionView.automaticallyAdjustsScrollIndicatorInsets = true
        collectionView.selfSizingInvalidation = .enabled
        messagesLayout.supportSelfSizingInvalidation = true

        dataSource.prepare(with: collectionView)

        dataSource.onTapAvatar = { [weak self] sender in
            self?.onTapAvatar?(sender)
        }
        dataSource.onTapInvite = { [weak self] invite in
            guard let self = self else { return }
            self.onTapInvite?(invite)
        }
        dataSource.agentShareResolver = agentShareResolver
        dataSource.inviteMembershipResolver = inviteMembershipResolver
        dataSource.onTapAgentShare = { [weak self] agentShare in
            guard let self = self else { return }
            self.onTapAgentShare?(agentShare)
        }
        dataSource.onTapReactions = { [weak self] message in
            guard let self = self else { return }
            self.onTapReactions?(message)
        }
        dataSource.onTapReadReceipts = { [weak self] group in
            guard let self = self else { return }
            self.onTapReadReceipts?(group)
        }
        dataSource.onTapThinkingIndicator = { [weak self] descriptor in
            guard let self = self else { return }
            self.onTapThinkingIndicator?(descriptor)
        }
        dataSource.onReaction = { [weak self] emoji, messageId in
            guard let self = self else { return }
            self.onReaction?(emoji, messageId)
        }
        dataSource.onToggleReaction = { [weak self] emoji, messageId in
            guard let self = self else { return }
            self.onToggleReaction?(emoji, messageId)
        }
        dataSource.onReply = { [weak self] message in
            guard let self = self else { return }
            self.onReply?(message)
        }
        applyOpenMessageDetailToDataSource()
        dataSource.onToggleMessageExpanded = { [weak self] messageId in
            self?.onToggleMessageExpanded?(messageId)
        }
        dataSource.onPhotoDimensionsLoaded = { [weak self] attachmentKey, width, height in
            self?.onPhotoDimensionsLoaded?(attachmentKey, width, height)
        }
        dataSource.onAgentOutOfCredits = { [weak self] in
            self?.onAgentOutOfCredits?()
        }
        dataSource.onTapUpdateMember = { [weak self] member in
            self?.onTapUpdateMember?(member)
        }
        dataSource.onTapCapabilityConnect = { [weak self] prompt in
            self?.onTapCapabilityConnect?(prompt)
        }
        dataSource.onOpenFile = { [weak self] attachment, message in
            self?.openFileAttachment(attachment, from: message)
        }
        dataSource.onRetryMessage = { [weak self] message in
            self?.onRetryMessage?(message)
        }
        dataSource.onDeleteMessage = { [weak self] message in
            self?.onDeleteMessage?(message)
        }
        dataSource.onRetryAgentJoin = { [weak self] in
            self?.onRetryAgentJoin?()
        }
        dataSource.onInviteAgent = { [weak self] in
            self?.onInviteAgent?()
        }
        dataSource.onRetryTranscript = { [weak self] item in
            self?.onRetryTranscript?(item)
        }
        dataSource.memberContactOverride = { [weak self] inboxId in
            self?.memberContactOverride?(inboxId)
        }

        setupImmediateTouchGesture()
    }

    private func setupImmediateTouchGesture() {
        let gesture = ImmediateTouchGestureRecognizer(target: self, action: #selector(handleImmediateTouch))
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        collectionView.addGestureRecognizer(gesture)
    }

    @objc private func handleImmediateTouch(_ gesture: UIGestureRecognizer) {
        onUserInteraction?()
    }

    private func handleViewTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        guard isViewLoaded else { return }

        currentInterfaceActions.options.insert(.changingFrameSize)
        let positionSnapshot = messagesLayout.getContentOffsetSnapshot(from: .bottom)
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.setNeedsLayout()

        coordinator.animate(alongsideTransition: { _ in
            self.collectionView.performBatchUpdates(nil)
        }, completion: { _ in
            if let positionSnapshot,
               !self.isUserInitiatedScrolling {
                self.messagesLayout.restoreContentOffset(with: positionSnapshot)
            }
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.currentInterfaceActions.options.remove(.changingFrameSize)
        })
    }

    // MARK: - Scrolling Methods

    private func loadPreviousMessages() {
        guard let onLoadPreviousMessages = onLoadPreviousMessages else { return }
        // Don't set the loading flag if there are no more messages to load —
        // the repository will no-op and we'd never clear the flag.
        guard state?.hasLoadedAllMessages == false else { return }
        currentControllerActions.options.insert(.loadingPreviousMessages)
        onLoadPreviousMessages()
    }

    /// `adjustedContentInset.bottom`, except while the open transition is
    /// settling: the SwiftUI bottom bar transiently registers in the safe
    /// area on top of the contentInset mirror of the same bar, and anchoring
    /// against that double-counted inset over-pins the list, which then
    /// steps back down in a visible snap when the duplicate resolves. Cap
    /// the anchor at the settled target (bar inset + window safe area).
    private var bottomAnchorInset: CGFloat {
        let adjusted = collectionView.adjustedContentInset.bottom
        guard isSettlingInitialLayout, let window = view.window else { return adjusted }
        let settledMax = collectionView.contentInset.bottom + window.safeAreaInsets.bottom
        return min(adjusted, settledMax)
    }

    func scrollToBottom(animated: Bool = true, completion: (() -> Void)? = nil) {
        // Deferred insets must land first so the bottom target below
        // reflects the final bar height.
        flushPendingBottomBarInsetUpdate()
        flushPendingComposerInset()

        // Clamped to the lowest offset the scroll view will hold, not floored at
        // zero. Zero is only the lowest when nothing is inset off the top, and a
        // host that hands this list a frame taller than it shows - the conversation
        // sheet, which clips it and insets by the clipped part - breaks that: for
        // any transcript shorter than the frame the arithmetic lands well below
        // zero. A `> 0` guard read that as "already at the bottom" and returned
        // without scrolling, so sending a message never moved the list.
        let lowestOffset: CGFloat = -collectionView.adjustedContentInset.top
        let contentOffsetAtBottom = CGPoint(
            x: collectionView.contentOffset.x,
            y: max(
                messagesLayout.collectionViewContentSize.height
                    - collectionView.frame.height
                    + bottomAnchorInset,
                lowestOffset
            )
        )

        // Exit before cancelling in-flight animations: when the layout's
        // animated bottom-pinning compensation is already scrolling to the
        // bottom, the model offset is at the target and this call must not
        // stamp the presentation mid-flight (which would snap the scroll).
        guard abs(contentOffsetAtBottom.y - collectionView.contentOffset.y) > 0.5 else {
            completion?()
            return
        }

        collectionView.setContentOffset(collectionView.contentOffset, animated: false)

        if !animated {
            // Plain assignment would inherit an enclosing animated context -
            // during the open transition this method runs from
            // viewSafeAreaInsetsDidChange inside the push's animation scope,
            // and an implicitly animated offset change makes the whole list
            // ride the bottom bar's entrance for the length of the push
            // spring instead of anchoring instantly.
            UIView.performWithoutAnimation {
                collectionView.contentOffset = contentOffsetAtBottom
            }
            completion?()
            return
        }

        performScrollToBottom(from: contentOffsetAtBottom,
                              initialOffset: collectionView.contentOffset.y,
                              completion: completion)
    }

    private func performScrollToBottom(from contentOffsetAtBottom: CGPoint,
                                       initialOffset: CGFloat,
                                       completion: (() -> Void)?) {
        let delta: CGFloat = contentOffsetAtBottom.y - initialOffset

        if abs(delta) > messagesLayout.visibleBounds.height {
            performLongScrollToBottom(initialOffset: initialOffset, delta: delta, completion: completion)
        } else {
            performShortScrollToBottom(to: contentOffsetAtBottom, completion: completion)
        }
    }

    private func performLongScrollToBottom(initialOffset: CGFloat, delta: CGFloat, completion: (() -> Void)?) {
        animator = ManualAnimator()
        animator?.animate(duration: TimeInterval(0.25), curve: .easeInOut) { [weak self] percentage in
            guard let self else { return }

            collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x,
                                                   y: initialOffset + (delta * percentage))

            if percentage == 1.0 {
                animator = nil
                currentInterfaceActions.options.remove(.scrollingToBottom)
                completion?()
            }
        }
    }

    private func performShortScrollToBottom(to contentOffsetAtBottom: CGPoint, completion: (() -> Void)?) {
        currentInterfaceActions.options.insert(.scrollingToBottom)
        UIView.animate(withDuration: 0.25, animations: { [weak self] in
            self?.collectionView.setContentOffset(contentOffsetAtBottom, animated: true)
        }, completion: { [weak self] _ in
            self?.currentInterfaceActions.options.remove(.scrollingToBottom)
            completion?()
        })
    }
}

// MARK: - Agent power reconfigure

extension MessagesViewController {
    /// Reconfigures the visible message cells sent by any of the given inbox
    /// ids. Used when the owner-computed power map flips for a sender: the
    /// `.messages` items themselves are unchanged, so — exactly like the
    /// long-body expansion set — the change carries no DifferenceKit
    /// changeset of its own and visible cells must be reconfigured by hand.
    private func reconfigureCells(forSenderInboxIds inboxIds: Set<String>) {
        guard !inboxIds.isEmpty else { return }
        var indexPaths: [IndexPath] = []
        for (sectionIndex, section) in dataSource.sections.enumerated() {
            for (itemIndex, cell) in section.cells.enumerated() {
                guard case .messages(let group) = cell else { continue }
                if inboxIds.contains(group.sender.profile.inboxId) {
                    indexPaths.append(IndexPath(item: itemIndex, section: sectionIndex))
                }
            }
        }
        guard !indexPaths.isEmpty else { return }
        collectionView.reconfigureItems(at: indexPaths)
        // Pair with the layout call, matching `reconfigureCells(forMessageIds:)`
        // — the custom layout only re-measures cells stashed by its own
        // `reconfigureItems`.
        messagesLayout.reconfigureItems(at: indexPaths)
    }
}

// MARK: - MessagesControllerDelegate

extension MessagesViewController {
    private func processUpdates(for conversation: Conversation,
                                with messages: [MessagesListItemType],
                                invite: Invite,
                                hasLoadedAllMessages: Bool,
                                animated: Bool = true,
                                requiresIsolatedProcess: Bool,
                                completion: (() -> Void)? = nil) {
        // Clear the pagination loading flag whenever we receive a batch of messages.
        // Previously this only cleared on messages with .paginated origin, but if the
        // repository decides there are no more messages to load (totalCount <= limit),
        // it returns without triggering a new publisher emission, leaving the flag
        // stuck forever. Clearing on any update is safe because fetchPrevious has its
        // own concurrency guard, and hasMoreMessages gates further pagination requests.
        if currentControllerActions.options.contains(.loadingPreviousMessages) {
            currentControllerActions.options.remove(.loadingPreviousMessages)
        }

        // The processor (via `MessagesListRepository.verifiedAgent` and
        // `.agentBuilderSummary`) already drops the legacy "Agent
        // joined" update / `.agentPresentInfo` cells, attaches the contact
        // card to the agent's first group (or synthesizes an empty one),
        // applies the summary cutoff, and prepends the summary cell — so we
        // start from the publisher's items verbatim here.
        var cells: [MessagesListItemType] = messages
        let hasVerifiedConvosAgent: Bool = conversation.members.contains(where: \.isVerifiedConvosAgent)

        // Add invite or conversation info at the beginning if all messages are loaded.
        // A home-flow Agent Builder summary suppresses this whole block - the
        // summary card already announces the agent via its "You created an
        // agent" footer, so the "+ Invite members" pill on top of it is
        // redundant. The in-chat "New Agent" flow (`existingConversation`) is
        // different: it targets a real group, so its invite affordances stay
        // visible while the card shows.
        let summaryAllowsInvite: Bool = agentBuilderSummary == nil || agentBuilderSummary?.existingConversation == true
        // No `.invite` cell any more: the inviter's QR and the "Invite members"
        // pill it carried are both gone from the transcript, leaving the top bar's
        // invite button as the one place to add someone. An inviter now opens on
        // their messages rather than on a card about the room.
        //
        // The condition it used to guard is kept, negated, so nothing else moves:
        // whoever was getting the info preview still gets it, and an inviter who
        // was getting the QR now gets no leading cell rather than a different one.
        if hasLoadedAllMessages, summaryAllowsInvite, headerMode != .suppressed {
            let hostsInviteHeader = !conversation.isDraft && conversation.creator.isCurrentUser && !conversation.isLocked && !conversation.isFull
            if !hostsInviteHeader, !conversation.isDraft, headerMode == .standard, !hasVerifiedConvosAgent {
                cells.insert(.conversationInfo(conversation), at: 0)
            }
        }

        // A conversation nobody has said anything in yet gets a stand-in, so the
        // transcript is never entirely blank - and so the conversation sheet, which
        // sizes itself to the transcript, has a height to size itself to.
        //
        // Unless the transcript already carries something that says the same thing:
        // the agent DM's disclosure header always shows, so a "no comments" line
        // under it is the empty state twice.
        if hasLoadedAllMessages,
           !cells.contains(where: \.isMessages),
           !cells.contains(where: \.explainsAnEmptyTranscript) {
            cells.append(.noComments)
        }

        // The per-agent "lost power" cell derives ONLY from the backend's
        // owner-computed `agentPowerDepleted` signal, matched by inboxId.
        // `true` is the same fact for every member, so the cell shows to
        // everyone; an agent missing from the map is UNKNOWN (old backend,
        // or an agent the backend has no bookkeeping for) and shows nothing.
        // The viewer's own wallet is never consulted here — a zero-balance
        // viewer looking at a funded agent sees a working agent.
        // Only the upgrade CTA stays gated: the backend doesn't expose agent
        // ownership, so conversation creatorship is the closest proxy for
        // "the viewer is who tops this agent up".
        let showsUpgradeCTA: Bool = conversation.creator.isCurrentUser
        for agentMember in conversation.members.agentsWithDepletedPower(agentPowerDepletedByInboxId) {
            let agentInboxId = agentMember.profile.inboxId
            if let lastAgentIndex = cells.lastIndex(where: {
                if case .messages(let group) = $0 { return group.sender.profile.inboxId == agentInboxId }
                return false
            }) {
                cells.insert(.agentOutOfCredits(agentMember, showsUpgradeCTA: showsUpgradeCTA), at: lastAgentIndex + 1)
            } else {
                cells.append(.agentOutOfCredits(agentMember, showsUpgradeCTA: showsUpgradeCTA))
            }
        }

        let sections: [MessagesCollectionSection] = [
            .init(id: 0, title: "", cells: cells)
        ]

        guard isViewLoaded else {
            dataSource.sections = sections
            completion?()
            return
        }

        guard currentInterfaceActions.options.isEmpty else {
            scheduleDelayedUpdate(for: conversation,
                                  with: messages,
                                  invite: invite,
                                  hasLoadedAllMessages: hasLoadedAllMessages,
                                  animated: animated,
                                  requiresIsolatedProcess: requiresIsolatedProcess,
                                  completion: completion)
            return
        }

        performUpdate(with: sections,
                      animated: animated,
                      requiresIsolatedProcess: requiresIsolatedProcess,
                      completion: completion)
    }

    // swiftlint:disable:next function_parameter_count
    private func scheduleDelayedUpdate(for conversation: Conversation,
                                       with messages: [MessagesListItemType],
                                       invite: Invite,
                                       hasLoadedAllMessages: Bool,
                                       animated: Bool,
                                       requiresIsolatedProcess: Bool,
                                       completion: (() -> Void)?) {
        currentInterfaceActions.removeAllReactions(.delayedUpdate)
        let reaction = SetActor<Set<InterfaceActions>, ReactionTypes>.Reaction(
            type: .delayedUpdate,
            action: .onEmpty,
            executionType: .once,
            actionBlock: { [weak self] in
                guard let self else { return }
                processUpdates(for: conversation,
                               with: messages,
                               invite: invite,
                               hasLoadedAllMessages: hasLoadedAllMessages,
                               animated: animated,
                               requiresIsolatedProcess: requiresIsolatedProcess,
                               completion: completion)
            })
        currentInterfaceActions.add(reaction: reaction)
    }

    private func performUpdate(with sections: [MessagesCollectionSection],
                               animated: Bool,
                               requiresIsolatedProcess: Bool,
                               completion: (() -> Void)?) {
        let process = {
            let changeSet = StagedChangeset(source: self.dataSource.sections, target: sections).flattenIfPossible()

            guard !changeSet.isEmpty else {
                completion?()
                return
            }

            if requiresIsolatedProcess {
                self.messagesLayout.processOnlyVisibleItemsOnAnimatedBatchUpdates = true
                self.currentInterfaceActions.options.insert(.updatingCollectionInIsolation)
            }

            self.currentControllerActions.options.insert(.updatingCollection)
            self.collectionView.reload(
                using: changeSet,
                interrupt: { changeSet in
                    !changeSet.sectionInserted.isEmpty
                },
                onInterruptedReload: {
                    let positionSnapshot = MessagesLayoutPositionSnapshot(
                        indexPath: IndexPath(item: 0, section: sections.count - 1),
                        kind: .footer,
                        edge: .bottom
                    )
                    // Safe to combine with the forced layout in
                    // `restoreContentOffset` below: section inserts (the only
                    // way into this interrupted-reload path) happen solely on
                    // the initial load, never re-entrantly inside a sheet's
                    // keyboard layout pass - the scenario the deferred inset
                    // path exists to avoid.
                    self.flushPendingBottomBarInsetUpdate()
                    self.collectionView.reloadData()
                    self.messagesLayout.restoreContentOffset(with: positionSnapshot)
                },
                completion: { _ in
                    DispatchQueue.main.async {
                        self.messagesLayout.processOnlyVisibleItemsOnAnimatedBatchUpdates = false
                        if requiresIsolatedProcess {
                            self.currentInterfaceActions.options.remove(.updatingCollectionInIsolation)
                        }
                        completion?()
                        self.currentControllerActions.options.remove(.updatingCollection)
                    }
                },
                setData: { data in
                    self.dataSource.sections = data
                }
            )
        }

        if animated {
            process()
        } else {
            UIView.performWithoutAnimation {
                process()
            }
        }
    }
}

// MARK: - UIScrollViewDelegate & UICollectionViewDelegate

extension MessagesViewController: UIScrollViewDelegate, UICollectionViewDelegate {
    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard scrollView.contentSize.height > 0,
              !currentInterfaceActions.options.contains(.scrollingToTop),
              !currentInterfaceActions.options.contains(.scrollingToBottom) else {
            return false
        }

        currentInterfaceActions.options.insert(.scrollingToTop)
        return true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        guard !currentControllerActions.options.contains(.loadingInitialMessages),
              !currentControllerActions.options.contains(.loadingPreviousMessages) else {
            return
        }
        currentInterfaceActions.options.remove(.scrollingToTop)
        loadPreviousMessages()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        handleScrollViewDidScroll(scrollView)
    }

    private func handleScrollViewDidScroll(_ scrollView: UIScrollView) {
        isPinnedToBottom = distanceFromBottom <= Constant.pinnedToBottomTolerance

        if currentControllerActions.options.contains(.updatingCollection), collectionView.isDragging {
            interruptCurrentUpdateAnimation()
        }

        guard !currentControllerActions.options.contains(.loadingInitialMessages),
              !currentControllerActions.options.contains(.loadingPreviousMessages),
              !currentInterfaceActions.options.contains(.scrollingToTop),
              !currentInterfaceActions.options.contains(.scrollingToBottom) else {
            return
        }

        if scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top {
            loadPreviousMessages()
        }
    }

    private func interruptCurrentUpdateAnimation() {
        guard !hasPendingInterrupt else { return }
        hasPendingInterrupt = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingInterrupt = false
            UIView.performWithoutAnimation {
                self.collectionView.performBatchUpdates({}, completion: { _ in
                    let context = MessagesLayoutInvalidationContext()
                    context.invalidateLayoutMetrics = false
                    self.collectionView.collectionViewLayout.invalidateLayout(with: context)
                })
            }
        }
    }

    /// Called when the message context menu dismisses. Keyboard-driven
    /// inset updates are suppressed while the menu is up (see
    /// `updateBottomInset`), so the keyboard's dismissal under the overlay
    /// left the inset at its keyboard-up value and the list never moved.
    /// iOS usually restores first responder right after the menu goes away,
    /// and the returning keyboard matches the preserved inset -- zero
    /// motion. Dropping the inset eagerly here instead would clamp the
    /// offset down and the returning keyboard would push it back up, a
    /// visible down/up bounce. So wait briefly, and only if no keyboard
    /// change arrives settle the inset with the regular animated update.
    func restoreBottomInsetAfterContextMenu() {
        pendingContextMenuInsetFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingContextMenuInsetFallback = nil
            updateBottomInsetForBottomBarHeight()
        }
        pendingContextMenuInsetFallback = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constant.contextMenuInsetFallbackDelay,
            execute: fallback
        )
    }

    private func updateBottomInsetForBottomBarHeight() {
        guard isViewLoaded else { return }

        self.view.keyboardLayoutGuide.keyboardDismissPadding = bottomBarHeight

        // `hasBottomBar` gates the keyboard math here for the same reason it does
        // in `applyDeferredBottomInset`: a host that renders no bar of its own
        // positions its chrome against the keyboard and rises with it, so the
        // keyboard never overlaps this list and the clearance it was handed is
        // already the whole answer. Without the gate, a retained keyboard frame
        // turns a later bar-height update into an overlap inset that replaces that
        // clearance and shifts the transcript.
        if let lastKeyboardFrameChange, hasBottomBar {
            let newBottomInset = calculateNewBottomInset(for: lastKeyboardFrameChange)
            updateBottomInset(inset: newBottomInset, info: lastKeyboardFrameChange, isComposerDriven: true)
        } else {
            updateBottomInset(inset: bottomBarHeight, info: nil, isComposerDriven: true)
        }
    }
}

// MARK: - KeyboardListenerDelegate

extension MessagesViewController: KeyboardListenerDelegate {
    public func keyboardWillChangeFrame(info: KeyboardInfo) {
        self.lastKeyboardFrameChange = info

        // The keyboard taking over again after a context-menu dismissal is
        // the no-motion path; the deferred fallback is only for when it
        // never comes back.
        if !contextMenuState.isPresented {
            pendingContextMenuInsetFallback?.cancel()
            pendingContextMenuInsetFallback = nil
        }

        guard shouldHandleKeyboardFrameChange(info: info) else { return }

        currentInterfaceActions.options.insert(.changingKeyboardFrame)
        let newBottomInset = calculateNewBottomInset(for: info)
        // If the keyboard is growing the bottom inset (appearing or expanding),
        // queue a scroll-to-bottom for after the inset animation. SwiftUI's
        // @FocusState may not transition (e.g. when iOS restores first-responder
        // and just re-shows the keyboard), so we trigger off the keyboard frame
        // change directly rather than relying on focus events. Only flip the
        // flag once per keyboard show; rapid frame changes (emoji ↔ standard
        // keyboard, accessory bar resize) shouldn't queue duplicate scrolls.
        let insetGrowth = newBottomInset - collectionView.contentInset.bottom
        if !pendingScrollToBottomAfterKeyboard,
           insetGrowth > Constant.minKeyboardInsetGrowthForScrollAnchor {
            pendingScrollToBottomAfterKeyboard = true
        }
        updateBottomInset(inset: newBottomInset, info: info)
    }

    private func updateBottomInset(inset: CGFloat, info: KeyboardInfo?, isComposerDriven: Bool = false) {
        guard !contextMenuState.isPresented else { return }
        if isComposerDriven, isSettlingInitialLayout {
            // Bar-height changes during the open transition re-anchor
            // instantly (see applyBottomInsetInstantly); the send-time
            // deferral below is steady-state behavior.
            pendingComposerBottomInset = nil
            guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
            applyBottomInsetInstantly(inset)
            return
        }
        if isComposerDriven, inset < collectionView.contentInset.bottom, isPinnedToBottom {
            // The composer collapsed while the list was pinned -- typically
            // a multi-line draft being sent. Neither immediate option works
            // here: the anchored update drags the list down behind the
            // receding bar and the reveal scroll pulls it back up, and a
            // silent inset change clamps the pinned offset down by the
            // shrink in a single frame. So defer the change entirely: the
            // outgoing message lands a beat later and its reveal scroll
            // flushes the pending inset first (no clamp once the content
            // has grown) and settles in one motion. The fallback only fires
            // when no message follows (e.g. the user deleted their draft).
            deferBottomInset(to: inset)
            return
        }
        pendingComposerBottomInset = nil
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
        updateCollectionViewInsets(to: inset, with: info)
    }

    /// Applies a bar-height inset change with no animation and re-anchors the
    /// list arithmetically. Used while the conversation-open transition is
    /// still settling: the bar's measurement can land a render pass or two
    /// after the list's first paint, and animating the catch-up re-anchor
    /// (the steady-state behavior) visibly slides the messages up mid
    /// transition. Both steps below are plain property assignments - no batch
    /// updates, no snapshot restore, no forced layout - so this is also safe
    /// inside an in-flight UIKit layout pass.
    private func applyBottomInsetInstantly(_ inset: CGFloat) {
        UIView.performWithoutAnimation {
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
        }
        if !isUserInitiatedScrolling {
            scrollToBottom(animated: false)
        }
    }

    public func keyboardWillHide(info: KeyboardInfo) {
    }

    public func keyboardDidChangeFrame(info: KeyboardInfo) {
        if currentInterfaceActions.options.contains(.changingKeyboardFrame) {
            currentInterfaceActions.options.remove(.changingKeyboardFrame)
        }

        if pendingScrollToBottomAfterKeyboard {
            pendingScrollToBottomAfterKeyboard = false
            scrollToBottom()
        }
    }

    private func shouldHandleKeyboardFrameChange(info: KeyboardInfo) -> Bool {
        guard !currentInterfaceActions.options.contains(.changingFrameSize),
              collectionView.contentInsetAdjustmentBehavior != .never else {
            return false
        }
        return true
    }

    private func calculateNewBottomInset(for info: KeyboardInfo) -> CGFloat {
        guard let keyboardFrame = collectionView.window?.convert(info.frameEnd, to: view),
              !keyboardFrame.isEmpty else {
            return bottomBarHeight
        }
        let keyboardInset = (bottomBarHeight + collectionView.frame.minY +
                     collectionView.frame.size.height -
                     keyboardFrame.minY - collectionView.safeAreaInsets.bottom)
        let inset = max(keyboardInset, bottomBarHeight)
        return inset
    }

    private func updateCollectionViewInsets(to topInset: CGFloat) {
        let positionSnapshot = messagesLayout.getContentOffsetSnapshot(from: .top)

        if currentControllerActions.options.contains(.updatingCollection) {
            UIView.performWithoutAnimation {
                self.collectionView.performBatchUpdates {}
            }
        }

        currentInterfaceActions.options.insert(.changingContentInsets)
        UIView.animate(withDuration: 0.2, animations: {
            self.collectionView.performBatchUpdates({
                self.collectionView.contentInset.top = topInset
                self.collectionView.verticalScrollIndicatorInsets.top = topInset
            }, completion: nil)

            if let positionSnapshot, !self.isUserInitiatedScrolling {
                self.messagesLayout.restoreContentOffset(with: positionSnapshot)
            }
        }, completion: { _ in
            self.currentInterfaceActions.options.remove(.changingContentInsets)
        })
    }

    private func updateCollectionViewInsets(to newBottomInset: CGFloat, with info: KeyboardInfo?) {
        let positionSnapshot = messagesLayout.getContentOffsetSnapshot(from: .bottom)

        if currentControllerActions.options.contains(.updatingCollection) {
            UIView.performWithoutAnimation {
                self.collectionView.performBatchUpdates {}
            }
        }

        currentInterfaceActions.options.insert(.changingContentInsets)
        UIView.animate(withDuration: info?.animationDuration ?? 0.2, animations: {
            self.collectionView.performBatchUpdates({
                self.collectionView.contentInset.bottom = newBottomInset
                self.collectionView.verticalScrollIndicatorInsets.bottom = newBottomInset
            }, completion: nil)

            if let positionSnapshot, !self.isUserInitiatedScrolling {
                self.messagesLayout.restoreContentOffset(with: positionSnapshot)
            }
        }, completion: { _ in
            self.currentInterfaceActions.options.remove(.changingContentInsets)
        })
    }

    private enum Constant {
        // Floating-point slop for distinguishing "keyboard appearing" from
        // micro adjustments (e.g. autocorrect bar resizes, sub-point
        // accessory-view recalculations).
        static let minKeyboardInsetGrowthForScrollAnchor: CGFloat = 1.0
        // How close to the bottom (in points) the last settled offset must
        // be for the list to count as pinned. Covers float fuzz and inset
        // micro adjustments without absorbing intentional scrolling.
        static let pinnedToBottomTolerance: CGFloat = 8.0
        // How long after a context-menu dismissal to wait for the keyboard
        // to take back over before settling the bottom inset ourselves.
        // First-responder restoration lands well within this on device.
        static let contextMenuInsetFallbackDelay: TimeInterval = 0.6
        // How long after a composer collapse to wait for the outgoing
        // message's reveal scroll before settling to the bottom ourselves.
        static let composerSettleFallbackDelay: TimeInterval = 0.35
    }
}

// MARK: - Deferred Bottom Inset

extension MessagesViewController {
    /// Holds a bottom-inset shrink until the content can absorb it, and arms the
    /// fallback that applies it if nothing else does.
    ///
    /// The fallback is the whole point of routing both deferrals through here. A
    /// composer collapse is normally followed by the outgoing message's reveal
    /// scroll, which flushes the pending inset on its way. A host that shrinks
    /// the clearance it hands us has no such follow-up - the conversation sheet
    /// does exactly that, by the drag indicator's 10pt, as soon as it grows past
    /// collapsed - and without the timer that shrink is never applied at all.
    private func deferBottomInset(to inset: CGFloat) {
        pendingComposerBottomInset = inset
        pendingComposerSettleFallback?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            self?.settlePendingComposerInset()
        }
        pendingComposerSettleFallback = settle
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constant.composerSettleFallbackDelay,
            execute: settle
        )
    }

    private func settlePendingComposerInset() {
        guard !currentInterfaceActions.options.contains(.scrollingToBottom) else { return }
        guard flushPendingComposerInset() else { return }
        scrollToBottom()
    }

    /// Applies a deferred composer-collapse inset, silently when the content
    /// reaches the new bottom (no clamp, nothing moves) and via the anchored
    /// animated update otherwise. Returns whether an inset was applied.
    @discardableResult
    private func flushPendingComposerInset() -> Bool {
        guard let target = pendingComposerBottomInset else { return false }
        pendingComposerBottomInset = nil
        let adjustedTarget = target + collectionView.safeAreaInsets.bottom
        let reach = collectionView.contentSize.height
            - (collectionView.contentOffset.y + collectionView.frame.height - adjustedTarget)
        if reach >= -0.5 {
            UIView.performWithoutAnimation {
                collectionView.contentInset.bottom = target
                collectionView.verticalScrollIndicatorInsets.bottom = target
            }
        } else {
            updateCollectionViewInsets(to: target, with: nil)
        }
        return true
    }
}

// MARK: - File Attachment Preview

extension MessagesViewController {
    private func openFileAttachment(_ attachment: HydratedAttachment, from message: AnyMessage) {
        Task {
            do {
                let fileURL = try await loadFileForPreview(attachment)
                await MainActor.run {
                    if attachment.isHTMLFile, let onPresentHTMLAttachmentPreview {
                        onPresentHTMLAttachmentPreview(
                            attachment,
                            fileURL,
                            message.sender,
                            message.date
                        )
                    } else {
                        onPresentFileAttachmentPreview?(
                            attachment,
                            fileURL,
                            message.sender,
                            message.date
                        )
                    }
                }
            } catch {
                Log.error("Failed to open file attachment: \(error)")
                let alert = UIAlertController(
                    title: "File Unavailable",
                    message: "This file is no longer available on this device.",
                    preferredStyle: .alert
                )
                let okAction = UIAlertAction(title: "OK", style: .default)
                alert.addAction(okAction)
                present(alert, animated: true)
            }
        }
    }

    private func loadFileForPreview(_ attachment: HydratedAttachment) async throws -> URL {
        try await FileAttachmentLoader.loadFile(for: attachment)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MessagesViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is ImmediateTouchGestureRecognizer
    }
}

extension MessagesViewController {
    /// `.always` lets the safe area feed the list's clearance, which is what a
    /// host owning the whole screen wants: its floating bar arrives as a safe
    /// area and the list insets by it.
    ///
    /// A host that renders no bar of its own hands the clearance over as an
    /// explicit number instead, and must not have the safe area added on top -
    /// that inset changes with the keyboard, so the same number would resolve
    /// differently with the keyboard up and down, and the list's clearance would
    /// drift by the home indicator's height every time.
    func applyContentInsetAdjustmentBehavior() {
        collectionView.contentInsetAdjustmentBehavior = hasBottomBar ? .always : .never
        // The indicator's insets have to follow the content's, and this is a
        // separate flag: left on, UIKit keeps adding the safe area to the
        // scroll indicator after the content has stopped receiving it, and the
        // track ends up inset differently from the messages beside it.
        collectionView.automaticallyAdjustsScrollIndicatorInsets = hasBottomBar
    }

    /// Reports the transcript's content height when it changes, for a host that
    /// sizes itself to the messages - the conversation sheet, which will not offer
    /// a detent taller than there is transcript to put in it.
    ///
    /// Rounded to a point and compared before reporting: this runs on every layout
    /// pass, and the host turns the number into a set of presentation detents, so
    /// a report that carries no news is a rebuild for nothing.
    func reportContentHeightIfChanged() {
        let height: CGFloat = collectionView.contentSize.height.rounded()
        guard height > 0, height != lastReportedContentHeight else { return }
        lastReportedContentHeight = height
        // Out of the layout pass, always. This is called from the collection
        // view's own `layoutSubviews`, and the host turns the number into
        // presentation detents - so delivering it inline would re-enter the layout
        // that is still running.
        //
        // The top inset is re-applied here too: it holds short content against the
        // bottom, so it has to follow the content height, and this is the one hook
        // that fires when that changes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            applyClippedTopOverflow()
            onContentHeightChanged?(height)
        }
    }

    /// The list's top inset: what the host clips away, plus whatever it takes to
    /// hold short content against the bottom. See `clippedTopOverflow` and
    /// `shortContentTopSlack`.
    func applyClippedTopOverflow() {
        let target: CGFloat = clippedTopOverflow + shortContentTopSlack
        guard abs(collectionView.contentInset.top - target) > 0.5 else { return }
        collectionView.contentInset.top = target
        collectionView.verticalScrollIndicatorInsets.top = target
    }

    /// Extra top inset that rests content too short to fill the visible area
    /// against the bottom of it, instead of leaving it at the top.
    ///
    /// A scroll view puts content shorter than its frame at the top, which for a
    /// chat is the wrong end: a conversation with one message should show it just
    /// above the composer, where the next one will appear. The transcript used to
    /// be padded out by the invite card and rarely reached this; without it, every
    /// new conversation does.
    ///
    /// An inset rather than an offset applied to the item frames themselves, and
    /// that is the whole point. Offsetting frames inside the layout - which is what
    /// ChatLayout's own `keepContentAtBottomOfVisibleArea` does, and what this
    /// briefly did - puts the alignment in the middle of self-sizing: a cell
    /// reports its preferred size, the content height changes, the offset changes,
    /// the attributes no longer match what the cell was handed, UIKit invalidates
    /// and asks again. That loop crashed the app on device, seven
    /// `_updateVisibleCellsNow:` frames deep. An inset cannot join that cycle
    /// because it does not change where any item thinks it is.
    ///
    /// Only for hosts that hand their clearance over rather than rendering a bar of
    /// their own - the conversation sheet's transcripts and the thinking detail. A
    /// host that owns the whole screen keeps the layout it had.
    ///
    /// Zero until the content has measured: slack against a content size of nothing
    /// would push the first messages to the bottom and haul them back as they
    /// arrived.
    private var shortContentTopSlack: CGFloat {
        guard !hasBottomBar, collectionView.contentSize.height > 0 else { return 0 }
        let visibleHeight: CGFloat = collectionView.frame.height
            - clippedTopOverflow
            - collectionView.contentInset.bottom
        return max(0, visibleHeight - collectionView.contentSize.height)
    }
}
#endif
