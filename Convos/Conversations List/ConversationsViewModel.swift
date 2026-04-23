import Combine
import ConvosCore
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

    // Single source of truth for selection
    @ObservationIgnored
    private var _selectedConversationId: String? {
        didSet {
            updateSelectionState()
        }
    }

    // for selection binding
    var selectedConversationId: Conversation.ID? {
        get { _selectedConversationId }
        set {
            guard _selectedConversationId != newValue else { return }
            _selectedConversationId = newValue
        }
    }

    // Computed property derived from selectedConversationId
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

    // Called whenever _selectedConversationId changes
    private func updateSelectionState() {
        let conversation = selectedConversation
        let previousViewModelId = selectedConversationViewModel?.conversation.id

        if let conversation = conversation {
            if selectedConversationViewModel?.conversation.id != conversation.id {
                updateSelectionTask?.cancel()
                let viewModel = ConversationViewModel.createSync(
                    conversation: conversation,
                    session: session
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

        // Only update if the selection actually changed
        if previousViewModelId != _selectedConversationId {
            // Post notification for other observers (e.g., SyncingManager)
            let userInfo: [AnyHashable: Any] = _selectedConversationId.map { ["conversationId": $0] } ?? [:]
            NotificationCenter.default.post(
                name: .activeConversationChanged,
                object: nil,
                userInfo: userInfo
            )

            // Set the active client ID to protect this inbox from being put to sleep
            Task { [weak self] in
                guard let self else { return }
                await session.setActiveClientId(self.selectedConversation?.clientId)
            }
        }
    }

    var newConversationViewModel: NewConversationViewModel? {
        didSet {
            oldValue?.cleanUpIfNeeded()
            if newConversationViewModel == nil {
                // New conversation dismissed - notify observers and reset active client ID
                NotificationCenter.default.post(
                    name: .activeConversationChanged,
                    object: nil,
                    userInfo: [:] // no active conversation
                )
                Task { [weak self] in
                    guard let self else { return }
                    await session.setActiveClientId(selectedConversation?.clientId)
                }
            }
        }
    }
    var presentingExplodeInfo: Bool = false
    var presentingPinLimitInfo: Bool = false

    var conversations: [Conversation] = []
    var staleDeviceState: StaleDeviceState = .healthy

    /// True when any inbox is stale (partial or full). Drives banner visibility.
    var isDeviceStale: Bool {
        staleDeviceState.hasAnyStaleInboxes
    }

    /// True when the device is fully stale (every used inbox revoked).
    var isFullStale: Bool {
        staleDeviceState == .fullStale
    }

    /// User can still start/join conversations when there's at least one
    /// healthy inbox (i.e., not in fullStale).
    var canStartOrJoinConversations: Bool {
        staleDeviceState.hasUsableInboxes
    }
    @ObservationIgnored
    private var staleInboxIds: Set<String> = []
    /// Source-of-truth list from `conversationsPublisher`, unfiltered.
    /// We recompute `conversations` from this whenever staleInboxIds or
    /// hiddenConversationIds change — filtering `self.conversations`
    /// in-place would lose recovered conversations when an inbox goes
    /// from stale back to healthy.
    @ObservationIgnored
    private var unfilteredConversations: [Conversation] = []
    private var hiddenConversationIds: Set<String> = []
    private var conversationsCount: Int = 0 {
        didSet {
            if conversationsCount > 1 {
                hasCreatedMoreThanOneConvo = true
            }
            if oldValue == 0 && conversationsCount > 0 {
                BackupScheduler.shared.scheduleNextBackup(earliestIn: Self.firstConversationBackupDelay)
            }
        }
    }

    private static let firstConversationBackupDelay: TimeInterval = 15 * 60

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
        let baseConversations = conversations
            .filter { $0.isPinned }
            .filter { $0.kind == .group }
            .sorted { ($0.pinnedOrder ?? Int.max) < ($1.pinnedOrder ?? Int.max) }

        switch activeFilter {
        case .all:
            return baseConversations
        case .unread:
            return baseConversations.filter { $0.isUnread }
        case .exploding:
            return baseConversations.filter { $0.scheduledExplosionDate != nil }
        }
    }

    var unpinnedConversations: [Conversation] {
        let baseConversations = conversations.filter { !$0.isPinned }.filter { $0.kind == .group } // @jarodl temporarily filtering out dms
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
        UserDefaults.standard.removeObject(forKey: skippedRestoreBackupDateKey)
    }

    // MARK: - Restore prompt

    /// When non-nil, the empty conversations screen renders a "Welcome back"
    /// card offering to restore from this backup.
    var availableRestorePrompt: BackupBundleMetadata?

    /// Set when the restore card's Restore button is tapped, so the view can
    /// present `BackupRestoreSettingsView` as a sheet.
    var presentingRestoreSheet: Bool = false

    // MARK: - Private

    let session: any SessionManagerProtocol
    let databaseManager: (any DatabaseManagerProtocol)?
    let environment: AppEnvironment
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
        databaseManager: (any DatabaseManagerProtocol)? = nil,
        environment: AppEnvironment = ConfigManager.shared.currentEnvironment,
        horizontalSizeClass: UserInterfaceSizeClass? = nil
    ) {
        self.session = session
        self.databaseManager = databaseManager
        self.environment = environment
        self.horizontalSizeClass = horizontalSizeClass
        let coordinator = FocusCoordinator(horizontalSizeClass: horizontalSizeClass)
        self.focusCoordinator = coordinator
        self.appSettingsViewModel = AppSettingsViewModel(session: session)
        self.conversationsRepository = session.conversationsRepository(
            for: .allowed
        )
        self.conversationsCountRepository = session.conversationsCountRepo(
            for: .allowed,
            kinds: .groups
        )
        do {
            let initial = try conversationsRepository.fetchAll()
            // Seed both the visible list AND the unfiltered cache so the first
            // staleInboxIdsPublisher emit in observe() doesn't recompute
            // against an empty source and wipe the initial data.
            self.unfilteredConversations = initial
            self.conversations = initial
            self.conversationsCount = try conversationsCountRepository.fetchCount()
            if conversationsCount > 1 {
                hasCreatedMoreThanOneConvo = true
            }
        } catch {
            Log.error("Error fetching conversations: \(error)")
            self.unfilteredConversations = []
            self.conversations = []
            self.conversationsCount = 0
        }
        observe()
    }

    /// Update the horizontal size class when it changes (call from view)
    func updateHorizontalSizeClass(_ sizeClass: UserInterfaceSizeClass?) {
        guard horizontalSizeClass != sizeClass else { return }
        horizontalSizeClass = sizeClass

        // Update the focus coordinator's size class - it will react to the change
        focusCoordinator.horizontalSizeClass = sizeClass
    }

    deinit {
        updateSelectionTask?.cancel()
    }

    var joinerPairingViewModel: JoinerPairingSheetViewModel?
    var showJoinerPairingSheet: Bool = false

    func handleURL(_ url: URL) {
        guard let destination = DeepLinkHandler.destination(for: url) else {
            return
        }

        switch destination {
        case .joinConversation(inviteCode: let inviteCode):
            join(from: inviteCode)
        case let .pairDevice(pairingId, expiresAt, initiatorName):
            startJoinerPairing(pairingId: pairingId, expiresAt: expiresAt, initiatorName: initiatorName)
        }
    }

    private func startJoinerPairing(pairingId: String, expiresAt: Date?, initiatorName: String?) {
        joinerPairingViewModel?.cancel()

        let vaultManager = (session.vaultService as? VaultManager) ?? .preview
        let vm = JoinerPairingSheetViewModel(
            pairingId: pairingId,
            expiresAt: expiresAt,
            initiatorName: initiatorName,
            vaultManager: vaultManager
        )
        joinerPairingViewModel = vm
        showJoinerPairingSheet = true
    }

    func onStartConvo() {
        guard canStartOrJoinConversations else { return }
        newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .newConversation
        )
    }

    func onJoinConvo() {
        guard canStartOrJoinConversations else { return }
        newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .scanner
        )
    }

    private func join(from inviteCode: String) {
        guard canStartOrJoinConversations else { return }
        newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .joinInvite(code: inviteCode)
        )
    }

    func deleteAllData() {
        selectedConversation = nil
        appSettingsViewModel.deleteAllData {}
    }

    // MARK: - Stale state handling

    /// Reacts to changes in the device's stale-installation state.
    ///
    /// Behavior per state:
    /// - `healthy` → no action
    /// - `partialStale` → cancel any in-flight new conversation flow that
    ///   may have been started before the partial state was detected; the
    ///   user can still create new conversations in remaining healthy inboxes
    /// - `fullStale` → close any in-flight new conversation flow, dismiss
    ///   the selection, and trigger an automatic local reset (countdown
    ///   handled by the UI)
    private func handleStaleStateTransition(
        from previous: StaleDeviceState,
        to current: StaleDeviceState
    ) {
        guard previous != current else { return }

        let event: String
        switch (previous, current) {
        case (.healthy, .partialStale): event = "healthy_to_partial"
        case (.healthy, .fullStale): event = "healthy_to_full"
        case (.partialStale, .fullStale): event = "partial_to_full"
        case (.partialStale, .healthy): event = "partial_to_healthy"
        case (.fullStale, .partialStale): event = "full_to_partial"
        case (.fullStale, .healthy): event = "full_to_healthy"
        default: event = "unknown_transition"
        }
        Log.info("state transition: \(event) (previous=\(previous) current=\(current))")

        switch current {
        case .healthy:
            isPendingFullStaleAutoReset = false
        case .partialStale:
            // Continue allowing new convos in healthy inboxes — only close
            // an in-flight flow if it can no longer complete.
            isPendingFullStaleAutoReset = false
        case .fullStale:
            newConversationViewModel = nil
            selectedConversation = nil
        }
    }

    /// True when the UI should be showing the auto-reset countdown for full stale.
    /// The view layer renders a "Resetting in N seconds" countdown that the user
    /// can cancel — `cancelFullStaleAutoReset()` clears this back to false.
    var isPendingFullStaleAutoReset: Bool = false

    /// Recompute the visible `conversations` list from the unfiltered source,
    /// applying current `staleInboxIds` and `hiddenConversationIds` filters.
    /// Must be called whenever any of those three inputs change so that a
    /// previously-filtered conversation can reappear when its inbox recovers.
    private func recomputeVisibleConversations() {
        let filtered = unfilteredConversations
            .filter { !staleInboxIds.contains($0.inboxId) }
        conversations = hiddenConversationIds.isEmpty
            ? filtered
            : filtered.filter { !hiddenConversationIds.contains($0.id) }
    }

    func cancelFullStaleAutoReset() {
        isPendingFullStaleAutoReset = false
        Log.info("auto-reset cancelled by user")
    }

    func confirmFullStaleAutoReset() {
        Log.info("auto-reset confirmed")
        isPendingFullStaleAutoReset = false
        deleteAllData()
    }

    func leave(conversation: Conversation) {
        hiddenConversationIds.insert(conversation.id)
        if selectedConversation == conversation {
            selectedConversation = nil
        }
        recomputeVisibleConversations()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.deleteInbox(clientId: conversation.clientId, inboxId: conversation.inboxId)
            } catch {
                self.hiddenConversationIds.remove(conversation.id)
                self.recomputeVisibleConversations()
                Log.error("Error leaving convo: \(error.localizedDescription)")
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
                    unfilteredConversations.removeAll { $0.id == conversationId }
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

        // Observe explosion notification taps
        NotificationCenter.default
            .publisher(for: .explosionNotificationTapped)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.selectedConversation = nil
                self?.presentingExplodeInfo = true
            }
            .store(in: &cancellables)

        // Observe conversation notification taps
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

        let inboxesRepository = InboxesRepository(databaseReader: session.databaseReader)
        inboxesRepository.staleDeviceStatePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let previousState = self.staleDeviceState
                self.staleDeviceState = state
                self.handleStaleStateTransition(from: previousState, to: state)
            }
            .store(in: &cancellables)

        inboxesRepository.staleInboxIdsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                guard let self else { return }
                self.staleInboxIds = ids
                self.recomputeVisibleConversations()

                if let selectedId = self._selectedConversationId,
                   !self.conversations.contains(where: { $0.id == selectedId }) {
                    self.selectedConversationId = nil
                }

                // If filtering stale inboxes left zero visible conversations
                // but we have stale inboxes, escalate to fullStale. This
                // handles the edge case where partialStale leaves the app
                // unusable (e.g. the only "healthy" inbox is a draft with
                // no real conversations).
                if self.conversations.isEmpty, !ids.isEmpty,
                   self.staleDeviceState == .partialStale {
                    Log.info("no visible conversations in partial stale — escalating to fullStale")
                    let previous = self.staleDeviceState
                    self.staleDeviceState = .fullStale
                    self.handleStaleStateTransition(from: previous, to: .fullStale)
                }
            }
            .store(in: &cancellables)

        conversationsRepository.conversationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                guard let self else { return }
                self.unfilteredConversations = conversations
                self.recomputeVisibleConversations()

                // Clear selection if selected conversation no longer exists in the filtered list
                if let selectedId = _selectedConversationId,
                   !self.conversations.contains(where: { $0.id == selectedId }) {
                    selectedConversationId = nil
                }

                // Reset filter only when base conversations list is empty (not when filtered list is empty)
                if !conversations.contains(where: { !$0.isPinned && $0.kind == .group }) {
                    activeFilter = .all
                }
            }
            .store(in: &cancellables)

        // Mark active conversation as read when app becomes active
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
                self.checkForAvailableBackup()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: Self.debugShowRestorePromptNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDebugShowRestorePrompt()
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
        let clientId = conversation.clientId
        let inboxId = conversation.inboxId
        let currentlyMuted = conversation.isMuted

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = try await session.messagingService(
                    for: clientId,
                    inboxId: inboxId
                )
                let shouldEnableNotifications = currentlyMuted
                try await messagingService.setConversationNotificationsEnabled(shouldEnableNotifications, for: conversationId)
            } catch {
                Log.error("Failed toggling mute for conversation \(conversationId): \(error.localizedDescription)")
            }
        }
    }

    func toggleReadState(conversation: Conversation) {
        let conversationId = conversation.id
        let clientId = conversation.clientId
        let inboxId = conversation.inboxId
        let currentlyUnread = conversation.isUnread

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = try await session.messagingService(
                    for: clientId,
                    inboxId: inboxId
                )
                let writer = messagingService.conversationLocalStateWriter()
                try await writer.setUnread(!currentlyUnread, for: conversationId)
            } catch {
                Log.error("Failed toggling read state for conversation \(conversationId): \(error.localizedDescription)")
            }
        }
    }

    func togglePin(conversation: Conversation) {
        let conversationId = conversation.id
        let clientId = conversation.clientId
        let inboxId = conversation.inboxId
        let currentlyPinned = conversation.isPinned

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = try await session.messagingService(
                    for: clientId,
                    inboxId: inboxId
                )
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
        let clientId = conversation.clientId
        let inboxId = conversation.inboxId

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = try await session.messagingService(
                    for: clientId,
                    inboxId: inboxId
                )
                let writer = messagingService.conversationLocalStateWriter()
                try await writer.setUnread(false, for: conversationId)
            } catch {
                Log.warning("Failed marking conversation as read: \(error.localizedDescription)")
            }
        }
    }

    func explodeConversation(_ conversation: Conversation) {
        let conversationId = conversation.id
        let clientId = conversation.clientId
        let inboxId = conversation.inboxId
        let memberInboxIds = conversation.members.map { $0.profile.inboxId }

        // Optimistic hide: the conversation stays in unfilteredConversations
        // (the publisher hasn't emitted yet) but we filter it out of the
        // visible list via hiddenConversationIds so the user sees it disappear
        // immediately.
        hiddenConversationIds.insert(conversationId)
        if selectedConversation == conversation {
            selectedConversation = nil
        }
        recomputeVisibleConversations()

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = try await session.messagingService(for: clientId, inboxId: inboxId)
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

                // On success, drop from unfilteredConversations too so the
                // visible list stays correct until the conversationsPublisher
                // catches up with the DB delete. Then clear the hide marker.
                // Must remove from unfilteredConversations BEFORE removing
                // from hiddenConversationIds — otherwise recompute would
                // briefly resurface the conversation.
                self.unfilteredConversations.removeAll { $0.id == conversationId }
                self.hiddenConversationIds.remove(conversationId)
                self.recomputeVisibleConversations()
                Log.info("Exploded conversation from list: \(conversationId)")
            } catch {
                // On failure, bring the conversation back by clearing the
                // hide marker. unfilteredConversations still contains it.
                self.hiddenConversationIds.remove(conversationId)
                self.recomputeVisibleConversations()
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
        let clientId = conversation.clientId
        let inboxId = conversation.inboxId

        Task { [weak self] in
            guard let self else { return }
            do {
                let messagingService = try await session.messagingService(for: clientId, inboxId: inboxId)
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
