import Combine
import ConvosComposer
import ConvosCore
import ConvosMetrics
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
@Observable
final class ConversationsViewModel {
    // MARK: - Public

    private(set) var focusCoordinator: FocusCoordinator

    // MARK: - Selection State

    @ObservationIgnored
    private var _selectedConversationId: String? {
        didSet {
            updateSelectionState()
        }
    }

    var selectedConversationId: Conversation.ID? {
        get { _selectedConversationId }
        set {
            guard _selectedConversationId != newValue else { return }
            _selectedConversationId = newValue
        }
    }

    private(set) var selectedConversation: Conversation? {
        get {
            guard let id = _selectedConversationId else { return nil }
            return conversations.first(where: { $0.id == id })
        }
        set {
            selectedConversationId = newValue?.id
        }
    }

    private(set) var selectedConversationViewModel: ConversationViewModel?

    @ObservationIgnored
    private var updateSelectionTask: Task<Void, Never>?

    private func updateSelectionState() {
        let conversation = selectedConversation
        let previousViewModelId = selectedConversationViewModel?.conversation.id

        if let conversation = conversation {
            if selectedConversationViewModel?.conversation.id != conversation.id {
                updateSelectionTask?.cancel()
                let viewModel = ConversationViewModel.createSync(
                    conversation: conversation,
                    session: session,
                    coreActions: coreActions
                )
                selectedConversationViewModel = viewModel
                markConversationAsRead(conversation)
            }
        } else {
            if let previousViewModel = selectedConversationViewModel {
                markConversationAsRead(previousViewModel.conversation)
            }
            updateSelectionTask?.cancel()
            selectedConversationViewModel = nil
        }

        if previousViewModelId != _selectedConversationId {
            let userInfo: [AnyHashable: Any] = _selectedConversationId.map { ["conversationId": $0] } ?? [:]
            NotificationCenter.default.post(
                name: .activeConversationChanged,
                object: nil,
                userInfo: userInfo
            )
        }

        updateListVisibility()
    }

    var pendingGrantRequest: PendingGrantRequest?
    var pendingPairDevice: PendingPairDevice?
    var pendingJoinerPairing: JoinerPairingSheetViewModel?
    /// Drives the first-install "Pair <device>?" sheet when another
    /// device's identity is found in the iCloud-synced keychain backup.
    var foundDevicePairingPrompt: FoundDevicePairingPrompt?
    /// Drives the first-launch "Hello / My name is" profile setup sheet.
    /// Presented only when the pairable-device check found no other
    /// identity in the iCloud-synced keychain backup and no pairing UI is
    /// on screen (see `presentFirstLaunchProfileSetupIfNeeded`).
    var presentingFirstLaunchProfileSetup: Bool = false
    /// Joiner pairing flow prepared by `pairWithFoundDevice()`, promoted
    /// to `pendingJoinerPairing` once the prompt sheet finishes
    /// dismissing - presenting both sheets in the same tick can drop the
    /// second presentation.
    @ObservationIgnored
    private var preparedFoundDevicePairing: JoinerPairingSheetViewModel?
    /// Whether the prompt sheet's dismissal has completed. Minting and
    /// dismissal race in both directions: whichever finishes second
    /// performs the promotion (see `pairWithFoundDevice`).
    @ObservationIgnored
    private var foundDevicePromptDismissalComplete: Bool = false
    @ObservationIgnored
    private var didCheckForPairableDevice: Bool = false
    /// Initiator pairing sheet auto-surfaced by a verified join request
    /// arriving on the main message stream. Presented at MainTabView
    /// level so it shows over any tab.
    var incomingPairingRequest: PairingSheetViewModel?
    /// When the current `incomingPairingRequest` was assigned. Drives the
    /// dropped-presentation watchdog in `handleVerifiedJoinRequest`.
    @ObservationIgnored
    private var incomingPairingPresentedAt: Date?
    @ObservationIgnored
    private var pendingIncomingPairRequest: PendingIncomingPairRequest?
    @ObservationIgnored
    private let incomingPairingObservers: PairingNotificationObservers = .init()
    let staleDeviceObserver: StaleDeviceObserver = .init()

    var newConversationViewModel: NewConversationViewModel? {
        didSet {
            oldValue?.cleanUpIfNeeded()
            if newConversationViewModel == nil {
                NotificationCenter.default.post(
                    name: .activeConversationChanged,
                    object: nil,
                    userInfo: [:]
                )
            }
            updateListVisibility()
        }
    }
    var agentBuilderViewModel: AgentBuilderViewModel? {
        didSet {
            // Mirrors `newConversationViewModel.didSet`'s cleanup: when
            // an Agent Builder VM is dropped without committing (e.g.
            // the host view sets this to nil on tab swap), discard the
            // outgoing one so its draft XMTP group is torn down. Skip
            // when the user committed — that conversation has shipped
            // and should stay on the server.
            if let outgoing = oldValue,
               oldValue !== agentBuilderViewModel,
               !outgoing.hasCommitted,
               !outgoing.didDiscard {
                outgoing.discard()
            }
            updateListVisibility()
        }
    }
    /// Drives the Compose flow sheet (`ComposeFlowView`): the contacts picker
    /// is the root, and every conversation is minted on intent inside the flow
    /// (Continue / Send-invite / Show-code) -- nothing is claimed just by
    /// opening it. Distinct from `newConversationViewModel` (scanner / join /
    /// template), so the two never drive overlapping presentations.
    var presentingComposeFlow: Bool = false
    var presentingExplodeInfo: Bool = false
    var presentingPinLimitInfo: Bool = false

    var conversations: [Conversation] = []
    /// Whether `conversations` has received its first real value from the
    /// database (first-frame prime or first publisher emission). Until then
    /// an empty array means "not loaded yet", not "no conversations", so the
    /// empty-state CTA must stay hidden.
    private(set) var hasLoadedInitialConversations: Bool = false
    private(set) var hiddenConversationIds: Set<String> = []
    private var conversationsCount: Int = 0 {
        didSet {
            if conversationsCount > 1 {
                hasCreatedMoreThanOneConvo = true
            }
        }
    }

    enum ConversationFilter {
        case all
        case unread
        case exploding

        var emptyStateMessage: String {
            switch self {
            case .all:
                return "No convos"
            case .unread:
                return "No unread convos"
            case .exploding:
                return "No exploding convos"
            }
        }
    }

    var activeFilter: ConversationFilter = .all

    var pinnedConversations: [Conversation] {
        let baseConversations = pinnedBaseConversations
        return Self.applyFilter(activeFilter, to: baseConversations)
    }

    private var pinnedBaseConversations: [Conversation] {
        conversations
            .filter { $0.isPinned }
            .filter { $0.kind == .group }
            .sorted { ($0.pinnedOrder ?? Int.max) < ($1.pinnedOrder ?? Int.max) }
    }

    private static func applyFilter(_ filter: ConversationFilter, to conversations: [Conversation]) -> [Conversation] {
        switch filter {
        case .all:
            return conversations
        case .unread:
            return conversations.filter { $0.isUnread }
        case .exploding:
            return conversations.filter { $0.scheduledExplosionDate != nil }
        }
    }

