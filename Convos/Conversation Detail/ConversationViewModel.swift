import Combine
import ConvosCore
import ConvosCoreiOS
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
class ConversationViewModel {
    // MARK: - Private

    private let session: any SessionManagerProtocol
    private let messagingService: any MessagingServiceProtocol
    private let conversationStateManager: any ConversationStateManagerProtocol
    private let outgoingMessageWriter: any OutgoingMessageWriterProtocol
    private let backgroundUploadManager: any BackgroundUploadManagerProtocol

    @ObservationIgnored
    private var _cachedMessageWriter: (any OutgoingMessageWriterProtocol)?
    @ObservationIgnored
    private var _cachedMessageWriterConversationId: String?

    private var cachedMessageWriter: any OutgoingMessageWriterProtocol {
        if _cachedMessageWriterConversationId != conversation.id {
            Log.info("[EagerUpload] Creating new message writer for conversation: \(conversation.id)")
            _cachedMessageWriter = messagingService.messageWriter(
                for: conversation.id,
                backgroundUploadManager: backgroundUploadManager
            )
            _cachedMessageWriterConversationId = conversation.id
        } else {
            Log.info("[EagerUpload] Reusing cached message writer for conversation: \(conversation.id)")
        }
        return _cachedMessageWriter ?? messagingService.messageWriter(
            for: conversation.id,
            backgroundUploadManager: backgroundUploadManager
        )
    }
    private let consentWriter: any ConversationConsentWriterProtocol
    private let localStateWriter: any ConversationLocalStateWriterProtocol
    private let metadataWriter: any ConversationMetadataWriterProtocol
    private let explosionWriter: any ConversationExplosionWriterProtocol
    private let reactionWriter: any ReactionWriterProtocol
    private let conversationRepository: any ConversationRepositoryProtocol
    private let messagesListRepository: any MessagesListRepositoryProtocol
    private let photoPreferencesRepository: any PhotoPreferencesRepositoryProtocol
    private let photoPreferencesWriter: any PhotoPreferencesWriterProtocol
    private let attachmentLocalStateWriter: any AttachmentLocalStateWriterProtocol

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored
    private var photoPreferencesCancellable: AnyCancellable?
    @ObservationIgnored
    private var observedPhotoPreferencesConversationId: String?

    // MARK: - Public

    var myProfileViewModel: MyProfileViewModel

    var showsInfoView: Bool = true
    private(set) var conversation: Conversation {
        didSet {
            presentingConversationForked = conversation.isForked
            if oldValue.isDraft, !conversation.isDraft {
                applyPendingDraftEdits()
                _editingIncludeInfoInPublicPreview = nil
            }
            if !isEditingConversationName { editingConversationName = conversation.name ?? "" }
            if !isEditingDescription { editingDescription = conversation.description ?? "" }
        }
    }

    private func applyPendingDraftEdits() {
        let name = editingConversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = editingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let toggle = _editingIncludeInfoInPublicPreview
        Task { [weak self, metadataWriter, conversation] in
            guard let self else { return }
            if !name.isEmpty, name != (conversation.name ?? "") { try? await metadataWriter.updateName(name, for: conversation.id) }
            if !desc.isEmpty, desc != (conversation.description ?? "") { try? await metadataWriter.updateDescription(desc, for: conversation.id) }
            if let toggle, toggle != conversation.includeInfoInPublicPreview { self.updateIncludeInfoInPublicPreview(toggle) }
        }
    }
    var messages: [MessagesListItemType] = []
    var invite: Invite {
        conversation.invite ?? .empty
    }

