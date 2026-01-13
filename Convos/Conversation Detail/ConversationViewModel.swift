import Combine
import ConvosCore
import Observation
import UIKit

@MainActor
@Observable
class ConversationViewModel {
    // MARK: - Private

    private let session: any SessionManagerProtocol
    private let messagingService: any MessagingServiceProtocol
    private let conversationStateManager: any ConversationStateManagerProtocol
    private let outgoingMessageWriter: any OutgoingMessageWriterProtocol
    private let consentWriter: any ConversationConsentWriterProtocol
    private let localStateWriter: any ConversationLocalStateWriterProtocol
    private let metadataWriter: any ConversationMetadataWriterProtocol
    private let conversationRepository: any ConversationRepositoryProtocol
    private let messagesListRepository: any MessagesListRepositoryProtocol

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Public

    var myProfileViewModel: MyProfileViewModel

    var showsInfoView: Bool = true
    private(set) var conversation: Conversation {
        didSet {
            presentingConversationForked = conversation.isForked
            if !isEditingConversationName {
                editingConversationName = conversation.name ?? ""
            }
            if !isEditingDescription {
                editingDescription = conversation.description ?? ""
            }
        }
    }
    var messages: [MessagesListItemType] = []
    var invite: Invite {
        conversation.invite ?? .empty
    }

    var profile: Profile {
        myProfileViewModel.profile
    }
    var profileImage: UIImage? {
        get {
            myProfileViewModel.profileImage
        }
        set {
            myProfileViewModel.profileImage = newValue
        }
    }
    var untitledConversationPlaceholder: String = "Untitled"
    var conversationInfoSubtitle: String {
        (
            !conversation.hasJoined || conversation.members.count > 1
        ) && !conversation.isDraft ? conversation.membersCountString : "Customize"
    }
    var conversationNamePlaceholder: String = "Convo name"
    var conversationDescriptionPlaceholder: String = "Description"
    var joinEnabled: Bool = true
    var notificationsEnabled: Bool {
        get { !conversation.isMuted }
        set { setNotificationsEnabled(newValue) }
    }

    // Editing state flags
    var isEditingDisplayName: Bool {
        get {
            myProfileViewModel.isEditingDisplayName
        }
        set {
            myProfileViewModel.isEditingDisplayName = newValue
        }
    }
    var isEditingConversationName: Bool = false
    var isEditingDescription: Bool = false

    // Editing values
    var editingConversationName: String = ""
    var editingDescription: String = ""

    // Computed properties for display
    var displayName: String {
        myProfileViewModel.displayName
    }

    var conversationName: String {
        isEditingConversationName ? editingConversationName : conversation.name ?? ""
    }

    var conversationDescription: String {
        isEditingDescription ? editingDescription : conversation.description ?? ""
    }
    var conversationImage: UIImage? {
        didSet {
            isConversationImageDirty = true
        }
    }
    var isConversationImageDirty: Bool = false
    var messageText: String = ""
    var canRemoveMembers: Bool {
        conversation.creator.isCurrentUser
    }
    var showsExplodeNowButton: Bool {
        conversation.members.count > 1 && conversation.creator.isCurrentUser
    }
    var sendButtonEnabled: Bool {
        !messageText.isEmpty
    }
    var explodeState: ExplodeState = .ready

    var presentingConversationSettings: Bool = false
    var presentingProfileSettings: Bool = false
    var presentingProfileForMember: ConversationMember?
    var presentingNewConversationForInvite: NewConversationViewModel?
    var presentingConversationForked: Bool = false

    // MARK: - Onboarding

    var onboardingCoordinator: ConversationOnboardingCoordinator = ConversationOnboardingCoordinator()
    var isWaitingForInviteAcceptance: Bool {
        get {
            onboardingCoordinator.isWaitingForInviteAcceptance
        }
        set {
            onboardingCoordinator.isWaitingForInviteAcceptance = newValue
        }
    }

    @ObservationIgnored
    private var joinFromInviteTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadConversationImageTask: Task<Void, Never>?

    // MARK: - Init

    static func create(
        conversation: Conversation,
        session: any SessionManagerProtocol
    ) async throws -> ConversationViewModel {
        let messagingService = try await session.messagingService(
            for: conversation.clientId,
            inboxId: conversation.inboxId
        )
        return ConversationViewModel(
            conversation: conversation,
            session: session,
            messagingService: messagingService
        )
    }

