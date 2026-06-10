import ConvosComposer
import Combine
import ConvosCore
import DifferenceKit
import Foundation
import Observation
import QuickLook
import SwiftUI
import UIKit
import WebKit

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
enum MessagesHeaderMode {
    case standard
    case hidden
    case suppressed
}

final class MessagesViewController: UIViewController {
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
        if let lastKeyboardFrameChange {
            targetInset = calculateNewBottomInset(for: lastKeyboardFrameChange)
        } else {
            targetInset = bottomBarHeight
        }
        guard abs(collectionView.contentInset.bottom - targetInset) > 0.5 else { return }
        if targetInset < collectionView.contentInset.bottom, isPinnedToBottom, !isSettlingInitialLayout {
            pendingComposerBottomInset = targetInset
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
    func scrollToBottomForSend() {
        scrollToBottom()
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
    var contextMenuState: MessageContextMenuState = .init() {
        didSet { dataSource.contextMenuState = contextMenuState }
    }

    var onPhotoRevealed: ((String) -> Void)?
    var onPhotoHidden: ((String) -> Void)?
    var onPhotoDimensionsLoaded: ((String, Int, Int) -> Void)?
    var onAgentOutOfCredits: (() -> Void)?
    /// Drives the in-stream out-of-credits cell. Set from
    /// `MessagesViewRepresentable` off `ConversationViewModel.creditsDepleted`
    /// (which mirrors `CreditsServices.shared.currentBalance?.isDepleted`).
    /// When this flips while a state is already applied, we replay the
    /// last processed state so the cell appears / disappears without
    /// needing the messages publisher to emit again.
    var creditsDepleted: Bool = false {
        didSet {
            dataSource.creditsDepleted = creditsDepleted
            guard oldValue != creditsDepleted, isViewLoaded, let state else { return }
            self.state = state
        }
    }
    var onTapUpdateMember: ((ConversationMember) -> Void)?
    var onRetryMessage: ((AnyMessage) -> Void)?
    var onDeleteMessage: ((AnyMessage) -> Void)?
    var onRetryAgentJoin: (() -> Void)?
    var onCopyInviteLink: (() -> Void)?
    var onConvoCode: (() -> Void)?
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
    /// can drive the post-tap `AttachmentPreviewSheet` presentation with
    /// a matched-geometry zoom transition. When `nil`, falls back to the
    /// in-class UIKit `presentAttachmentPreview` path.
    var onPresentHTMLAttachmentPreview: ((HydratedAttachment, URL, ConversationMember, Date) -> Void)?

    var isAgentJoinPending: Bool = false {
        didSet { dataSource.isAgentJoinPending = isAgentJoinPending }
    }
    var shouldBlurPhotos: Bool = true {
        didSet {
            guard oldValue != shouldBlurPhotos else { return }
            dataSource.shouldBlurPhotos = shouldBlurPhotos
            collectionView.reloadData()
        }
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

    override func viewDidLoad() {
        super.viewDidLoad()

        setupCollectionView()
        setupUI()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        handleViewTransition(to: size, with: coordinator)
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isSettlingInitialLayout = false
        messagesLayout.compensatesAllSelfSizingGrowth = false
    }

    /// The SwiftUI bottom bar mounts into the safe area a render pass or two
    /// after the list's first bottom anchor during the open transition, which
    /// silently grows `adjustedContentInset.bottom` without re-anchoring -
    /// the list paints short of the bottom until something else scrolls it.
    /// Re-anchor arithmetically while settling; `scrollToBottom(animated:
    /// false)` is plain property assignments, safe mid-layout.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard isSettlingInitialLayout, isViewLoaded, !isUserInitiatedScrolling else { return }
        scrollToBottom(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
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
        messagesLayout.delegate = dataSource
        collectionView.keyboardDismissMode = .interactive

        collectionView.contentInset = .init(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
        collectionView.scrollIndicatorInsets = collectionView.contentInset
        collectionView.contentInsetAdjustmentBehavior = .always
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
        dataSource.onPhotoRevealed = { [weak self] attachmentKey in
            self?.onPhotoRevealed?(attachmentKey)
        }
        dataSource.onPhotoHidden = { [weak self] attachmentKey in
            self?.onPhotoHidden?(attachmentKey)
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
        dataSource.onCopyInviteLink = { [weak self] in
            self?.onCopyInviteLink?()
        }
        dataSource.onConvoCode = { [weak self] in
            self?.onConvoCode?()
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

        let contentOffsetAtBottom = CGPoint(
            x: collectionView.contentOffset.x,
            y: (messagesLayout.collectionViewContentSize.height -
                collectionView.frame.height +
                bottomAnchorInset)
        )

        // Exit before cancelling in-flight animations: when the layout's
        // animated bottom-pinning compensation is already scrolling to the
        // bottom, the model offset is at the target and this call must not
        // stamp the presentation mid-flight (which would snap the scroll).
        guard contentOffsetAtBottom.y > 0,
              abs(contentOffsetAtBottom.y - collectionView.contentOffset.y) > 0.5 else {
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

        // Mirror the conversation's persisted "hide invite QR" flag onto the
        // data source so the `.invite` cell renderer can drop the QR card
        // while keeping the invite menu visible.
        dataSource.hidesInviteCard = conversation.hidesInviteCard

        // Add invite or conversation info at the beginning if all messages are loaded.
        // A home-flow Agent Builder summary suppresses this whole block - the
        // summary card already announces the agent via its "You created an
        // agent" footer, so the "+ Invite members" pill on top of it is
        // redundant. The in-chat "New Agent" flow (`existingConversation`) is
        // different: it targets a real group, so its invite affordances stay
        // visible while the card shows. Without a summary, `.hidden` header
        // mode still renders the `.invite` cell (which surfaces just the
        // "Invite members" affordance - the QR is gated inside the cell on the
        // same `headerMode`).
        let summaryAllowsInvite: Bool = agentBuilderSummary == nil || agentBuilderSummary?.existingConversation == true
        if hasLoadedAllMessages, !conversation.isDraft, summaryAllowsInvite, headerMode != .suppressed {
            if conversation.creator.isCurrentUser && !conversation.isLocked && !conversation.isFull {
                cells.insert(.invite(invite), at: 0)
            } else if headerMode == .standard, !hasVerifiedConvosAgent {
                cells.insert(.conversationInfo(conversation), at: 0)
            }
        }

        if creditsDepleted, let agentMember = conversation.members.first(where: { $0.isAgent }) {
            let agentInboxId = agentMember.profile.inboxId
            let isCurrentUserCreator: Bool = conversation.creator.isCurrentUser
            if let lastAgentIndex = cells.lastIndex(where: {
                if case .messages(let group) = $0 { return group.sender.profile.inboxId == agentInboxId }
                return false
            }) {
                cells.insert(.agentOutOfCredits(agentMember, isCurrentUserCreator: isCurrentUserCreator), at: lastAgentIndex + 1)
            } else {
                cells.append(.agentOutOfCredits(agentMember, isCurrentUserCreator: isCurrentUserCreator))
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
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard scrollView.contentSize.height > 0,
              !currentInterfaceActions.options.contains(.scrollingToTop),
              !currentInterfaceActions.options.contains(.scrollingToBottom) else {
            return false
        }

        currentInterfaceActions.options.insert(.scrollingToTop)
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        guard !currentControllerActions.options.contains(.loadingInitialMessages),
              !currentControllerActions.options.contains(.loadingPreviousMessages) else {
            return
        }
        currentInterfaceActions.options.remove(.scrollingToTop)
        loadPreviousMessages()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
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

        if let lastKeyboardFrameChange {
            let newBottomInset = calculateNewBottomInset(for: lastKeyboardFrameChange)
            updateBottomInset(inset: newBottomInset, info: lastKeyboardFrameChange, isComposerDriven: true)
        } else {
            updateBottomInset(inset: bottomBarHeight, info: nil, isComposerDriven: true)
        }
    }
}

// MARK: - KeyboardListenerDelegate

extension MessagesViewController: KeyboardListenerDelegate {
    func keyboardWillChangeFrame(info: KeyboardInfo) {
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
            return
        }
        pendingComposerBottomInset = nil
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
        updateCollectionViewInsets(to: inset, with: info)
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

    func keyboardWillHide(info: KeyboardInfo) {
    }

    func keyboardDidChangeFrame(info: KeyboardInfo) {
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

// MARK: - File Attachment QuickLook

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
                        presentAttachmentPreview(
                            attachment: attachment,
                            fileURL: fileURL,
                            sender: message.sender,
                            sentAt: message.date
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

    private func presentAttachmentPreview(
        attachment: HydratedAttachment,
        fileURL: URL,
        sender: ConversationMember,
        sentAt: Date
    ) {
        let preview = AttachmentPreviewSheet(
            attachment: attachment,
            fileURL: fileURL,
            sender: sender,
            sentAt: sentAt,
            profileSheetContent: profileSheetForMember
        )
        let controller = UIHostingController(rootView: preview)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        present(controller, animated: true)
    }

    private func loadFileForPreview(_ attachment: HydratedAttachment) async throws -> URL {
        try await FileAttachmentLoader.loadFile(for: attachment)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MessagesViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is ImmediateTouchGestureRecognizer
    }
}