    var profile: Profile { myProfileViewModel.profile }
    var profileImage: UIImage? {
        get {
            myProfileViewModel.profileImage
        }
        set {
            myProfileViewModel.profileImage = newValue
        }
    }
    var untitledConversationPlaceholder: String {
        conversation.computedDisplayName
    }
    var conversationInfoSubtitle: String {
        if let expiresAt = scheduledExplosionDate {
            return ExplosionDurationFormatter.countdown(until: expiresAt)
        }
        return conversation.shouldShowQuickEdit ? "Customize" : conversation.membersCountString
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
        get { myProfileViewModel.isEditingDisplayName }
        set { myProfileViewModel.isEditingDisplayName = newValue }
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
        isEditingConversationName ? editingConversationName : conversation.displayName
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
    var selectedAttachmentImage: UIImage? {
        didSet {
            if selectedAttachmentImage != nil, oldValue == nil {
                onPhotoAttached()
            }
        }
    }
    private(set) var currentEagerUploadKey: String?
    var canRemoveMembers: Bool {
        conversation.creator.isCurrentUser
    }
    var isUpdatingPublicPreview: Bool = false
    private var _editingIncludeInfoInPublicPreview: Bool?
    var includeInfoInPublicPreview: Bool {
        get {
            _editingIncludeInfoInPublicPreview ?? conversation.includeInfoInPublicPreview
        }
        set {
            _editingIncludeInfoInPublicPreview = newValue
            if !conversation.isDraft { updateIncludeInfoInPublicPreview(newValue) }
        }
    }
    var showsExplodeNowButton: Bool {
        conversation.members.count > 1 && conversation.creator.isCurrentUser
    }

    var scheduledExplosionDate: Date? {
        conversation.scheduledExplosionDate
    }

    var isExplosionScheduled: Bool {
        scheduledExplosionDate != nil
    }

    // MARK: - Lock Conversation

    var isLocked: Bool {
        conversation.isLocked
    }

    var isFull: Bool {
        conversation.isFull
    }

    var currentUserMember: ConversationMember? {
        conversation.members.first(where: { $0.isCurrentUser })
    }

    var isCurrentUserSuperAdmin: Bool {
        currentUserMember?.role == .superAdmin
    }

    var canToggleLock: Bool {
        isCurrentUserSuperAdmin
    }
    var sendButtonEnabled: Bool {
        !messageText.isEmpty || selectedAttachmentImage != nil
    }
    private(set) var isSendingPhoto: Bool = false
    var explodeState: ExplodeState = .ready

    var presentingConversationSettings: Bool = false
    var presentingProfileSettings: Bool = false
    var presentingProfileForMember: ConversationMember?
    var presentingNewConversationForInvite: NewConversationViewModel?
    var presentingConversationForked: Bool = false
    var presentingReactionsForMessage: AnyMessage?
    var replyingToMessage: AnyMessage?
    var presentingRevealMediaInfoSheet: Bool = false
    var presentingPhotosInfoSheet: Bool = false
    var activeToast: IndicatorToastStyle?

    var autoRevealPhotos: Bool = false {
        didSet {
            guard oldValue != autoRevealPhotos else { return }
            persistAutoReveal(autoRevealPhotos)
        }
    }

    private static let hasShownPhotosInfoSheetKey: String = "hasShownPhotosInfoSheet"
    private var hasShownPhotosInfoSheet: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownPhotosInfoSheetKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownPhotosInfoSheetKey) }
    }

    private static let hasShownRevealInfoSheetKey: String = "hasShownRevealInfoSheet"
    private var hasShownRevealInfoSheet: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownRevealInfoSheetKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownRevealInfoSheetKey) }
    }

    private static let revealToastKeyPrefix: String = "hasShownRevealToast_"
    private var hasShownRevealToastKey: String {
        "\(Self.revealToastKeyPrefix)\(conversation.id)"
    }
    private var hasShownRevealToast: Bool {
        get { UserDefaults.standard.bool(forKey: hasShownRevealToastKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasShownRevealToastKey) }
    }

    static func resetUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: hasShownPhotosInfoSheetKey)
        defaults.removeObject(forKey: hasShownRevealInfoSheetKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(revealToastKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func onPhotoAttached() {
        guard !hasShownPhotosInfoSheet else { return }
        hasShownPhotosInfoSheet = true
        presentingPhotosInfoSheet = true
    }

    var shouldBlurPhotos: Bool {
        !autoRevealPhotos
    }

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
    private var loadConversationImageTask: Task<Void, Never>?

    @ObservationIgnored
    private var explodeTask: Task<Void, Never>?

    deinit {
        loadConversationImageTask?.cancel()
        explodeTask?.cancel()
    }

    // MARK: - Init

    static func create(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared
    ) async throws -> ConversationViewModel {
        let messagingService = try await session.messagingService(
            for: conversation.clientId,
            inboxId: conversation.inboxId
        )
        return ConversationViewModel(
            conversation: conversation,
            session: session,
            messagingService: messagingService,
            backgroundUploadManager: backgroundUploadManager
        )
    }

    static func createSync(
        conversation: Conversation,
        session: any SessionManagerProtocol
    ) -> ConversationViewModel {
        let messagingService = session.messagingServiceSync(
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
        messagingService: any MessagingServiceProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared
    ) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService
        self.backgroundUploadManager = backgroundUploadManager

        let messagesRepository = session.messagesRepository(for: conversation.id)
        self.conversationStateManager = messagingService.conversationStateManager(for: conversation.id)
        self.conversationRepository = conversationStateManager.draftConversationRepository
        self.messagesListRepository = MessagesListRepository(messagesRepository: messagesRepository)
        self.outgoingMessageWriter = conversationStateManager
        self.consentWriter = conversationStateManager.conversationConsentWriter
        self.localStateWriter = conversationStateManager.conversationLocalStateWriter
        self.metadataWriter = conversationStateManager.conversationMetadataWriter
        self.explosionWriter = messagingService.conversationExplosionWriter()
        self.reactionWriter = messagingService.reactionWriter()

        let myProfileWriter = conversationStateManager.myProfileWriter
        let myProfileRepository = conversationRepository.myProfileRepository
        myProfileViewModel = .init(
            inboxId: conversation.inboxId,
            myProfileWriter: myProfileWriter,
            myProfileRepository: myProfileRepository
        )

        self.photoPreferencesRepository = session.photoPreferencesRepository(for: conversation.id)
        self.photoPreferencesWriter = session.photoPreferencesWriter()
        self.attachmentLocalStateWriter = session.attachmentLocalStateWriter()

        do {
            self.messages = try messagesListRepository.fetchInitial()
        } catch {
            Log.error("Error fetching messages: \(error.localizedDescription)")
            self.messages = []
        }

        editingConversationName = self.conversation.name ?? ""
        editingDescription = self.conversation.description ?? ""

        presentingConversationForked = self.conversation.isForked

        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        let individualMessageCount = messages.reduce(0) { count, item in
            if case .messages(let group) = item { return count + group.messages.count }
            return count
        }
        Log.info("[PERF] ConversationViewModel.init: \(perfElapsed)ms, \(individualMessageCount) messages loaded (\(messages.count) list items)")
        Log.info("Created for conversation: \(conversation.id)")

        observe()
        loadPhotoPreferences()

        startOnboarding()
    }

    // Alternative initializer for draft conversations with pre-loaded dependencies
    init(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        messagingService: any MessagingServiceProtocol,
        conversationStateManager: any ConversationStateManagerProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared
    ) {
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService
        self.backgroundUploadManager = backgroundUploadManager

        // Extract dependencies from conversation state manager
        self.conversationStateManager = conversationStateManager
        self.conversationRepository = conversationStateManager.draftConversationRepository
        let messagesRepository = conversationStateManager.draftConversationRepository.messagesRepository
        self.messagesListRepository = MessagesListRepository(messagesRepository: messagesRepository)
        self.outgoingMessageWriter = conversationStateManager
        self.consentWriter = conversationStateManager.conversationConsentWriter
        self.localStateWriter = conversationStateManager.conversationLocalStateWriter
        self.metadataWriter = conversationStateManager.conversationMetadataWriter
        self.explosionWriter = messagingService.conversationExplosionWriter()
        self.reactionWriter = messagingService.reactionWriter()

        let myProfileWriter = conversationStateManager.myProfileWriter
        let myProfileRepository = conversationStateManager.draftConversationRepository.myProfileRepository
        myProfileViewModel = .init(
            inboxId: conversation.inboxId,
            myProfileWriter: myProfileWriter,
            myProfileRepository: myProfileRepository
        )

        self.photoPreferencesRepository = session.photoPreferencesRepository(for: conversation.id)
        self.photoPreferencesWriter = session.photoPreferencesWriter()
        self.attachmentLocalStateWriter = session.attachmentLocalStateWriter()

        do {
            self.messages = try messagesListRepository.fetchInitial()
        } catch {
            Log.error("Error fetching messages: \(error.localizedDescription)")
            self.messages = []
        }

        Log.info("Created for draft conversation: \(conversation.id)")

        observe()
        loadPhotoPreferences()

        self.editingConversationName = conversation.name ?? ""
        self.editingDescription = conversation.description ?? ""
    }

    // MARK: - Private

    private func loadPhotoPreferences() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prefs = try await photoPreferencesRepository.preferences(for: conversation.id)
                self.autoRevealPhotos = prefs?.autoReveal ?? false
            } catch {
                Log.error("Error loading photo preferences: \(error)")
            }
        }
    }

    private func observe() {
        messagesListRepository.startObserving()
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
                let previousId = self.conversation.id
                self.conversation = conversation
                self.loadConversationImage(for: conversation)
                if conversation.id != previousId {
                    self.observePhotoPreferences(for: conversation.id)
                    self.loadPhotoPreferences()
                }
            }
            .store(in: &cancellables)
        ImageCache.shared.cacheUpdates
            .filter { [weak self] identifier in
                identifier == self?.conversation.imageCacheIdentifier
            }
            .sink { [weak self] _ in
                guard let self, !self.isConversationImageDirty else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.conversationImage = await ImageCache.shared.loadImage(for: self.conversation)
                    self.isConversationImageDirty = false
                }
            }
            .store(in: &cancellables)
        observePhotoPreferences(for: conversation.id)
    }

    private func observePhotoPreferences(for conversationId: String) {
        guard conversationId != observedPhotoPreferencesConversationId else { return }
        observedPhotoPreferencesConversationId = conversationId

        photoPreferencesCancellable?.cancel()
        photoPreferencesCancellable = photoPreferencesRepository.preferencesPublisher(for: conversationId)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                self.autoRevealPhotos = prefs?.autoReveal ?? false
            }
    }

    private func loadConversationImage(for conversation: Conversation) {
        guard !isConversationImageDirty else { return }

        loadConversationImageTask?.cancel()
        loadConversationImageTask = Task { [weak self] in
            guard let self else { return }
            let image = await ImageCache.shared.loadImage(for: conversation)
            guard !Task.isCancelled, !self.isConversationImageDirty else { return }
            self.conversationImage = image
            self.isConversationImageDirty = false
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
        if conversation.shouldShowQuickEdit {
            focusCoordinator.moveFocus(to: .conversationName)
        } else {
            presentingConversationSettings = true
        }
    }

    func onConversationInfoLongPress(focusCoordinator: FocusCoordinator) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            ImageCache.shared.cacheImage(conversationImage, for: conversation.imageCacheIdentifier, imageFormat: .jpg)
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
}