    var unpinnedConversations: [Conversation] {
        let baseConversations = conversations.filter { !$0.isPinned }.filter { $0.kind == .group }
        switch activeFilter {
        case .all:
            return baseConversations
        case .unread:
            return baseConversations.filter { $0.isUnread }
        case .exploding:
            return baseConversations.filter { $0.scheduledExplosionDate != nil }
        }
    }

    var hasUnpinnedConversations: Bool {
        conversations.contains { !$0.isPinned && $0.kind == .group }
    }

    var isFilteredResultEmpty: Bool {
        activeFilter != .all && unpinnedConversations.isEmpty && hasUnpinnedConversations
    }

    /// True when the chats list is empty and the `.all` filter is active —
    /// i.e. the user is in the no-convos-yet state that previously rendered
    /// `ConversationsListEmptyCTA` ("Pop-up private convos"). Mirrors the
    /// SwiftUI-side gate inside `ConversationsView.sidebarContent` so the
    /// shell can swap the chats tab for an inline agent builder and hide
    /// the bottom chrome. Gated on the initial read having landed: on cold
    /// launch `conversations` starts empty while the first database read is
    /// still in flight, and rendering the CTA then shows a user with
    /// conversations a false "no convos yet" screen for seconds.
    var isEmptyCTAActive: Bool {
        hasLoadedInitialConversations
            && unpinnedConversations.isEmpty
            && pinnedConversations.isEmpty
            && activeFilter == .all
    }

    private static let hasCreatedMoreThanOneConvoKey: String = "hasCreatedMoreThanOneConvo"
    private(set) var hasCreatedMoreThanOneConvo: Bool {
        get {
            UserDefaults.standard.bool(forKey: Self.hasCreatedMoreThanOneConvoKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.hasCreatedMoreThanOneConvoKey)
        }
    }

    static func resetUserDefaults() {
        UserDefaults.standard.removeObject(forKey: hasCreatedMoreThanOneConvoKey)
        UserDefaults.standard.removeObject(forKey: hasDeclinedFoundDevicePairingKey)
    }

    // MARK: - Private

    let session: any SessionManagerProtocol
    let coreActions: any CoreActions
    private let conversationsRepository: any ConversationsRepositoryProtocol
    private let conversationsCountRepository: any ConversationsCountRepositoryProtocol
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = .init()
    @ObservationIgnored
    private var leftConversationObserver: Any?
    /// A scan-resolved conversation to navigate into that isn't in the list yet
    /// (a just-joined convo lands via the conversations publisher a beat later).
    /// Resolved to a selection once the row appears.
    @ObservationIgnored
    private var pendingScanNavigationConversationId: String?
    /// A connection-grant deep link that arrived before its conversation was
    /// in the list (cold launch races the initial load). Resolved once the
    /// conversation appears; mirrors `pendingScanNavigationConversationId`.
    @ObservationIgnored
    private var pendingConnectionGrantLink: (serviceId: String, conversationId: String)?
    /// Whether the conversations / count publishers have delivered at least
    /// one emission. The late prime path must skip applying its stale
    /// snapshot after any emission, including a legitimately empty or zero
    /// one, so this cannot be inferred from the data values themselves.
    @ObservationIgnored
    private var conversationsObservationHasEmitted: Bool = false
    @ObservationIgnored
    private var conversationsCountObservationHasEmitted: Bool = false
    /// Mirrors whether the Chats tab is frontmost in the tab shell (kept
    /// current by `MainTabView`). Scan navigation must not select a
    /// conversation while another tab is visible: selecting hides the tab bar
    /// and lifts the conversation indicator on every tab, while the pushed
    /// conversation mounts in the background Chats stack -- stranding the
    /// user on a hybrid screen with no way back. Defaults to true for hosts
    /// without a tab shell (previews, tests).
    @ObservationIgnored
    var isChatsTabActive: Bool = true {
        didSet {
            guard isChatsTabActive, !oldValue else { return }
            resolvePendingScanNavigationIfPossible()
        }
    }
    /// Asks the tab shell to bring the Chats tab frontmost. Invoked when a
    /// scan resolves so the user is directed to Chats no matter which tab the
    /// scan started from; the parked navigation is consumed only after the
    /// switch has committed (see `isChatsTabActive`).
    @ObservationIgnored
    var bringChatsTabToFront: (() -> Void)?

    private var horizontalSizeClass: UserInterfaceSizeClass?

    let appSettingsViewModel: AppSettingsViewModel

    init(
        session: any SessionManagerProtocol,
        horizontalSizeClass: UserInterfaceSizeClass? = nil,
        coreActions: any CoreActions = NoOpCoreActions()
    ) {
        self.session = session
        self.coreActions = coreActions
        self.horizontalSizeClass = horizontalSizeClass
        let coordinator = FocusCoordinator(horizontalSizeClass: horizontalSizeClass)
        self.focusCoordinator = coordinator
        self.appSettingsViewModel = AppSettingsViewModel(session: session)
        self.conversationsRepository = session.conversationsRepository(
            for: .allowed
        )
        // Bind the stale-device observer to the session's state manager
        // so the banner appears when this device's installation is
        // revoked from the network. Done asynchronously because
        // messagingService() may need to construct the service.
        let stale = staleDeviceObserver
        Task { @MainActor in
            stale.bind(to: session.messagingService().sessionStateManager)
        }
        self.conversationsCountRepository = session.conversationsCountRepo(
            for: .allowed,
            kinds: .groups
        )
        self.conversations = []
        self.conversationsCount = 0
        primeInitialConversations()
        observe()
        observeIncomingPairingRequests()
    }

    func updateHorizontalSizeClass(_ sizeClass: UserInterfaceSizeClass?) {
        guard horizontalSizeClass != sizeClass else { return }
        horizontalSizeClass = sizeClass
        focusCoordinator.horizontalSizeClass = sizeClass
    }

    func onAppear() {
        isVisible = true
        updateListVisibility()
        checkForPairableDeviceIfNeeded()
    }

    func onDisappear() {
        isVisible = false
        updateListVisibility()
    }

    @ObservationIgnored
    private var isVisible: Bool = false

    private func updateListVisibility() {
        let isFocusedOnList = isVisible
            && selectedConversationViewModel == nil
            && newConversationViewModel == nil
            && agentBuilderViewModel == nil
        session.setIsOnConversationsList(isFocusedOnList)
    }

    deinit {
        updateSelectionTask?.cancel()
    }

    func makeGrantRequestSheetViewModel(for request: PendingGrantRequest) -> CloudConnectionGrantRequestSheetViewModel {
        let conversation = conversations.first(where: { $0.id == request.conversationId })
        return CloudConnectionGrantRequestSheetViewModel(
            serviceId: request.serviceId,
            conversationId: request.conversationId,
            conversation: conversation,
            session: session
        )
    }