    init(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        messagingService: any MessagingServiceProtocol
    ) {
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService

        let messagesRepository = session.messagesRepository(for: conversation.id)
        self.conversationStateManager = messagingService.conversationStateManager(for: conversation.id)
        self.conversationRepository = conversationStateManager.draftConversationRepository
        self.messagesListRepository = MessagesListRepository(messagesRepository: messagesRepository)
        self.outgoingMessageWriter = conversationStateManager
        self.consentWriter = conversationStateManager.conversationConsentWriter
        self.localStateWriter = conversationStateManager.conversationLocalStateWriter
        self.metadataWriter = conversationStateManager.conversationMetadataWriter

        let myProfileWriter = conversationStateManager.myProfileWriter
        let myProfileRepository = conversationRepository.myProfileRepository
        myProfileViewModel = .init(
            inboxId: conversation.inboxId,
            myProfileWriter: myProfileWriter,
            myProfileRepository: myProfileRepository
        )

        do {
            self.messages = try messagesListRepository.fetchInitial()
            self.conversation = try conversationRepository.fetchConversation() ?? conversation
        } catch {
            Log.error("Error fetching messages or conversation: \(error.localizedDescription)")
            self.messages = []
        }

        editingConversationName = self.conversation.name ?? ""
        editingDescription = self.conversation.description ?? ""

        presentingConversationForked = self.conversation.isForked

        Log.info("Created for conversation: \(conversation.id)")

        observe()

        startOnboarding()
    }

    // Alternative initializer for draft conversations with pre-loaded dependencies
    init(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        messagingService: any MessagingServiceProtocol,
        conversationStateManager: any ConversationStateManagerProtocol
    ) {
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService

        // Extract dependencies from conversation state manager
        self.conversationStateManager = conversationStateManager
        self.conversationRepository = conversationStateManager.draftConversationRepository
        let messagesRepository = conversationStateManager.draftConversationRepository.messagesRepository
        self.messagesListRepository = MessagesListRepository(messagesRepository: messagesRepository)
        self.outgoingMessageWriter = conversationStateManager
        self.consentWriter = conversationStateManager.conversationConsentWriter
        self.localStateWriter = conversationStateManager.conversationLocalStateWriter
        self.metadataWriter = conversationStateManager.conversationMetadataWriter

        let myProfileWriter = conversationStateManager.myProfileWriter
        let myProfileRepository = conversationStateManager.draftConversationRepository.myProfileRepository
        myProfileViewModel = .init(
            inboxId: conversation.inboxId,
            myProfileWriter: myProfileWriter,
            myProfileRepository: myProfileRepository
        )

        do {
            self.messages = try messagesListRepository.fetchInitial()
            self.conversation = try conversationRepository.fetchConversation() ?? conversation
        } catch {
            Log.error("Error fetching messages or conversation: \(error.localizedDescription)")
            self.messages = []
        }

        Log.info("Created for draft conversation: \(conversation.id)")

        observe()

        self.editingConversationName = conversation.name ?? ""
        self.editingDescription = conversation.description ?? ""
    }

    // MARK: - Private