// MARK: - Conversation Settings Actions

extension ConversationViewModel {
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
        conversationImage = ImageCache.shared.image(for: conversation)
        isConversationImageDirty = false
    }

    func onProfilePhotoTap(focusCoordinator: FocusCoordinator) {
        focusCoordinator.moveFocus(to: .displayName)
    }

    func onProfileSettingsDismissed(focusCoordinator: FocusCoordinator) {
        onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .editProfile)
    }

    func onSendMessage(focusCoordinator: FocusCoordinator) {
        let hasText = !messageText.isEmpty
        let hasAttachment = selectedAttachmentImage != nil

        guard hasText || hasAttachment else { return }

        let prevMessageText = messageText
        let replyTarget = replyingToMessage
        let prevAttachmentImage = selectedAttachmentImage
        let eagerUploadKey = currentEagerUploadKey

        messageText = ""
        replyingToMessage = nil
        selectedAttachmentImage = nil
        currentEagerUploadKey = nil
        focusCoordinator.endEditing(for: .message, context: .conversation)

        let messageWriter = cachedMessageWriter

        Task { [weak self] in
            guard let self else { return }

            do {
                let photoTrackingKey: String?

                if prevAttachmentImage != nil {
                    isSendingPhoto = true
                    if let trackingKey = eagerUploadKey {
                        photoTrackingKey = trackingKey
                        if let replyTarget {
                            try await messageWriter.sendEagerPhotoReply(trackingKey: trackingKey, toMessageWithClientId: replyTarget.base.id)
                        } else {
                            try await messageWriter.sendEagerPhoto(trackingKey: trackingKey)
                        }
                    } else if let attachmentImage = prevAttachmentImage {
                        let key = try await messageWriter.startEagerUpload(image: attachmentImage)
                        photoTrackingKey = key
                        if let replyTarget {
                            try await messageWriter.sendEagerPhotoReply(trackingKey: key, toMessageWithClientId: replyTarget.base.id)
                        } else {
                            try await messageWriter.sendEagerPhoto(trackingKey: key)
                        }
                    } else {
                        photoTrackingKey = nil
                    }
                } else {
                    photoTrackingKey = nil
                }

                if hasText {
                    let textIsReply = replyTarget != nil && !hasAttachment
                    if textIsReply, let replyTarget {
                        try await messageWriter.sendReply(text: prevMessageText, afterPhoto: photoTrackingKey, toMessageWithClientId: replyTarget.base.id)
                    } else {
                        try await messageWriter.send(text: prevMessageText, afterPhoto: photoTrackingKey)
                    }
                }
            } catch {
                Log.error("Error sending message: \(error)")
            }

            isSendingPhoto = false
        }
    }

    func onReply(_ message: AnyMessage) {
        replyingToMessage = message
    }

    func cancelReply() {
        replyingToMessage = nil
    }

    func onPhotoSelected(_ image: UIImage) {
        let messageWriter = cachedMessageWriter
        if let existingKey = currentEagerUploadKey {
            currentEagerUploadKey = nil
            Task { await messageWriter.cancelEagerUpload(trackingKey: existingKey) }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let trackingKey = try await messageWriter.startEagerUpload(image: image)
                await MainActor.run { self.currentEagerUploadKey = trackingKey }
            } catch {
                Log.error("Error starting eager upload: \(error)")
            }
        }
    }

    func onPhotoRemoved() {
        guard let trackingKey = currentEagerUploadKey else { return }
        currentEagerUploadKey = nil
        Task { await cachedMessageWriter.cancelEagerUpload(trackingKey: trackingKey) }
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
        presentingNewConversationForInvite = NewConversationViewModel(
            session: session,
            mode: .joinInvite(code: invite.inviteSlug)
        )
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

    private func updateIncludeInfoInPublicPreview(_ enabled: Bool) {
        guard conversation.includeInfoInPublicPreview != enabled else { return }
        guard !isUpdatingPublicPreview else { return }
        isUpdatingPublicPreview = true
        let pendingName = editingConversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingDesc = editingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self, metadataWriter, conversation] in
            guard let self else { return }
            defer { self.isUpdatingPublicPreview = false }
            do {
                if !pendingName.isEmpty, pendingName != (conversation.name ?? "") {
                    try await metadataWriter.updateName(pendingName, for: conversation.id)
                }
                if !pendingDesc.isEmpty, pendingDesc != (conversation.description ?? "") {
                    try await metadataWriter.updateDescription(pendingDesc, for: conversation.id)
                }
                try await metadataWriter.updateIncludeInfoInPublicPreview(enabled, for: conversation.id)
            } catch {
                Log.error("Error updating public preview setting: \(error.localizedDescription)")
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

// MARK: - Pagination Support

extension ConversationViewModel {
    func loadPreviousMessages() {
        guard hasMoreMessages else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try messagesListRepository.fetchPrevious()
                Log.info("Fetching previous messages")
            } catch {
                Log.error("Error loading previous messages: \(error.localizedDescription)")
            }
        }
    }

    var hasMoreMessages: Bool { messagesListRepository.hasMoreMessages }

    var hasLoadedAllMessages: Bool { !messagesListRepository.hasMoreMessages }
}