    func handleURL(_ url: URL) {
        guard let destination = DeepLinkHandler.destination(for: url) else {
            return
        }

        switch destination {
        case .joinConversation(inviteCode: let inviteCode):
            join(from: inviteCode)
        case let .connectionGrant(serviceId: serviceId, conversationId: conversationId):
            guard conversations.contains(where: { $0.id == conversationId }) else {
                // On cold launch the list may not have loaded yet (the
                // initial prime and the repository publisher both arrive
                // asynchronously), so park the link and resolve it once the
                // conversation appears instead of dropping it outright.
                Log.warning("Parking connection grant deep link until its conversation loads")
                pendingConnectionGrantLink = (serviceId: serviceId, conversationId: conversationId)
                return
            }
            openConnectionGrant(serviceId: serviceId, conversationId: conversationId)
        case let .pairDevice(pairingId, expiresAt, initiatorName):
            pendingPairDevice = PendingPairDevice(
                pairingId: pairingId,
                expiresAt: expiresAt,
                initiatorName: initiatorName
            )
            pendingJoinerPairing = makeJoinerPairingViewModel(
                pairingId: pairingId,
                expiresAt: expiresAt,
                initiatorName: initiatorName
            )
        case .agentTemplate(templateId: let templateId):
            startConversation(withAgentTemplateId: templateId)
        }
    }

    /// Compose opens the contacts picker first (optional selection); the flow
    /// mints a conversation only on intent (`ComposeFlowView`), so opening and
    /// cancelling the picker claims nothing. With no contacts to pick from,
    /// the picker would be pointless -- so we skip it and open the
    /// new-conversation view directly, like the pre-picker flow.
    func onStartConvo() {
        // Count the contacts the picker would actually show (excludes agents,
        // blocked, and unnamed) -- the raw contact count includes those, so
        // it can't decide whether the picker is worth showing.
        let contacts = (try? session.messagingServiceSync().contactsRepository().fetchAll()) ?? []
        let pickable = ContactsPickerViewModel.pickableContacts(contacts)
        guard !pickable.isEmpty else {
            newConversationViewModel = NewConversationViewModel(
                session: session,
                mode: .newConversation,
                coreActions: coreActions
            )
            return
        }
        presentingComposeFlow = true
    }

    /// The home scan button lands on the embedded Scan/Invite screen with the
    /// Scan segment active, so the live viewfinder and "Or scan from camera roll" are
    /// both reachable (a scanned code opens a brand-new convo to join/add).
    /// Mirrors `onShowInviteCode` but starts on `.scan`.
    func onJoinConvo() {
        let viewModel = NewConversationViewModel(
            session: session,
            mode: .newConversation,
            showsEmbeddedInvite: true,
            embeddedInviteInitialSegment: .scan,
            coreActions: coreActions
        )
        viewModel.onScanResolvedConversation = { [weak self] conversationId in
            self?.navigateToScannedConversation(conversationId)
        }
        newConversationViewModel = viewModel
    }

    /// Starts and enters a fresh conversation showing the invite QR at the top
    /// (the standard message-list header) and the scan viewfinder as its
    /// trailing action -- the "Show an invite code" entry point. Mirrors the
    /// no-contacts branch of `onStartConvo`, opting the conversation into the
    /// embedded-invite presentation.
    func onShowInviteCode() {
        let viewModel = NewConversationViewModel(
            session: session,
            mode: .newConversation,
            showsEmbeddedInvite: true,
            coreActions: coreActions
        )
        viewModel.onScanResolvedConversation = { [weak self] conversationId in
            self?.navigateToScannedConversation(conversationId)
        }
        newConversationViewModel = viewModel
    }

    func onStartAgent(entryMode: AgentBuilderEntryMode = .composer) {
        agentBuilderViewModel = AgentBuilderViewModel(session: session, entryMode: entryMode, coreActions: coreActions)
    }

