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
    var selectedConversation: Conversation? {
        get {
            guard let id = _selectedConversationId else { return nil }
            return conversations.first(where: { $0.id == id })
        }
        set {
            selectedConversationId = newValue?.id
        }
    }

    private(set) var selectedConversationViewModel: ConversationViewModel?

    // Called whenever _selectedConversationId changes
    private func updateSelectionState() {
        let conversation = selectedConversation
        let previousViewModelId = selectedConversationViewModel?.conversation.id

        if let conversation = conversation {
            // Update view model if needed
            if selectedConversationViewModel?.conversation.id != conversation.id {
                selectedConversationViewModel = ConversationViewModel(
                    conversation: conversation,
                    session: session
                )
                markConversationAsRead(conversation)
            }
        } else {
            selectedConversationViewModel = nil
        }

        // Only post notification if the ID actually changed
        if previousViewModelId != _selectedConversationId {
            let userInfo: [AnyHashable: Any]
            if let conversationId = _selectedConversationId {
                userInfo = ["conversationId": conversationId]
            } else {
                userInfo = [:]
            }
            NotificationCenter.default.post(
                name: .activeConversationChanged,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    var newConversationViewModel: NewConversationViewModel? {
        didSet {
            if newConversationViewModel == nil {
                NotificationCenter.default.post(
                    name: .activeConversationChanged,
                    object: nil,
                    userInfo: [:] // leave out conversationId
                )
            }
        }
    }
    var presentingExplodeInfo: Bool = false
    let maxNumberOfConvos: Int = 50
    var presentingMaxNumberOfConvosReachedInfo: Bool = false
    private var maxNumberOfConvosReached: Bool {
        conversationsCount >= maxNumberOfConvos
    }
    private(set) var conversations: [Conversation] = []
    private var conversationsCount: Int = 0 {
        didSet {
            if conversationsCount > 1 {
                hasCreatedMoreThanOneConvo = true
            }
        }
    }

    var pinnedConversations: [Conversation] {
        conversations.filter { $0.isPinned }.filter { $0.kind == .group } // @jarodl temporarily filtering out dms
    }
    var unpinnedConversations: [Conversation] {
        conversations.filter { !$0.isPinned }.filter { $0.kind == .group } // @jarodl temporarily filtering out dms
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

    init(
        session: any SessionManagerProtocol,
        horizontalSizeClass: UserInterfaceSizeClass? = nil
    ) {
        self.session = session
        self.horizontalSizeClass = horizontalSizeClass
        let coordinator = FocusCoordinator(horizontalSizeClass: horizontalSizeClass)
        self.focusCoordinator = coordinator

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
        guard !maxNumberOfConvosReached else {
            presentingMaxNumberOfConvosReachedInfo = true
            return
        }
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
        guard !maxNumberOfConvosReached else {
            presentingMaxNumberOfConvosReachedInfo = true
            return
        }
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
        guard !maxNumberOfConvosReached else {
            presentingMaxNumberOfConvosReachedInfo = true
            return
        }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.deleteAllInboxes()

                // Clear all cached writers
                await MainActor.run { self.localStateWriters.removeAll() }
            } catch {
                Log.error("Error deleting all accounts: \(error)")
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
                try await session.deleteInbox(clientId: conversation.clientId)

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
                    let messagingService = session.messagingService(
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
}