// MARK: - Reactions

extension ConversationViewModel {
    func onReaction(emoji: String, messageId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await reactionWriter.toggleReaction(
                    emoji: emoji,
                    to: messageId,
                    in: conversation.id
                )
            } catch {
                Log.error("Error toggling reaction: \(error)")
            }
        }
    }

    func onTapReactions(_ message: AnyMessage) {
        presentingReactionsForMessage = message
    }

    func onToggleReaction(emoji: String, messageId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await reactionWriter.toggleReaction(
                    emoji: emoji,
                    to: messageId,
                    in: conversation.id
                )
            } catch {
                Log.error("Error toggling reaction: \(error)")
            }
        }
    }

    func removeReaction(_ reaction: MessageReaction, from message: AnyMessage) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await reactionWriter.removeReaction(
                    emoji: reaction.emoji,
                    from: message.base.id,
                    in: conversation.id
                )
                await MainActor.run {
                    self.presentingReactionsForMessage = nil
                }
            } catch {
                Log.error("Error removing reaction: \(error)")
            }
        }
    }
}

// MARK: - Photo Preferences

extension ConversationViewModel {
    func onPhotoRevealed(_ attachmentKey: String) {
        Log.info("[ConversationVM] onPhotoRevealed called with key: \(attachmentKey)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await attachmentLocalStateWriter.markRevealed(
                    attachmentKey: attachmentKey,
                    conversationId: conversation.id
                )
                Log.info("[ConversationVM] markRevealed completed for key: \(attachmentKey)")
            } catch {
                Log.error("Error marking photo revealed: \(error)")
            }
        }

        if !hasShownRevealInfoSheet {
            hasShownRevealInfoSheet = true
            hasShownRevealToast = true
            presentingRevealMediaInfoSheet = true
        } else if !hasShownRevealToast {
            hasShownRevealToast = true
            showRevealSettingsToast()
        }
    }

    func onPhotoHidden(_ attachmentKey: String) {
        Log.info("[ConversationVM] onPhotoHidden called with key: \(attachmentKey)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await attachmentLocalStateWriter.markHidden(
                    attachmentKey: attachmentKey,
                    conversationId: conversation.id
                )
                Log.info("[ConversationVM] markHidden completed for key: \(attachmentKey)")
            } catch {
                Log.error("Error marking photo hidden: \(error)")
            }
        }
    }

    func onPhotoDimensionsLoaded(_ attachmentKey: String, width: Int, height: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await attachmentLocalStateWriter.saveWithDimensions(
                    attachmentKey: attachmentKey,
                    conversationId: conversation.id,
                    width: width,
                    height: height
                )
            } catch {
                Log.error("Error saving photo dimensions: \(error)")
            }
        }
    }

    func setAutoReveal(_ autoReveal: Bool) {
        autoRevealPhotos = autoReveal
    }

    private func persistAutoReveal(_ autoReveal: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await photoPreferencesWriter.setAutoReveal(autoReveal, for: conversation.id)
            } catch {
                Log.error("Error setting autoReveal: \(error)")
            }
        }
    }

    func showRevealSettingsToast() {
        activeToast = .revealSettings(isAutoReveal: autoRevealPhotos)
    }
}