    private func join(from inviteCode: String) {
        newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .joinInvite(code: inviteCode),
            coreActions: coreActions
        )
    }

    /// Opens a new conversation and, once it is ready, requests a fresh
    /// instance of the given agent template into it. Entry point for the
    /// `convos://template/<id>` deeplink.
    private func startConversation(withAgentTemplateId templateId: String) {
        newConversationViewModel = NewConversationViewModel(
            session: session,
            // Deep link knows only the template id; the optimistic identity is
            // resolved asynchronously inside NewConversationViewModel.
            mode: .newConversationWithTemplate(templateId: templateId, optimisticIdentity: nil),
            coreActions: coreActions
        )
    }

    func deleteAllData() {
        selectedConversation = nil
        appSettingsViewModel.deleteAllData {}
    }

    /// Called by `StaleDeviceBanner` when the user holds "Hold to reset"
    /// on a session that has landed in `.error(DeviceReplacedError)`.
    /// Same underlying action as "Delete all app data" (no confirmation
    /// sheet — the hold itself is the confirmation, and the banner copy
    /// is the explanation). After the delete completes we rebind the
    /// stale-device observer to the freshly-built state manager so the
    /// banner doesn't linger past the reset.
    func resetForStaleDevice() {
        staleDeviceObserver.dismiss()
        selectedConversation = nil
        let session = self.session
        let observer = staleDeviceObserver
        appSettingsViewModel.deleteAllData { [weak self] in
            guard self != nil else { return }
            Task { @MainActor in
                observer.bind(to: session.messagingService().sessionStateManager)
            }
        }
    }

    func leave(conversation: Conversation) {
        // Optimistic hide while the consent write lands. Once the DB row's
        // consent flips to .denied, ConversationsRepository filters it out
        // unconditionally, so the hiddenConversationIds fallback is only
        // needed during the in-flight window.
        hiddenConversationIds.insert(conversation.id)
        if let index = conversations.firstIndex(of: conversation) {
            conversations.remove(at: index)
        }
        if selectedConversation == conversation {
            selectedConversation = nil
        }

        let conversationId = conversation.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let writer = session.messagingService().conversationConsentWriter()
                try await writer.delete(conversation: conversation)
                self.hiddenConversationIds.remove(conversationId)
            } catch {
                self.hiddenConversationIds.remove(conversationId)
                Log.error("Failed to persist delete for \(conversationId): \(error.localizedDescription)")
            }
        }
    }

    private func observe() {
        leftConversationObserver = NotificationCenter.default
            .addObserver(forName: .leftConversationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let conversationId = notification.userInfo?["conversationId"] as? String else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    Log.info("Left conversation notification received for conversation: \(conversationId)")
                    // Keep hiding on re-emits — see `leave(conversation:)` and
                    // ConversationViewModel.leaveConvo for the same pattern.
                    hiddenConversationIds.insert(conversationId)
                    conversations.removeAll { $0.id == conversationId }
                    if _selectedConversationId == conversationId {
                        _selectedConversationId = nil
                        selectedConversationViewModel = nil
                    }
                    if newConversationViewModel?.conversationViewModel?.conversation.id == conversationId {
                        newConversationViewModel = nil
                    }
                }
            }

        NotificationCenter.default
            .publisher(for: .explosionNotificationTapped)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.selectedConversation = nil
                self?.presentingExplodeInfo = true
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .conversationNotificationTapped)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleConversationNotificationTap(notification)
            }
            .store(in: &cancellables)

        conversationsCountRepository.conversationsCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversationsCount in
                self?.conversationsCountObservationHasEmitted = true
                self?.conversationsCount = conversationsCount
            }
            .store(in: &cancellables)
        conversationsRepository.conversationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                guard let self else { return }
                self.conversationsObservationHasEmitted = true
                self.hasLoadedInitialConversations = true
                self.conversations = hiddenConversationIds.isEmpty
                    ? conversations
                    : conversations.filter { !hiddenConversationIds.contains($0.id) }

                ShareSuggestionDonator.donate(self.conversations)

                if let selectedId = _selectedConversationId,
                   !conversations.contains(where: { $0.id == selectedId }) {
                    selectedConversationId = nil
                }

                resolvePendingScanNavigationIfPossible()
                resolvePendingConnectionGrantIfPossible()

                if !conversations.contains(where: { !$0.isPinned && $0.kind == .group }) {
                    activeFilter = .all
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let conversation = self.selectedConversationViewModel?.conversation {
                    self.markConversationAsRead(conversation)
                } else if let conversation = self.newConversationViewModel?.conversationViewModel?.conversation {
                    self.markConversationAsRead(conversation)
                }
            }
            .store(in: &cancellables)
    }

    private func handleConversationNotificationTap(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let inboxId = userInfo["inboxId"] as? String,
              let conversationId = userInfo["conversationId"] as? String else {
            Log.warning("Conversation notification tapped but missing required userInfo")
            return
        }

        Log.info(
            "Handling conversation notification tap for inboxId: \(inboxId), conversationId: \(conversationId)"
        )

        if let conversation = conversations.first(where: { $0.id == conversationId }) {
            Log.info("Found conversation, selecting it")
            selectedConversation = conversation
        } else {
            Log.warning("Conversation \(conversationId) not found in current conversation list")
        }
    }

    func toggleMute(conversation: Conversation) {
        let conversationId = conversation.id
        let currentlyMuted = conversation.isMuted

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = session.messagingService()
                let shouldEnableNotifications = currentlyMuted
                try await messagingService.setConversationNotificationsEnabled(shouldEnableNotifications, for: conversationId)
            } catch {
                Log.error("Failed toggling mute for conversation \(conversationId): \(error.localizedDescription)")
            }
        }
    }

    func toggleReadState(conversation: Conversation) {
        let conversationId = conversation.id
        let currentlyUnread = conversation.isUnread

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = session.messagingService()
                let writer = messagingService.conversationLocalStateWriter()
                try await writer.setUnread(!currentlyUnread, for: conversationId)
            } catch {
                Log.error("Failed toggling read state for conversation \(conversationId): \(error.localizedDescription)")
            }
        }
    }

    func togglePin(conversation: Conversation) {
        let conversationId = conversation.id
        let currentlyPinned = conversation.isPinned

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = session.messagingService()
                let writer = messagingService.conversationLocalStateWriter()
                try await writer.setPinned(!currentlyPinned, for: conversationId)
            } catch ConversationLocalStateWriterError.pinLimitReached {
                await MainActor.run {
                    self.presentingPinLimitInfo = true
                }
            } catch {
                Log.error("Failed toggling pin for conversation \(conversationId): \(error.localizedDescription)")
            }
        }
    }

    /// Ends the selected host conversation's invite session on a real
    /// pop-to-home and mirrors the flipped flag into the in-memory list.
    /// The persist is async (GRDB); without the mirror, an instant re-entry
    /// builds the next detail view model from the stale list row and the big
    /// inline Invite/Scan card flashes until the write round-trips.
    func endHostedInviteSessionOnPop() {
        guard let detailViewModel = selectedConversationViewModel else { return }
        detailViewModel.markInviteSessionEndedIfHosting()
        let endedConversation = detailViewModel.conversation
        guard endedConversation.leftHostedInviteSession,
              let index = conversations.firstIndex(where: { $0.id == endedConversation.id }) else { return }
        conversations[index] = endedConversation
    }

    private func markConversationAsRead(_ conversation: Conversation) {
        let conversationId = conversation.id

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = session.messagingService()
                let writer = messagingService.conversationLocalStateWriter()
                try await writer.setUnread(false, for: conversationId)
            } catch {
                Log.warning("Failed marking conversation as read: \(error.localizedDescription)")
            }
        }
    }

    func explodeConversation(_ conversation: Conversation) {
        let conversationId = conversation.id
        let memberInboxIds = conversation.members.map { $0.profile.inboxId }

        hiddenConversationIds.insert(conversationId)
        if selectedConversation == conversation {
            selectedConversation = nil
        }
        conversations.removeAll { $0.id == conversationId }

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = session.messagingService()
                let explosionWriter = messagingService.conversationExplosionWriter()
                try await explosionWriter.explodeConversation(
                    conversationId: conversationId,
                    memberInboxIds: memberInboxIds
                )

                await UNUserNotificationCenter.current().addExplosionNotification(
                    conversationId: conversationId,
                    displayName: conversation.displayName
                )

                NotificationCenter.default.post(
                    name: .conversationExpired,
                    object: nil,
                    userInfo: ["conversationId": conversationId]
                )
                conversation.postLeftConversationNotification()
                self.hiddenConversationIds.remove(conversationId)
                Log.info("Exploded conversation from list: \(conversationId)")
            } catch {
                self.hiddenConversationIds.remove(conversationId)
                Log.error("Error exploding conversation from list: \(error.localizedDescription)")
            }
        }
    }

    func scheduleConversationExplosion(_ conversation: Conversation, at expiresAt: Date) {
        guard conversation.scheduledExplosionDate == nil else {
            Log.warning("Conversation \(conversation.id) already has a scheduled explosion")
            return
        }

        if expiresAt <= Date() {
            explodeConversation(conversation)
            return
        }

        let conversationId = conversation.id

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = session.messagingService()
                let explosionWriter = messagingService.conversationExplosionWriter()
                try await explosionWriter.scheduleExplosion(
                    conversationId: conversationId,
                    expiresAt: expiresAt
                )
                Log.info("Scheduled explosion from list for conversation: \(conversationId) at \(expiresAt)")
            } catch {
                Log.error("Error scheduling explosion from list: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Device Pairing

extension ConversationsViewModel {
    /// Builds a joiner-side pairing sheet VM with the session callbacks
    /// shared by both entry points: the `/pair/<slug>` deep link and the
    /// first-install iCloud-discovery prompt.
    func makeJoinerPairingViewModel(
        pairingId: String,
        expiresAt: Date?,
        initiatorName: String?,
        timeoutInterval: TimeInterval = 60,
        connectingMessage: String? = nil,
        resendJoinRequestInterval: TimeInterval? = nil
    ) -> JoinerPairingSheetViewModel {
        JoinerPairingSheetViewModel(
            pairingId: pairingId,
            expiresAt: expiresAt,
            initiatorName: initiatorName,
            timeoutInterval: timeoutInterval,
            connectingMessage: connectingMessage,
            resendJoinRequestInterval: resendJoinRequestInterval,
            pairingService: session.joinerPairingService(),
            onPairingAdopted: { [weak self] in
                await self?.session.refreshAfterPairingCompleted()
            },
            onApplyAdoptedProfile: { [weak self] displayName, imageAssetIdentifier in
                // The joiner just adopted the initiator's identity, so
                // it shouldn't be asked to onboard a profile from
                // scratch. Three side-effects in order:
                //   1. Seed DBMyProfile from the share payload (may fail).
                //   2. Re-bind the shared profile VM unconditionally.
                //      Identity adoption already happened, so the
                //      VM's cached writer / repository for the
                //      placeholder session are stale either way — a
                //      failed seed doesn't reverse the adoption, and
                //      leaving the VM bound to the now-stopped
                //      MessagingService risks crashes on subsequent
                //      profile operations.
                //   3. Flip global onboarding flags *only* on a
                //      successful seed, so a failed save doesn't
                //      permanently suppress prompts under an empty
                //      DBMyProfile.
                guard let session = self?.session else { return }
                var seeded: Bool = false
                do {
                    // The writer drops `imageAssetIdentifier` when
                    // `imageData` is nil, and that is correct here: the
                    // identifier is a PhotoKit local identifier scoped to
                    // the initiator's photo library and cannot resolve on
                    // this device, and the identity share carries no image
                    // bytes. Persisting it would only hand the photo
                    // picker a dangling reference. The avatar itself
                    // arrives later through per-conversation profile
                    // snapshots.
                    try await session.messagingService().myGlobalProfileWriter().save(
                        name: displayName,
                        imageData: nil,
                        imageAssetIdentifier: imageAssetIdentifier,
                        metadata: nil
                    )
                    // Propagate the adopted profile through the canonical
                    // repository so it fans out to every conversation via
                    // the durable publisher. No image bytes are available on
                    // the adoption path, so only the display name is sent.
                    try await session.messagingService().profilesRepository().publishMyProfile(
                        displayName: displayName,
                        avatarBytes: nil,
                        priorityConversationId: nil
                    )
                    seeded = true
                } catch {
                    Log.warning("Pairing: failed to seed DBMyProfile after adoption: \(error)")
                }
                ProfileSettingsViewModel.shared.rebind(session: session)
                // Only suppress profile onboarding when the adopted
                // payload actually carried a usable profile. A nil or
                // empty display name means the initiator never set one
                // up, and the joiner would otherwise be stranded as
                // "Somebody" with the prompt permanently suppressed.
                // (The asset identifier alone doesn't count: it's a
                // PhotoKit id from the initiator's library and can't
                // resolve here.)
                let adoptedUsableProfile = displayName?.isEmpty == false
                if seeded && adoptedUsableProfile {
                    ConversationOnboardingCoordinator.markCompletedForPairedDevice()
                }
            },
            onDeleteExistingData: { [weak self] in
                try await self?.session.deleteAllInboxes()
            },
            checkHasExistingData: { [weak self] in
                guard let session = self?.session else { return false }
                return await session.hasAnyUsedConversations()
            }
        )
    }

    private static let hasDeclinedFoundDevicePairingKey: String = "hasDeclinedFoundDevicePairing"
    private var hasDeclinedFoundDevicePairing: Bool {
        get {
            UserDefaults.standard.bool(forKey: Self.hasDeclinedFoundDevicePairingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.hasDeclinedFoundDevicePairingKey)
        }
    }

    /// First-install check for another device's identity in the
    /// iCloud-synced keychain backup. Runs once per launch from
    /// `onAppear`; re-running on later launches covers iCloud Keychain's
    /// sync latency (a backup that hadn't synced yet on first launch).
    ///
    /// Deliberately not gated on local "engagement" signals:
    /// fresh-install bootstrap pollutes all of them with zero user
    /// interaction (`hasAnyUsedConversations()` flips once the inline
    /// agent builder's auto-claimed draft commits on first termination,
    /// and the conversations count includes the hidden prewarmed convo),
    /// which would permanently suppress the prompt from the second launch
    /// on. The prompt therefore shows whenever another identity's backup
    /// predating this install's own key exists and the user hasn't
    /// declined (newer backups are never offered - installing on a second
    /// device must not make the first offer to demote itself; see
    /// `PairableDeviceBackup.pairableBackups`). Data on an established
    /// install stays safe because the joiner flow runs its own
    /// hold-to-erase guard before anything destructive.
    func checkForPairableDeviceIfNeeded() {
        guard !didCheckForPairableDevice else { return }
        didCheckForPairableDevice = true
        guard !hasDeclinedFoundDevicePairing else { return }
        Task { [weak self] in
            guard let self else { return }
            let backups = await self.session.pairableDeviceBackups()
            QAEvent.emit(.pairing, "found_device_check", ["pairableCount": "\(backups.count)"])
            guard let newest = backups.first else {
                // No other identity in iCloud, so pairing will never be
                // offered - this is the moment first-launch profile setup
                // becomes eligible.
                await self.presentFirstLaunchProfileSetupIfNeeded()
                return
            }
            // Don't fight an in-flight deep-link pairing flow - but
            // un-latch so the next chats-list appearance re-offers the
            // prompt once that flow ends. Without the reset, a launch
            // that starts with a /pair deep link would suppress the
            // found-device prompt for the whole session even if the
            // deep-link flow is abandoned.
            guard self.pendingJoinerPairing == nil, self.foundDevicePairingPrompt == nil else {
                self.didCheckForPairableDevice = false
                return
            }
            self.foundDevicePairingPrompt = FoundDevicePairingPrompt(
                inboxId: newest.inboxId,
                deviceName: newest.deviceName
            )
            QAEvent.emit(.pairing, "found_device_prompt_shown", [
                "inboxId": newest.inboxId,
                "deviceName": newest.deviceName ?? ""
            ])
        }
    }

    /// Launch profile setup: shows the "Hello / My name is" sheet whenever
    /// the user has no name or profile photo set — including users who went
    /// through onboarding before this sheet existed — instead of the
    /// in-conversation "Add your name and pic" prompt. Once per launch (the
    /// caller's check latch). Only reached when
    /// `checkForPairableDeviceIfNeeded` found no other identity in the
    /// iCloud-synced keychain backup, so it can never race the found-device
    /// pairing prompt; the explicit pairing guards below cover deep-link
    /// and incoming pairing flows.
    private func presentFirstLaunchProfileSetupIfNeeded() async {
        guard pendingJoinerPairing == nil,
              foundDevicePairingPrompt == nil,
              incomingPairingRequest == nil else { return }
        // Fast path: this launch registered a brand-new identity (empty
        // keychain), so there is provably no profile to wait for - present
        // immediately so the sheet really is the first thing a new user
        // sees.
        if await session.registeredFreshIdentityThisLaunch() {
            // Re-check the pairing guards: a deep-link pairing flow can
            // start while the await above is suspended.
            guard pendingJoinerPairing == nil,
                  foundDevicePairingPrompt == nil,
                  incomingPairingRequest == nil else { return }
            presentingFirstLaunchProfileSetup = true
            QAEvent.emit(.onboarding, "first_launch_profile_sheet_shown", ["path": "fresh_install"])
            return
        }
        // An identity was restored (e.g. delete + reinstall keeps the
        // keychain): don't decide on an unloaded snapshot - the profile
        // only arrives once the rebuilt inbox is ready, which can far
        // exceed a fixed timeout. Wait for however long the load takes;
        // the QA event marks launches where it ran long.
        var profileLoaded = await ProfileSettingsViewModel.shared.waitForProfileLoad(
            timeout: Constant.firstLaunchProfileLoadTimeout
        )
        if !profileLoaded {
            QAEvent.emit(.onboarding, "first_launch_profile_sheet_load_timeout")
            while !profileLoaded {
                profileLoaded = await ProfileSettingsViewModel.shared.waitForProfileLoad(
                    timeout: Constant.firstLaunchProfileLoadTimeout
                )
            }
        }
        // A profile already exists (name or photo): never show.
        guard ProfileSettingsViewModel.shared.profileSettings.isDefault else { return }
        // Re-check the pairing guards: a deep-link pairing flow may have
        // started while we awaited the profile load.
        guard pendingJoinerPairing == nil,
              foundDevicePairingPrompt == nil,
              incomingPairingRequest == nil else { return }
        presentingFirstLaunchProfileSetup = true
        QAEvent.emit(.onboarding, "first_launch_profile_sheet_shown")
    }

    /// Primary action of the prompt sheet: dismisses the prompt
    /// immediately, mints a pairing invite signed by the found device's
    /// backed-up key (so the standard joiner flow can target it as the
    /// main device), then presents the joiner flow.
    ///
    /// The prompt is nil'ed synchronously, before the mint Task, so a
    /// rapid second tap finds it nil and bails - concurrent mints would
    /// each build a `JoinerPairingSheetViewModel` whose notification
    /// observers stay live even on the orphaned loser, double-handling
    /// pairing messages. Minting and the dismissal animation then race
    /// in both directions; whichever finishes second performs the
    /// promotion (promoting while the prompt sheet is still animating
    /// out can drop the new presentation).
    func pairWithFoundDevice() {
        guard let prompt = foundDevicePairingPrompt else { return }
        foundDevicePromptDismissalComplete = false
        foundDevicePairingPrompt = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let expiresAt = Date().addingTimeInterval(Constant.foundDevicePairingWindow)
                let slug = try await self.session.pairingInviteSlug(
                    forBackupInboxId: prompt.inboxId,
                    expiresAt: expiresAt
                )
                let deviceLabel = prompt.deviceName ?? "your other device"
                self.preparedFoundDevicePairing = self.makeJoinerPairingViewModel(
                    pairingId: slug,
                    expiresAt: expiresAt,
                    initiatorName: prompt.deviceName,
                    // Match the initiator sheet's window. The PIN-entry
                    // countdown rebases to this on PIN arrival; the
                    // deep-link flow's 60s is tight when the user is
                    // juggling two devices they didn't stage in advance.
                    timeoutInterval: Constant.foundDevicePairingStageTimeout,
                    connectingMessage: "Open Convos on \"\(deviceLabel)\" to continue pairing.",
                    resendJoinRequestInterval: Constant.foundDevicePairingResendInterval
                )
                QAEvent.emit(.pairing, "found_device_invite_minted", ["inboxId": prompt.inboxId])
            } catch {
                Log.error("Failed to mint pairing invite from synced backup: \(error)")
                // Re-arm the once-per-launch check so a later chats-list
                // appearance offers the prompt again; with the latch left
                // set, a transient keychain/signing failure would strand
                // the user until the next app launch with no retry path.
                self.didCheckForPairableDevice = false
            }
            if self.foundDevicePromptDismissalComplete {
                self.promotePreparedFoundDevicePairing()
            }
            // Otherwise the sheet is still animating out; onDismiss
            // promotes when it completes.
        }
    }

    /// Secondary action of the prompt sheet. Persistent: once skipped,
    /// the prompt never comes back (until app data is reset).
    func skipFoundDevicePairing() {
        hasDeclinedFoundDevicePairing = true
        foundDevicePairingPrompt = nil
        QAEvent.emit(.pairing, "found_device_prompt_skipped")
    }

    /// Called when the prompt sheet finishes dismissing; presents the
    /// joiner pairing flow prepared by `pairWithFoundDevice()` if the
    /// mint already finished (no-op for Skip / swipe-away dismissals).
    func onFoundDevicePromptDismissed() {
        foundDevicePromptDismissalComplete = true
        promotePreparedFoundDevicePairing()
    }

    private func promotePreparedFoundDevicePairing() {
        guard let prepared = preparedFoundDevicePairing else { return }
        preparedFoundDevicePairing = nil
        // A /pair deep link may have claimed the slot while the
        // found-device invite was minting; replacing it mid-flight would
        // drop the user into the wrong pairing session. Yield to it and
        // tear down the prepared flow's ephemeral client instead.
        guard pendingJoinerPairing == nil else {
            prepared.cancel()
            return
        }
        pendingJoinerPairing = prepared
    }

    // MARK: Incoming Pairing Requests (initiator side)

    /// Auto-surfaces the initiator pairing flow when a verified join
    /// request arrives on the main message stream (posted by
    /// `StreamProcessor` after checking the slug signature against this
    /// device's own identity key). Foregrounded: present the PIN sheet
    /// immediately. Otherwise: stash the request and raise a local
    /// notification; the stash is redeemed on the next activation.
    private func observeIncomingPairingRequests() {
        incomingPairingObservers.add(for: .pairingDidReceiveVerifiedJoinRequest) { [weak self] notification in
            guard let joinerInboxId = notification.userInfo?["joinerInboxId"] as? String,
                  let deviceName = notification.userInfo?["deviceName"] as? String else { return }
            Task { @MainActor in
                self?.handleVerifiedJoinRequest(joinerInboxId: joinerInboxId, deviceName: deviceName)
            }
        }
        incomingPairingObservers.add(for: UIApplication.didBecomeActiveNotification) { [weak self] _ in
            Task { @MainActor in
                self?.presentPendingIncomingPairRequestIfNeeded()
            }
        }
    }

    /// Whether a new auto-surfaced initiator sheet may be presented,
    /// recovering from dropped presentations along the way. False while
    /// another initiator flow owns (or is about to own) the exchange - a
    /// second coordinator would race PIN generation for the same joiner.
    ///
    /// The sheet sets `PairingSheetViewModel.active` from its `.task` the
    /// moment it actually presents. A request that has sat un-presented
    /// well past that point means SwiftUI dropped the presentation
    /// (another sheet was up when it was assigned); without the reset the
    /// stale reference would block every resend - and the NSE stash - until
    /// app restart.
    private func canSurfaceIncomingPairingRequest() -> Bool {
        guard !PairingSheetViewModel.isFlowActiveOrStarting else { return false }
        guard incomingPairingRequest != nil else { return true }
        guard let presentedAt = incomingPairingPresentedAt,
              Date().timeIntervalSince(presentedAt) > Constant.incomingPairingPresentationGrace else {
            return false
        }
        Log.warning("Incoming pairing sheet never presented; resetting and retrying")
        incomingPairingRequest = nil
        incomingPairingPresentedAt = nil
        return true
    }

    private func handleVerifiedJoinRequest(joinerInboxId: String, deviceName: String) {
        // The joiner re-sends its request every few seconds, so one
        // dropped here (another flow active, stale sheet inside its
        // grace window) is recovered as soon as the active flow ends.
        guard canSurfaceIncomingPairingRequest() else { return }
        if UIApplication.shared.applicationState == .active {
            presentIncomingPairingSheet(joinerInboxId: joinerInboxId, deviceName: deviceName)
        } else {
            // Latch the banner per joiner: the resend cadence would
            // otherwise re-alert every few seconds while backgrounded.
            // The stash still refreshes so the staleness window keys
            // off the latest resend, not the first.
            let alreadyNotified = pendingIncomingPairRequest?.joinerInboxId == joinerInboxId
            pendingIncomingPairRequest = PendingIncomingPairRequest(
                joinerInboxId: joinerInboxId,
                deviceName: deviceName,
                receivedAt: Date()
            )
            if !alreadyNotified {
                scheduleIncomingPairingNotification(deviceName: deviceName)
            }
        }
    }

    private func presentIncomingPairingSheet(joinerInboxId: String, deviceName: String) {
        QAEvent.emit(.pairing, "incoming_request_surfaced", ["joinerInboxId": joinerInboxId])
        // The NSE stashes for pushes that arrive while the app is
        // foregrounded too; presenting from the stream path must discard
        // that stash (and any delivered banners), or the next activation
        // would re-present a ghost PIN sheet for an already-handled
        // request.
        _ = PendingPairRequestStore.consumePending(
            appGroup: ConfigManager.shared.currentEnvironment.appGroupIdentifier
        )
        removeDeliveredPairingNotifications()
        incomingPairingPresentedAt = Date()
        incomingPairingRequest = PairingSheetViewModel(
            pairingService: DeferredInitiatorPairingService(session: session),
            mode: .respondToJoinRequest(joinerInboxId: joinerInboxId, deviceName: deviceName),
            appGroupIdentifier: ConfigManager.shared.currentEnvironment.appGroupIdentifier
        )
    }

    private func presentPendingIncomingPairRequestIfNeeded() {
        // Bail before consuming anything when a pairing flow is already
        // on screen (the shared helper also recovers a stale
        // never-presented sheet first, so a dropped presentation can't
        // strand the stash). Consuming first and bailing after would
        // destructively drop the stash (the app-group read removes it),
        // losing the request if the joiner has stopped re-sending
        // (killed/backgrounded). Leave it stashed so the next activation,
        // once the active flow ends, can present it.
        guard canSurfaceIncomingPairingRequest() else { return }
        // Two stash sources: in-memory (request arrived while this
        // process was backgrounded) and the app-group store written by
        // the NSE (request arrived while the app wasn't running at all).
        var pending: PendingIncomingPairRequest?
        if let inMemory = pendingIncomingPairRequest {
            pendingIncomingPairRequest = nil
            pending = inMemory
        } else if let stashed = PendingPairRequestStore.consumePending(
            appGroup: ConfigManager.shared.currentEnvironment.appGroupIdentifier
        ) {
            pending = PendingIncomingPairRequest(
                joinerInboxId: stashed.joinerInboxId,
                deviceName: stashed.deviceName,
                receivedAt: stashed.receivedAt
            )
        }
        guard let pending else { return }
        removeDeliveredPairingNotifications()
        // A live joiner's resend loop keeps refreshing receivedAt, so a
        // fresh stash means an active handshake. Cap the surfacing window
        // at the shortest supported invite lifetime (the QR flow's 120s)
        // rather than the iCloud flow's 300s: the stash doesn't carry the
        // slug (deliberately, it's a bearer credential), so the invite's
        // actual expiry can't be re-checked here and a longer window
        // could present a PIN sheet for an invite that already expired.
        guard Date().timeIntervalSince(pending.receivedAt) < Constant.stashedPairRequestWindow else { return }
        presentIncomingPairingSheet(joinerInboxId: pending.joinerInboxId, deviceName: pending.deviceName)
    }

    /// Removes every delivered "is requesting to pair" banner: the app's
    /// own local one (fixed request identifier) and any the NSE produced
    /// for remote pushes, whose request identifiers are system-assigned
    /// and only findable via the shared pairing thread identifier.
    private func removeDeliveredPairingNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let pairingIds = notifications
                .filter { $0.request.content.threadIdentifier == PairingNotificationThread.identifier }
                .map(\.request.identifier)
            let ids = pairingIds + [Constant.incomingPairingNotificationId]
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private func scheduleIncomingPairingNotification(deviceName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pair new device"
        content.body = "\"\(deviceName)\" is requesting to pair"
        content.sound = .default
        content.threadIdentifier = PairingNotificationThread.identifier
        let request = UNNotificationRequest(
            identifier: Constant.incomingPairingNotificationId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.warning("Failed to schedule pairing request notification: \(error)")
            }
        }
    }

    /// Dismissal hook for the joiner pairing sheet (interactive and
    /// programmatic): tears down the ephemeral pairing client before the
    /// reference drops. Safe on every terminal state - the joiner-side
    /// `cancel()` signals nothing to the peer and the service stop is
    /// idempotent, so a completed flow just gets its temp client wiped.
    func dismissJoinerPairing() {
        pendingJoinerPairing?.cancel()
        pendingJoinerPairing = nil
        pendingPairDevice = nil
    }

    /// Sheet-dismissal hook for the auto-surfaced initiator flow. Also
    /// discards any stash the NSE wrote for resends that landed while
    /// the sheet was up - the request was handled either way, and a
    /// leftover stash would re-present a ghost sheet on next activation.
    func dismissIncomingPairingRequest() {
        incomingPairingRequest?.triggerCancel()
        incomingPairingRequest = nil
        incomingPairingPresentedAt = nil
        _ = PendingPairRequestStore.consumePending(
            appGroup: ConfigManager.shared.currentEnvironment.appGroupIdentifier
        )
        removeDeliveredPairingNotifications()
    }

    private enum Constant {
        /// Validity window for an invite minted from an iCloud backup.
        /// Longer than the QR flow's window because the user still has to
        /// fetch the other device and open the app on it.
        static let foundDevicePairingWindow: TimeInterval = 300
        /// Cadence for re-sending the join request while connecting. The
        /// found device only sees requests that arrive while its app is
        /// streaming, so the first send is almost always too early.
        static let foundDevicePairingResendInterval: TimeInterval = 5
        /// How old a stashed join request may be and still be surfaced on
        /// activation. Matches the shortest invite lifetime (QR flow,
        /// 120s) because the stash can't re-check the invite's own expiry.
        static let stashedPairRequestWindow: TimeInterval = 120
        /// Per-stage (PIN entry, emoji confirmation) window, matching the
        /// initiator sheet's 120s.
        static let foundDevicePairingStageTimeout: TimeInterval = 120
        /// Fixed identifier so a joiner's resend burst replaces (not
        /// stacks) the "is requesting to pair" local notification.
        static let incomingPairingNotificationId: String = "incoming-pairing-request"
        /// How long an assigned `incomingPairingRequest` may sit without
        /// the sheet's `.task` firing before the watchdog concludes the
        /// presentation was dropped. Generous against slow presentation
        /// animations; tiny against the 5s resend cadence that retries.
        static let incomingPairingPresentationGrace: TimeInterval = 3
        /// How long first-launch profile setup waits for the global
        /// profile to load before giving up for this launch. Matches
        /// `ConversationOnboardingCoordinator.profileLoadTimeout`.
        static let firstLaunchProfileLoadTimeout: TimeInterval = 10
    }
}

