import Combine
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
    /// The claimed conversation backing the Compose flow. Created upfront by
    /// `onStartConvo()` (mode `.newConversation`, which claims a warm-cached
    /// conversation that already has an invite) so the contacts picker can
    /// show that conversation's convo code in its empty state, and reused as
    /// the destination the picker pushes on Skip / Continue. Cleared (and
    /// torn down if it stayed empty) by `endComposeFlow()`.
    var composeConversationViewModel: NewConversationViewModel? {
        didSet {
            oldValue?.cleanUpIfNeeded()
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
    /// Drives the Compose flow sheet: the contacts picker is the root and
    /// the claimed `composeConversationViewModel` is pushed onto it on Skip /
    /// Continue. Distinct from `newConversationViewModel` (scanner / join /
    /// template), so the two never drive overlapping presentations.
    var presentingComposeFlow: Bool = false

    /// Honk-style focus-mode prototype (Assistant Builder). Distinct from
    /// `agentBuilderViewModel`, which drives the production Agent Builder.
    var assistantBuilderViewModel: AssistantBuilderViewModel?
    var presentingExplodeInfo: Bool = false
    var presentingPinLimitInfo: Bool = false

    var conversations: [Conversation] = []
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
    /// the bottom chrome.
    var isEmptyCTAActive: Bool {
        unpinnedConversations.isEmpty
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
        do {
            self.conversations = try conversationsRepository.fetchAll()
            self.conversationsCount = try conversationsCountRepository.fetchCount()
            if conversationsCount > 1 {
                hasCreatedMoreThanOneConvo = true
            }
        } catch {
            Log.error("Error fetching conversations: \(error)")
            self.conversations = []
            self.conversationsCount = 0
        }
        observe()
    }

    func updateHorizontalSizeClass(_ sizeClass: UserInterfaceSizeClass?) {
        guard horizontalSizeClass != sizeClass else { return }
        horizontalSizeClass = sizeClass
        focusCoordinator.horizontalSizeClass = sizeClass
    }

    func onAppear() {
        isVisible = true
        updateListVisibility()
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
                Log.warning("Dropping connection grant deep link for unknown conversationId")
                return
            }
            _selectedConversationId = conversationId
            pendingGrantRequest = PendingGrantRequest(
                serviceId: serviceId,
                conversationId: conversationId
            )
        case let .pairDevice(pairingId, expiresAt, initiatorName):
            pendingPairDevice = PendingPairDevice(
                pairingId: pairingId,
                expiresAt: expiresAt,
                initiatorName: initiatorName
            )
            let capturedSession = session
            pendingJoinerPairing = JoinerPairingSheetViewModel(
                pairingId: pairingId,
                expiresAt: expiresAt,
                initiatorName: initiatorName,
                pairingService: capturedSession.joinerPairingService(),
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
                        try await session.messagingService().myGlobalProfileWriter().save(
                            name: displayName,
                            imageData: nil,
                            imageAssetIdentifier: imageAssetIdentifier,
                            metadata: nil
                        )
                        seeded = true
                    } catch {
                        Log.warning("Pairing: failed to seed DBMyProfile after adoption: \(error)")
                    }
                    ProfileSettingsViewModel.shared.rebind(session: session)
                    if seeded {
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
        case .agentTemplate(templateId: let templateId):
            startConversation(withAgentTemplateId: templateId)
        }
    }

    /// Compose opens the contacts picker first (optional selection), then
    /// pushes the conversation on Skip / Continue (`ComposeFlowView`). With no
    /// contacts to pick from, the picker would be pointless -- so we skip it
    /// and open the new-conversation view directly, like the pre-picker flow.
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
        composeConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .newConversation,
            coreActions: coreActions
        )
        presentingComposeFlow = true
    }

    /// Tears down the Compose flow when its sheet is dismissed. Clearing
    /// `composeConversationViewModel` runs its `didSet` cleanup (which keeps a
    /// conversation that already has content / members and discards an empty
    /// claimed draft).
    func endComposeFlow() {
        presentingComposeFlow = false
        composeConversationViewModel = nil
    }

    func onJoinConvo() {
        newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .scanner,
            coreActions: coreActions
        )
    }

    func onStartAssistantBuilder() {
        assistantBuilderViewModel = AssistantBuilderViewModel(session: session)
    }

    /// Pairs with `onStartAssistantBuilder` for the second human in the convo —
    /// reads an invite from the system pasteboard and opens the Assistant
    /// Builder view in join-by-invite mode. Use when one sim creates the
    /// convo (hammer button) and copies the invite link from the `+` menu, then
    /// the other sim pastes via this button to participate in the live focus
    /// session as a peer typer (not as the focused assistant).
    func onPasteAssistantBuilderInvite() {
        let raw = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let inviteCode: String
        if let url = URL(string: raw),
           let destination = DeepLinkHandler.destination(for: url),
           case .joinConversation(let code) = destination {
            inviteCode = code
        } else {
            inviteCode = raw
        }
        guard !inviteCode.isEmpty else { return }
        assistantBuilderViewModel = AssistantBuilderViewModel(
            session: session,
            joiningInviteCode: inviteCode
        )
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
                self?.conversationsCount = conversationsCount
            }
            .store(in: &cancellables)
        conversationsRepository.conversationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                guard let self else { return }
                self.conversations = hiddenConversationIds.isEmpty
                    ? conversations
                    : conversations.filter { !hiddenConversationIds.contains($0.id) }

                if let selectedId = _selectedConversationId,
                   !conversations.contains(where: { $0.id == selectedId }) {
                    selectedConversationId = nil
                }

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

extension ConversationsViewModel {
    static var mock: ConversationsViewModel {
        let client = ConvosClient.mock()
        return .init(session: client.session)
    }

    static func preview(conversations: [Conversation]) -> ConversationsViewModel {
        let client = ConvosClient.mock()
        let vm = ConversationsViewModel(session: client.session)
        vm.conversations = conversations
        return vm
    }
}
