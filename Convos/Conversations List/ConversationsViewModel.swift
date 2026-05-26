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

    // MARK: - Navigation

    @ObservationIgnored
    let navigator: any ConversationsNavigator
    @ObservationIgnored
    let navState: ConversationsNavigatorImpl

    // MARK: - Selection State

    private(set) var selectedConversationViewModel: ConversationViewModel?

    @ObservationIgnored
    private var updateSelectionTask: Task<Void, Never>?

    func updateSelectionState() {
        let conversation: Conversation? = selectedConversation
        let previousViewModelId: String? = selectedConversationViewModel?.conversation.id

        if let conversation = conversation {
            if selectedConversationViewModel?.conversation.id != conversation.id {
                updateSelectionTask?.cancel()
                let viewModel: ConversationViewModel = ConversationViewModel.createSync(
                    conversation: conversation,
                    session: session,
                    metricsDelegate: navState.metricsDelegate
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

        if previousViewModelId != navState.selectedConversationId {
            let userInfo: [AnyHashable: Any] = navState.selectedConversationId.map { ["conversationId": $0] } ?? [:]
            NotificationCenter.default.post(
                name: .activeConversationChanged,
                object: nil,
                userInfo: userInfo
            )
        }

        updateListVisibility()
    }

    private var selectedConversation: Conversation? {
        guard let id = navState.selectedConversationId else { return nil }
        return conversations.first(where: { $0.id == id })
    }

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
    private let conversationsRepository: any ConversationsRepositoryProtocol
    private let conversationsCountRepository: any ConversationsCountRepositoryProtocol
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = .init()
    @ObservationIgnored
    private var leftConversationObserver: Any?

    private var horizontalSizeClass: UserInterfaceSizeClass?

    let appSettingsViewModel: AppSettingsViewModel

    @ObservationIgnored
    let metricsDelegate: CollectorDelegate
    @ObservationIgnored
    private(set) lazy var coreMetrics: CoreMetrics = CoreMetrics(
        delegate: metricsDelegate,
        stableId: PostHogConfiguration.stableIdEncoder
    )
    @ObservationIgnored
    private var didIdentifyUser: Bool = false
    @ObservationIgnored
    private var identifyTask: Task<Void, Never>?
    @ObservationIgnored
    private var userPropertiesTask: Task<Void, Never>?

    init(
        session: any SessionManagerProtocol,
        navigator: any ConversationsNavigator,
        navState: ConversationsNavigatorImpl,
        horizontalSizeClass: UserInterfaceSizeClass? = nil,
        metricsDelegate: CollectorDelegate = CollectorDelegate()
    ) {
        self.session = session
        self.navigator = navigator
        self.navState = navState
        self.horizontalSizeClass = horizontalSizeClass
        self.metricsDelegate = metricsDelegate
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
        identifyAndUpdateUserPropertiesIfNeeded()
    }

    func updateHorizontalSizeClass(_ sizeClass: UserInterfaceSizeClass?) {
        guard horizontalSizeClass != sizeClass else { return }
        horizontalSizeClass = sizeClass
        focusCoordinator.horizontalSizeClass = sizeClass
    }

    func onAppear() {
        isVisible = true
        navState.markScreenAppeared()
        updateListVisibility()
    }

    func onDisappear() {
        isVisible = false
        let durationSecs = navState.screenAppearAt.map { Float(Date().timeIntervalSince($0)) } ?? 0
        navigator.closed(context: ScreenContext(durationSecs: durationSecs))
        updateListVisibility()
    }

    @ObservationIgnored
    private var isVisible: Bool = false

    func updateListVisibility() {
        let isFocusedOnList = isVisible
            && selectedConversationViewModel == nil
            && navState.newConversationViewModel == nil
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
            navigator.present(newConversation: NewConversationNavigatorArgs(
                mode: .joinInvite,
                inviteCode: inviteCode
            ))
        case let .connectionGrant(serviceId: serviceId, conversationId: conversationId):
            guard conversations.contains(where: { $0.id == conversationId }) else {
                Log.warning("Dropping connection grant deep link for unknown conversationId")
                return
            }
            navigator.navigateTo(conversation: ConversationNavigatorArgs(conversationId: conversationId))
            navigator.present(connectionGrant: ConnectionGrantNavigatorArgs(
                serviceId: serviceId,
                conversationId: conversationId
            ))
        case .agentTemplate(templateId: let templateId):
            startConversation(withAgentTemplateId: templateId)
        }
    }

    func onStartConvo() {
        navState.newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .newConversation
        )
    }

    func onJoinConvo() {
        navState.newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .scanner
        )
    }

    private func join(from inviteCode: String) {
        navState.newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .joinInvite(code: inviteCode)
        )
    }

    private func startConversation(withAgentTemplateId templateId: String) {
        navState.newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .newConversationWithTemplate(templateId: templateId)
        )
    }

    func deleteAllData() {
        navState.selectedConversationId = nil
        appSettingsViewModel.deleteAllData {}
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
            navState.selectedConversationId = nil
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
                    if navState.selectedConversationId == conversationId {
                        navState.selectedConversationId = nil
                        selectedConversationViewModel = nil
                    }
                    if navState.newConversationViewModel?.conversationViewModel?.conversation.id == conversationId {
                        navState.newConversationViewModel = nil
                    }
                }
            }

        NotificationCenter.default
            .publisher(for: .explosionNotificationTapped)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.navState.selectedConversationId = nil
                self.navigator.present(explodeInfo: ExplodeInfoNavigatorArgs())
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

                if let selectedId = navState.selectedConversationId,
                   !conversations.contains(where: { $0.id == selectedId }) {
                    navState.selectedConversationId = nil
                }

                if !conversations.contains(where: { !$0.isPinned && $0.kind == .group }) {
                    activeFilter = .all
                }

                self.scheduleUserPropertiesUpdate()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let conversation = self.selectedConversationViewModel?.conversation {
                    self.markConversationAsRead(conversation)
                } else if let conversation = self.navState.newConversationViewModel?.conversationViewModel?.conversation {
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

        if conversations.contains(where: { $0.id == conversationId }) {
            Log.info("Found conversation, selecting it")
            navigator.navigateTo(conversation: ConversationNavigatorArgs(conversationId: conversationId))
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
                    self.navigator.present(pinLimitInfo: PinLimitInfoNavigatorArgs())
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
            navState.selectedConversationId = nil
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

    private func identifyAndUpdateUserPropertiesIfNeeded() {
        guard !didIdentifyUser else { return }
        didIdentifyUser = true

        identifyTask?.cancel()
        let metrics: CoreMetrics = coreMetrics
        let messagingService: AnyMessagingService = session.messagingService()
        identifyTask = Task { [weak self] in
            do {
                let inboxResult = try await messagingService.sessionStateManager.waitForInboxReadyResult()
                guard !Task.isCancelled else { return }
                let inboxId = inboxResult.client.inboxId
                metrics.identify(privateKey: Data(inboxId.utf8))
                await MainActor.run {
                    self?.sendCurrentUserProperties()
                }
            } catch {
                Log.warning("Metrics identify failed: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleUserPropertiesUpdate() {
        guard didIdentifyUser else { return }
        userPropertiesTask?.cancel()
        userPropertiesTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.sendCurrentUserProperties()
            }
        }
    }

    private func sendCurrentUserProperties() {
        let properties: UserProperties = currentUserProperties()
        let metrics: CoreMetrics = coreMetrics
        Task {
            await metrics.updateUserProperties(properties: properties)
        }
    }

    private func currentUserProperties() -> UserProperties {
        let now: Date = Date()
        let oneDay: TimeInterval = 60 * 60 * 24
        let sevenDays: TimeInterval = oneDay * 7
        let groupConversations: [Conversation] = conversations.filter { $0.kind == .group }
        let conversationCount: Int = groupConversations.count
        let assistantConversationCount: Int = groupConversations.filter { $0.hasAgent }.count
        let activeWithin24Hours: [Conversation] = groupConversations.filter {
            guard let lastAt = $0.lastMessage?.createdAt else { return false }
            return now.timeIntervalSince(lastAt) <= oneDay
        }
        let conversationCount24Hours: Int = activeWithin24Hours.count
        let conversationCount7Days: Int = groupConversations.filter {
            guard let lastAt = $0.lastMessage?.createdAt else { return false }
            return now.timeIntervalSince(lastAt) <= sevenDays
        }.count
        let maxAgeSecs: TimeInterval = activeWithin24Hours
            .map { now.timeIntervalSince($0.createdAt) }
            .max() ?? 0
        let maxActiveConvoAge: Float = Float(maxAgeSecs / oneDay)
        return UserProperties(
            hasMessagedAssistant: false,
            lastAssistantMessageTimestamp: nil,
            contactCount: 0,
            conversationCount: conversationCount,
            assistantConversationCount: assistantConversationCount,
            conversationCount24Hours: conversationCount24Hours,
            conversationCount7Days: conversationCount7Days,
            maxActiveConvoAge: maxActiveConvoAge
        )
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
        let delegate = CollectorDelegate()
        let navState = ConversationsNavigatorImpl(session: client.session, metricsDelegate: delegate)
        let navigator = ConversationsCollector(instance: navState, delegate: delegate)
        return .init(session: client.session, navigator: navigator, navState: navState)
    }

    static func preview(conversations: [Conversation]) -> ConversationsViewModel {
        let client = ConvosClient.mock()
        let delegate = CollectorDelegate()
        let navState = ConversationsNavigatorImpl(session: client.session, metricsDelegate: delegate)
        let navigator = ConversationsCollector(instance: navState, delegate: delegate)
        let vm = ConversationsViewModel(session: client.session, navigator: navigator, navState: navState)
        vm.conversations = conversations
        return vm
    }
}