/// A verified join request that arrived while the app wasn't active,
/// awaiting presentation on the next foreground.
private struct PendingIncomingPairRequest {
    let joinerInboxId: String
    let deviceName: String
    let receivedAt: Date
}

extension ConversationsViewModel {
    /// Dismisses the scanner sheet and navigates into the conversation a scan
    /// resolved to, reusing the canonical `selectedConversationId` selection the
    /// list uses. Deferred one hop so it runs after the presenting VM's `.ready`
    /// handler unwinds (nil-ing the sheet there would tear down a VM mid-call).
    /// The just-joined row may not be in `conversations` yet, so it's parked and
    /// resolved by the conversations publisher once the row lands.
    /// The landing point for every scan entry (home scanner, Contacts-tab
    /// sheets, the shared toolbar scan on any tab): it asks the shell to bring
    /// the Chats tab frontmost, and the parked id is consumed only once that
    /// switch has committed.
    func navigateToScannedConversation(_ conversationId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingScanNavigationConversationId = conversationId
            self.newConversationViewModel = nil
            self.bringChatsTabToFront?()
            self.resolvePendingScanNavigationIfPossible()
        }
    }

    /// Selects the parked scan-navigation target once its row exists in the list.
    /// Called after the sheet dismiss, whenever the conversations list updates,
    /// and when the Chats tab becomes frontmost. Selecting drives the same
    /// `navigationDestination` push a list tap does; the metrics navigator fires
    /// via the `selectedConversationId` onChange.
    /// Consuming is gated on the Chats tab being frontmost: selecting from any
    /// other tab would hide the tab bar and float the conversation indicator
    /// over that tab while the push mounts in the background Chats stack, an
    /// unrecoverable hybrid screen. When gated, the id stays parked and the
    /// shell is asked to switch; the `isChatsTabActive` observer re-runs this
    /// once the switch lands.
    func resolvePendingScanNavigationIfPossible() {
        guard let pendingId = pendingScanNavigationConversationId,
              conversations.contains(where: { $0.id == pendingId }) else { return }
        guard isChatsTabActive else {
            bringChatsTabToFront?()
            return
        }
        pendingScanNavigationConversationId = nil
        selectedConversationId = pendingId
    }

    static var mock: ConversationsViewModel {
        let client = ConvosClient.mock()
        return .init(session: client.session)
    }

    static func preview(conversations: [Conversation]) -> ConversationsViewModel {
        let client = ConvosClient.mock()
        let vm = ConversationsViewModel(session: client.session)
        vm.conversations = conversations
        vm.hasLoadedInitialConversations = true
        return vm
    }
}