    private func observe() {
        messagesListRepository.messagesListPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.messages = messages
            }
            .store(in: &cancellables)
        conversationRepository.conversationPublisher
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] conversation in
                guard let self else { return }
                self.conversation = conversation
                self.loadConversationImage(for: conversation)
            }
            .store(in: &cancellables)
    }

    private func loadConversationImage(for conversation: Conversation) {
        guard !isConversationImageDirty else { return }
        guard let imageURL = conversation.imageURL else { return }

        if let cachedImage = ImageCache.shared.image(for: imageURL) {
            conversationImage = cachedImage
            isConversationImageDirty = false
            return
        }

        loadConversationImageTask?.cancel()
        loadConversationImageTask = Task { [weak self] in
            guard let self else { return }

            let cachedImage = await ImageCache.shared.imageAsync(for: imageURL)
            if let cachedImage {
                guard !Task.isCancelled, !self.isConversationImageDirty else { return }
                self.conversationImage = cachedImage
                self.isConversationImageDirty = false
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                guard !Task.isCancelled else { return }
                guard let image = UIImage(data: data) else { return }

                ImageCache.shared.setImage(image, for: imageURL.absoluteString)
                ImageCache.shared.setImage(image, for: conversation)

                guard !self.isConversationImageDirty else { return }
                self.conversationImage = image
                self.isConversationImageDirty = false
            } catch {
                if !Task.isCancelled {
                    Log.error("Error loading conversation image: \(error)")
                }
            }
        }
    }

    // MARK: - Public

    func startOnboarding() {
        Task { @MainActor in
            await onboardingCoordinator.start(
                for: conversation.clientId
            )
        }
    }

    func inviteWasAccepted() {
        Task { @MainActor in
            await onboardingCoordinator.inviteWasAccepted(for: conversation.clientId)
        }
    }

    func onConversationInfoTap(focusCoordinator: FocusCoordinator) {
        focusCoordinator.moveFocus(to: .conversationName)
    }

    func onConversationNameEndedEditing(focusCoordinator: FocusCoordinator, context: FocusTransitionContext) {
        let trimmedConversationName = editingConversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingConversationName = trimmedConversationName

        if trimmedConversationName != (conversation.name ?? "") {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await metadataWriter.updateName(
                        trimmedConversationName,
                        for: conversation.id
                    )
                } catch {
                    Log.error("Failed updating group name: \(error)")
                }
            }
        }

        if isConversationImageDirty, let conversationImage = conversationImage {
            ImageCache.shared.setImage(conversationImage, for: conversation)
            isConversationImageDirty = false

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await metadataWriter.updateImage(
                        conversationImage,
                        for: conversation
                    )
                } catch {
                    Log.error("Failed updating group image: \(error)")
                }
            }
        }

        let trimmedConversationDescription = editingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        editingDescription = trimmedConversationDescription

        if trimmedConversationDescription != (conversation.description ?? "") {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await metadataWriter.updateDescription(
                        trimmedConversationDescription,
                        for: conversation.id
                    )
                } catch {
                    Log.error("Failed updating group description: \(error)")
                }
            }
        }

        isEditingConversationName = false
        // Delegate focus transition to coordinator
        focusCoordinator.endEditing(for: .conversationName, context: context)
    }

    func onConversationSettings(focusCoordinator: FocusCoordinator) {
        presentingConversationSettings = true
        focusCoordinator.moveFocus(to: nil)
    }

    func onConversationSettingsDismissed(focusCoordinator: FocusCoordinator) {
        isEditingConversationName = false
        isEditingDescription = false
        onConversationNameEndedEditing(focusCoordinator: focusCoordinator, context: .conversationSettings)
        presentingConversationSettings = false
    }

    func onConversationSettingsCancelled() {
        isEditingConversationName = false
        isEditingDescription = false
        editingConversationName = conversation.name ?? ""
        editingDescription = conversation.description ?? ""
        if let imageURL = conversation.imageURL {
            conversationImage = ImageCache.shared.image(for: imageURL)
        } else {
            conversationImage = nil
        }
        isConversationImageDirty = false
    }

    func onProfilePhotoTap(focusCoordinator: FocusCoordinator) {
        focusCoordinator.moveFocus(to: .displayName)
    }

    func onProfileSettingsDismissed(focusCoordinator: FocusCoordinator) {
        onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .editProfile)
    }

    func onSendMessage(focusCoordinator: FocusCoordinator) {
        guard !messageText.isEmpty else { return }
        let prevMessageText = messageText
        messageText = ""
        focusCoordinator.endEditing(for: .message, context: .conversation)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await outgoingMessageWriter.send(text: prevMessageText)
            } catch {
                Log.error("Error sending message: \(error)")
            }
        }
    }

    func onUseQuickname(_ profile: Profile, _ profileImage: UIImage?) {
        myProfileViewModel.update(using: profile, profileImage: profileImage, conversationId: conversation.id)
    }

    func onTapAvatar(_ member: ConversationMember) {
        presentingProfileForMember = member
    }

    func dismissQuickEditor() {
        isEditingConversationName = false
        editingConversationName = conversation.name ?? ""
        myProfileViewModel.cancelEditingDisplayName()
    }

    func onTapInvite(_ invite: MessageInvite) {
        joinFromInviteTask?.cancel()
        joinFromInviteTask = Task { [weak self] in
            guard let self else { return }
            let viewModel = await NewConversationViewModel.create(
                session: session
            )
            guard !Task.isCancelled else { return }  // Check for cancellation after async operation
            viewModel.joinConversation(inviteCode: invite.inviteSlug)
            await MainActor.run {
                self.presentingNewConversationForInvite = viewModel
            }
        }
    }

    func onDisplayNameEndedEditing(focusCoordinator: FocusCoordinator, context: FocusTransitionContext) {
        isEditingDisplayName = false

        let pickedImage = myProfileViewModel.profileImage
        _ = myProfileViewModel.onEndedEditing(for: conversation.id)

        // Forward profile editing completion to onboarding coordinator
        onboardingCoordinator.handleDisplayNameEndedEditing(
            displayName: myProfileViewModel.editingDisplayName,
            profileImage: pickedImage
        )

        // Delegate focus transition to coordinator
        if onboardingCoordinator.isSettingUpQuickname {
            focusCoordinator.endEditing(for: .displayName, context: .onboardingQuickname)
        } else {
            focusCoordinator.endEditing(for: .displayName, context: context)
        }
    }

    func onProfileSettings() {
        presentingProfileSettings = true
    }

    func remove(member: ConversationMember) {
        guard canRemoveMembers else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await metadataWriter.removeMembers([member.profile.inboxId], from: conversation.id)
            } catch {
                Log.error("Error removing member: \(error.localizedDescription)")
            }
        }
    }

    private func setNotificationsEnabled(_ enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await messagingService.setConversationNotificationsEnabled(enabled, for: conversation.id)
            } catch {
                Log.error("Error updating notification settings: \(error.localizedDescription)")
            }
        }
    }

    func leaveConvo() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.deleteInbox(clientId: conversation.clientId, inboxId: conversation.inboxId)
                await MainActor.run {
                    self.presentingConversationSettings = false
                    self.conversation.postLeftConversationNotification()
                }
            } catch {
                Log.error("Error leaving convo: \(error.localizedDescription)")
            }
        }
    }

    private enum ExplodeConvoError: Error {
        case conversationNotFound
        case notGroupConversation
    }

    func explodeConvo() {
        guard canRemoveMembers else { return }
        guard case .ready = explodeState else { return }

        explodeState = .exploding

        Task { [weak self] in
            guard let self else { return }

            do {
                let expiresAt = Date()

                Log.info("Sending ExplodeSettings message...")
                let messagingService = try await session.messagingService(
                    for: conversation.clientId,
                    inboxId: conversation.inboxId
                )
                let inboxReady = try await messagingService.inboxStateManager.waitForInboxReadyResult()
                guard let xmtpConversation = try await inboxReady.client.conversationsProvider.findConversation(conversationId: conversation.id) else {
                    throw ExplodeConvoError.conversationNotFound
                }

                try await withTimeout(seconds: 20) {
                    try await xmtpConversation.sendExplode(expiresAt: expiresAt)
                }
                Log.info("ExplodeSettings message sent successfully")

                await MainActor.run {
                    self.explodeState = .exploded
                }

                guard case .group(let group) = xmtpConversation else {
                    throw ExplodeConvoError.notGroupConversation
                }

                try await metadataWriter.updateExpiresAt(expiresAt, for: conversation.id)

                let memberIdsToRemove = conversation.members
                    .map { $0.profile.inboxId }

                try await metadataWriter.removeMembers(
                    memberIdsToRemove,
                    from: conversation.id
                )

                try await group.updateConsentState(state: .denied)
                Log.info("Denied exploded conversation to prevent re-sync")

                await MainActor.run {
                    self.presentingConversationSettings = false
                    self.conversation.postLeftConversationNotification()
                }
                Log.info("Explode complete, inbox deletion triggered")
            } catch {
                Log.error("Error exploding convo: \(error.localizedDescription)")
                await MainActor.run {
                    self.explodeState = .error("Explode failed")
                }
            }
        }
    }

    // MARK: - Pagination Support

    /// Loads previous (older) messages
    func loadPreviousMessages() {
        guard hasMoreMessages else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try messagesListRepository.fetchPrevious()
                // Messages will be delivered through the publisher
                Log.info("Fetching previous messages")
            } catch {
                Log.error("Error loading previous messages: \(error.localizedDescription)")
            }
        }
    }

    /// Checks if there are more messages to load
    var hasMoreMessages: Bool {
        return messagesListRepository.hasMoreMessages
    }

    /// Indicates if all available messages have been loaded
    var hasLoadedAllMessages: Bool {
        return !messagesListRepository.hasMoreMessages
    }

    @MainActor
    func exportDebugLogs() async throws -> URL {
        // Get the XMTP client for this conversation
        let messagingService = try await session.messagingService(
            for: conversation.clientId,
            inboxId: conversation.inboxId
        )

        // Wait for inbox to be ready and get the client
        let inboxResult = try await messagingService.inboxStateManager.waitForInboxReadyResult()
        let client = inboxResult.client

        guard let xmtpConversation = try await client.conversation(with: conversation.id) else {
            throw NSError(
                domain: "ConversationViewModel",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Conversation not found"]
            )
        }

        return try await xmtpConversation.exportDebugLogs()
    }
}

extension ConversationViewModel {
    static var mock: ConversationViewModel {
        return .init(
            conversation: .mock(),
            session: MockInboxesService(),
            messagingService: MockMessagingService()
        )
    }
}
