import Combine
import ConvosCore
import Foundation
import Observation
import SwiftUI
import UIKit

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
            // Update view model if needed
            if selectedConversationViewModel?.conversation.id != conversation.id {
                // Cancel any pending update task
                updateSelectionTask?.cancel()
                updateSelectionTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let viewModel = try await ConversationViewModel.create(
                            conversation: conversation,
                            session: session
                        )
                        guard !Task.isCancelled else { return }
                        guard self._selectedConversationId == conversation.id else { return }
                        self.selectedConversationViewModel = viewModel
                        self.markConversationAsRead(conversation)
                    } catch {
                        Log.error("Failed to create conversation view model: \(error)")
                    }
                }
            }
        } else {
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

    static let maxPinnedConversations: Int = 9

    var conversations: [Conversation] = []
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
    }

    var activeFilter: ConversationFilter = .all

    var pinnedConversations: [Conversation] {
        conversations
            .filter { $0.isPinned }
            .filter { $0.kind == .group }
            .sorted { ($0.pinnedOrder ?? Int.max) < ($1.pinnedOrder ?? Int.max) }
    }

    var unpinnedConversations: [Conversation] {
        let baseConversations = conversations.filter { !$0.isPinned }.filter { $0.kind == .group } // @jarodl temporarily filtering out dms
        switch activeFilter {
        case .all:
            return baseConversations
        case .unread:
            return baseConversations.filter { $0.isUnread }
        }
    }

    var hasUnpinnedConversations: Bool {
        conversations.contains { !$0.isPinned && $0.kind == .group }
    }

    private(set) var hasCreatedMoreThanOneConvo: Bool {
        get {
            UserDefaults.standard.bool(forKey: "hasCreatedMoreThanOneConvo")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hasCreatedMoreThanOneConvo")
        }
    }

    // MARK: - Private

    private let session: any SessionManagerProtocol
    private let conversationsRepository: any ConversationsRepositoryProtocol
    private let conversationsCountRepository: any ConversationsCountRepositoryProtocol
    private var localStateWriters: [String: any ConversationLocalStateWriterProtocol] = [:]
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = .init()
    @ObservationIgnored
    private var leftConversationObserver: Any?
    @ObservationIgnored
    private var newConversationViewModelTask: Task<Void, Never>?

    private var horizontalSizeClass: UserInterfaceSizeClass?

    let appSettingsViewModel: AppSettingsViewModel

    init(
        session: any SessionManagerProtocol,
        horizontalSizeClass: UserInterfaceSizeClass? = nil
    ) {
        self.session = session
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

    /// Update the horizontal size class when it changes (call from view)
    func updateHorizontalSizeClass(_ sizeClass: UserInterfaceSizeClass?) {
        guard horizontalSizeClass != sizeClass else { return }
        horizontalSizeClass = sizeClass

        // Update the focus coordinator's size class - it will react to the change
        focusCoordinator.horizontalSizeClass = sizeClass
    }

    deinit {
        newConversationViewModelTask?.cancel()
        updateSelectionTask?.cancel()
        if let leftConversationObserver {
            NotificationCenter.default.removeObserver(leftConversationObserver)
        }
    }

    func handleURL(_ url: URL) {
        guard let destination = DeepLinkHandler.destination(for: url) else {
            return
        }

        switch destination {
        case .joinConversation(inviteCode: let inviteCode):
            join(from: inviteCode)
        }
    }

    func onStartConvo() {
        newConversationViewModelTask?.cancel()
        newConversationViewModelTask = Task { [weak self] in
            guard let self else { return }
            let viewModel = await NewConversationViewModel.create(
                session: session,
                autoCreateConversation: true
            )
            await MainActor.run {
                self.newConversationViewModel = viewModel
            }
        }
    }

    func onJoinConvo() {
        newConversationViewModelTask?.cancel()
        newConversationViewModelTask = Task { [weak self] in
            guard let self else { return }
            let viewModel = await NewConversationViewModel.create(
                session: session,
                showingFullScreenScanner: true
            )
            await MainActor.run {
                self.newConversationViewModel = viewModel
            }
        }
    }

    private func join(from inviteCode: String) {
        newConversationViewModelTask?.cancel()
        newConversationViewModelTask = Task { [weak self] in
            guard let self else { return }
            let viewModel = await NewConversationViewModel.create(
                session: session
            )
            viewModel.joinConversation(inviteCode: inviteCode)
            await MainActor.run {
                self.newConversationViewModel = viewModel
            }
        }
    }

    func deleteAllData() {
        selectedConversation = nil
        appSettingsViewModel.deleteAllData { [weak self] in
            // Clear all cached writers
            DispatchQueue.main.async {
                self?.localStateWriters.removeAll()
            }
        }
    }

    func leave(conversation: Conversation) {
        if let index = conversations.firstIndex(of: conversation) {
            conversations.remove(at: index)
        }

        if selectedConversation == conversation {
            selectedConversation = nil
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.deleteInbox(clientId: conversation.clientId, inboxId: conversation.inboxId)

                // Remove cached writer for deleted inbox
                _ = await MainActor.run { self.localStateWriters.removeValue(forKey: conversation.inboxId) }
            } catch {
                Log.error("Error leaving convo: \(error.localizedDescription)")
            }
        }
    }

    private func observe() {
        leftConversationObserver = NotificationCenter.default
            .addObserver(forName: .leftConversationNotification, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let conversationId: String = notification.userInfo?["conversationId"] as? String else {
                        return
                    }
                    Log.info("Left conversation notification received for conversation: \(conversationId)")
                    if selectedConversation?.id == conversationId {
                        selectedConversation = nil
                        selectedConversationId = nil
                        selectedConversationViewModel = nil
                    }
                    if newConversationViewModel?.conversationViewModel.conversation.id == conversationId {
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
        conversationsRepository.conversationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                guard let self else { return }
                self.conversations = conversations

                // Clear selection if selected conversation no longer exists
                if let selectedId = _selectedConversationId,
                   !conversations.contains(where: { $0.id == selectedId }) {
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
                } else if let conversation = self.newConversationViewModel?.conversationViewModel.conversation {
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

                if !currentlyPinned {
                    let pinnedCount = try await writer.getPinnedCount()
                    guard pinnedCount < Self.maxPinnedConversations else {
                        await MainActor.run {
                            self.presentingPinLimitInfo = true
                        }
                        return
                    }
                }

                try await writer.setPinned(!currentlyPinned, for: conversationId)
            } catch {
                Log.error("Failed toggling pin for conversation \(conversationId): \(error.localizedDescription)")
            }
        }
    }

    private func markConversationAsRead(_ conversation: Conversation) {
        Task { [weak self] in
            guard let self else { return }
            do {
                // Get or create the local state writer for this inbox
                // Wrap dictionary access in MainActor.run to prevent race conditions
                let localStateWriter: (any ConversationLocalStateWriterProtocol)? = await MainActor.run {
                    if let existingWriter = self.localStateWriters[conversation.inboxId] {
                        return existingWriter
                    }
                    return nil
                }

                let writer: any ConversationLocalStateWriterProtocol
                if let localStateWriter {
                    writer = localStateWriter
                } else {
                    // Create new writer outside of MainActor context
                    let messagingService = try await session.messagingService(
                        for: conversation.clientId,
                        inboxId: conversation.inboxId
                    )
                    let newWriter = messagingService.conversationLocalStateWriter()

                    // Store it atomically on MainActor
                    await MainActor.run {
                        // Check again in case another task created it while we were waiting
                        if self.localStateWriters[conversation.inboxId] == nil {
                            self.localStateWriters[conversation.inboxId] = newWriter
                        }
                    }

                    writer = newWriter
                }

                try await writer.setUnread(false, for: conversation.id)
            } catch {
                Log.warning("Failed marking conversation as read: \(error.localizedDescription)")
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