// MARK: - Initial Prime

/// Bounded-deadline first load, in an extension to keep the class body
/// under the type-body-length limit. `init` used to fetch the list and
/// count synchronously on the main thread, which hung the UI whenever a
/// conversation's last-message row carried a huge text payload or the
/// SQLite page cache was contended by a background writer (Sentry
/// CONVOS-IOS-4A). In the common case the read finishes inside the
/// deadline and the list is populated in the first rendered frame,
/// exactly as before; otherwise the result is applied when the read
/// lands, and the repository publishers in `observe()` remain the source
/// of truth either way.
extension ConversationsViewModel {
    fileprivate struct InitialPrime {
        let conversations: [Conversation]?
        let count: Int?
    }

    fileprivate func primeInitialConversations() {
        // The reads are pure GRDB pool reads and thread-safe; the
        // existentials just aren't Sendable.
        nonisolated(unsafe) let primeRepository = conversationsRepository
        nonisolated(unsafe) let primeCountRepository = conversationsCountRepository
        let primed: InitialPrime? = BoundedInitialRead.prime(read: {
            var fetched: [Conversation]?
            var count: Int?
            do {
                fetched = try primeRepository.fetchAll()
            } catch {
                // Distinguish a failed read from a merely slow one: the
                // deadline-miss log alone would hide real database errors.
                Log.error("Initial conversations prime failed: \(error.localizedDescription)")
            }
            do {
                count = try primeCountRepository.fetchCount()
            } catch {
                Log.error("Initial conversations count prime failed: \(error.localizedDescription)")
            }
            return InitialPrime(conversations: fetched, count: count)
        }, late: { [weak self] payload in
            self?.applyInitialPrime(payload, deliveredLate: true)
        })
        if let primed {
            applyInitialPrime(primed, deliveredLate: false)
        } else {
            Log.info("[PERF] ConversationsViewModel: initial conversations read missed the first-frame deadline; applying when it completes")
        }
    }