// MARK: - Lock & Explode

extension ConversationViewModel {
    func toggleLock() {
        guard canToggleLock else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                if isLocked {
                    try await metadataWriter.unlockConversation(for: conversation.id)
                    Log.info("Unlocked conversation: \(conversation.id)")
                } else {
                    try await metadataWriter.lockConversation(for: conversation.id)
                    Log.info("Locked conversation: \(conversation.id)")
                }
            } catch {
                Log.error("Error toggling lock for conversation: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Explosion Actions

extension ConversationViewModel {
    func explodeConvo() {
        guard canRemoveMembers else { return }
        guard explodeState.isReady || explodeState.isError || explodeState.isScheduled else { return }

        explodeState = .exploding

        explodeTask?.cancel()
        explodeTask = Task { [weak self] in
            guard let self else { return }

            do {
                let memberIds = conversation.members.map { $0.profile.inboxId }
                try await explosionWriter.explodeConversation(
                    conversationId: conversation.id,
                    memberInboxIds: memberIds
                )

                self.presentingConversationSettings = false
                self.explodeState = .exploded

                await UNUserNotificationCenter.current().addExplosionNotification(
                    conversationId: conversation.id,
                    displayName: conversation.displayName
                )

                NotificationCenter.default.post(
                    name: .conversationExpired,
                    object: nil,
                    userInfo: ["conversationId": self.conversation.id]
                )
                self.conversation.postLeftConversationNotification()
                Log.info("Explode complete, inbox deletion triggered")
            } catch {
                Log.error("Error exploding convo: \(error.localizedDescription)")
                self.explodeState = .error("Explode failed")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.explodeState = .ready
            }
        }
    }

    func scheduleExplosion(at expiresAt: Date) {
        guard canRemoveMembers else { return }
        // Intentionally excludes .isScheduled — rescheduling is not supported
        guard explodeState.isReady || explodeState.isError else { return }

        if expiresAt <= Date() {
            explodeConvo()
            return
        }

        explodeState = .exploding

        explodeTask?.cancel()
        explodeTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await explosionWriter.scheduleExplosion(
                    conversationId: conversation.id,
                    expiresAt: expiresAt
                )

                self.explodeState = .scheduled(expiresAt)
                Log.info("Explosion scheduled for \(expiresAt)")
            } catch {
                Log.error("Error scheduling explosion: \(error.localizedDescription)")
                self.explodeState = .error("Schedule failed")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.explodeState = .ready
            }
        }
    }
}

extension UNUserNotificationCenter {
    func addExplosionNotification(conversationId: String, displayName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\u{1F4A5} \(displayName) \u{1F4A5}"
        content.body = "A convo exploded"
        content.sound = .default
        content.userInfo = ["conversationId": conversationId, "isExplosion": true]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "self-explosion-\(conversationId)",
            content: content,
            trigger: trigger
        )
        try? await add(request)
    }
}