    private func applyInitialPrime(_ prime: InitialPrime, deliveredLate: Bool) {
        if prime.conversations != nil {
            // The read succeeded, so the database state is known even when
            // the snapshot below is discarded in favor of a publisher
            // emission that arrived first.
            hasLoadedInitialConversations = true
        }
        if let fetched = prime.conversations {
            // On the late path the conversations publisher may have emitted
            // already; it is the source of truth, so never replace its
            // emission with this older snapshot. An emission can legitimately
            // be an empty list (the last conversation was just deleted), so
            // check the explicit flag rather than inferring from the data.
            if !deliveredLate || (!conversationsObservationHasEmitted && conversations.isEmpty) {
                conversations = fetched
                resolvePendingConnectionGrantIfPossible()
            }
        }
        // Assigning the count latches hasCreatedMoreThanOneConvo via its
        // didSet, matching what the old synchronous init fetch did.
        if let count = prime.count, !deliveredLate || (!conversationsCountObservationHasEmitted && conversationsCount == 0) {
            conversationsCount = count
        }
    }

    private func openConnectionGrant(serviceId: String, conversationId: String) {
        // Discard any older parked link so it cannot fire later and yank the
        // user away from the grant that is being handled now.
        pendingConnectionGrantLink = nil
        _selectedConversationId = conversationId
        pendingGrantRequest = PendingGrantRequest(
            serviceId: serviceId,
            conversationId: conversationId
        )
    }

    fileprivate func resolvePendingConnectionGrantIfPossible() {
        guard let link = pendingConnectionGrantLink,
              conversations.contains(where: { $0.id == link.conversationId }) else { return }
        pendingConnectionGrantLink = nil
        openConnectionGrant(serviceId: link.serviceId, conversationId: link.conversationId)
    }
}
