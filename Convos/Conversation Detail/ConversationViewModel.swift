import AVFoundation
import Combine
import ConvosConnections
import ConvosCore
import ConvosCoreiOS
import Observation
import SwiftUI
import UIKit
import UserNotifications

struct PendingInvite {
    let code: String
    var fullURL: String
    let range: Range<String.Index>
    var linkedConversationId: String?
    var explodeDuration: ExplodeDuration?
}

struct PendingFileAttachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let filename: String
    let mimeType: String
    let fileSize: Int

    init(id: UUID = UUID(), url: URL, filename: String, mimeType: String, fileSize: Int) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
    }

    static func == (lhs: PendingFileAttachment, rhs: PendingFileAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct PendingPhotoAttachment: Identifiable, Equatable {
    let id: UUID
    let image: UIImage
    var eagerUploadKey: String?

    init(id: UUID = UUID(), image: UIImage, eagerUploadKey: String? = nil) {
        self.id = id
        self.image = image
        self.eagerUploadKey = eagerUploadKey
    }

    static func == (lhs: PendingPhotoAttachment, rhs: PendingPhotoAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct PendingVideoAttachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var thumbnail: UIImage?
    var eagerUploadKey: String?

    init(id: UUID = UUID(), url: URL, thumbnail: UIImage? = nil, eagerUploadKey: String? = nil) {
        self.id = id
        self.url = url
        self.thumbnail = thumbnail
        self.eagerUploadKey = eagerUploadKey
    }

    static func == (lhs: PendingVideoAttachment, rhs: PendingVideoAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

enum PendingMediaAttachment: Identifiable, Equatable {
    case photo(PendingPhotoAttachment)
    case video(PendingVideoAttachment)
    case file(PendingFileAttachment)

    var id: UUID {
        switch self {
        case .photo(let p): return p.id
        case .video(let v): return v.id
        case .file(let f): return f.id
        }
    }
}

let maxPendingMediaAttachments: Int = 8

enum ExplodeDuration: CaseIterable {
    case sixtySeconds
    case oneHour
    case twentyFourHours
    case sundayAtMidnight

    var label: String {
        switch self {
        case .sixtySeconds: return "60 seconds"
        case .oneHour: return "1 hour"
        case .twentyFourHours: return "24 hours"
        case .sundayAtMidnight: return "Sunday at midnight"
        }
    }

    var shortLabel: String {
        switch self {
        case .sixtySeconds: return "60s"
        case .oneHour: return "1h"
        case .twentyFourHours: return "24h"
        case .sundayAtMidnight: return "Sun"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .sixtySeconds: return 60
        case .oneHour: return 3600
        case .twentyFourHours: return 86400
        case .sundayAtMidnight:
            let calendar = Calendar.current
            let now = Date()
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            components.weekday = 1
            components.hour = 0
            components.minute = 0
            components.second = 0
            if let nextSunday = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: 1), matchingPolicy: .nextTime) {
                return nextSunday.timeIntervalSince(now)
            }
            return 604800
        }
    }
}

@MainActor
@Observable
class ConversationViewModel { // swiftlint:disable:this type_body_length
    // MARK: - Private

    private let session: any SessionManagerProtocol
    let messagingService: any MessagingServiceProtocol
    private let conversationStateManager: any ConversationStateManagerProtocol
    private let outgoingMessageWriter: any OutgoingMessageWriterProtocol
    private let backgroundUploadManager: any BackgroundUploadManagerProtocol

    @ObservationIgnored
    private var _cachedMessageWriter: (any OutgoingMessageWriterProtocol)?
    @ObservationIgnored
    private var _cachedMessageWriterConversationId: String?

    private var cachedMessageWriter: any OutgoingMessageWriterProtocol {
        if _cachedMessageWriterConversationId != conversation.id {
            Log.debug("[EagerUpload] Creating new message writer for conversation: \(conversation.id)")
            _cachedMessageWriter = messagingService.messageWriter(
                for: conversation.id,
                backgroundUploadManager: backgroundUploadManager
            )
            _cachedMessageWriterConversationId = conversation.id
        } else {
            Log.debug("[EagerUpload] Reusing cached message writer for conversation: \(conversation.id)")
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
    let readReceiptWriter: any ReadReceiptWriterProtocol
    private let conversationRepository: any ConversationRepositoryProtocol
    private var messagesListRepository: any MessagesListRepositoryProtocol
    private let photoPreferencesRepository: any PhotoPreferencesRepositoryProtocol
    private let photoPreferencesWriter: any PhotoPreferencesWriterProtocol
    private let attachmentLocalStateWriter: any AttachmentLocalStateWriterProtocol
    let voiceMemoTranscriptionService: any VoiceMemoTranscriptionServicing
    private let applyGlobalDefaultsForNewConversation: Bool
    let typingIndicatorManager: TypingIndicatorManager

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored
    private var convosButtonCancellable: AnyCancellable?
    @ObservationIgnored
    private var convosButtonTask: Task<Void, Never>?
    @ObservationIgnored
    private var explodeDurationTask: Task<Void, Never>?
    @ObservationIgnored
    private var photoPreferencesCancellable: AnyCancellable?
    @ObservationIgnored
    private var observedPhotoPreferencesConversationId: String?
    @ObservationIgnored
    private var capabilityRequestsCancellable: AnyCancellable?
    @ObservationIgnored
    private var observedCapabilityRequestsConversationId: String?
    @ObservationIgnored
    private var latestObservedCapabilityRequest: CapabilityRequest?
    @ObservationIgnored
    private var locallyHandledCapabilityRequestIds: Set<String> = []
    @ObservationIgnored
    var lastReadReceiptSentAt: Date?
    @ObservationIgnored
    var pendingReadReceiptTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastMessageCountForReadReceipt: Int = 0

    // MARK: - Public

    var myProfileViewModel: MyProfileViewModel

    var showsInfoView: Bool = true
    private(set) var conversation: Conversation {
        didSet {
            messagesListRepository.currentOtherMemberCount = conversation.membersWithoutCurrent.count
            presentingConversationForked = conversation.isForked
            if oldValue.isDraft, !conversation.isDraft {
                // Keep the draft include-info override until remote metadata changes propagate.
                // Clearing it here can briefly show stale false values during async sync.
                applyPendingDraftEdits()
                startOnboarding()
            }

            if oldValue.isPendingInvite, !conversation.isPendingInvite {
                inviteWasAccepted()
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
        if isWaitingForInviteAcceptance {
            return conversation.membersCountString
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

    var isEditingDisplayName: Bool {
        get { myProfileViewModel.isEditingDisplayName }
        set { myProfileViewModel.isEditingDisplayName = newValue }
    }
    var isEditingConversationName: Bool = false
    var isEditingDescription: Bool = false

    var editingConversationName: String = ""
    var editingDescription: String = ""

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
    var messageText: String = "" {
        didSet {
            handleTextChanged()
        }
    }
    private var previousMessageTextLength: Int = 0
    var pastedLinkPreview: LinkPreview?

    func checkForPastedLink() {
        let inserted = messageText.count - previousMessageTextLength
        previousMessageTextLength = messageText.count
        guard inserted > 1, pastedLinkPreview == nil else { return }
        guard InviteURLDetector.detectInviteURL(in: messageText) == nil else { return }
        guard let preview = LinkPreview.from(text: messageText) else { return }
        pastedLinkPreview = preview
        messageText = ""
        previousMessageTextLength = 0
    }

    var typingMembers: [ConversationMember] = []

    @ObservationIgnored
    var isTypingSent: Bool = false
    @ObservationIgnored
    var typingResetTask: Task<Void, Never>?
    @ObservationIgnored
    var pendingTypingIndicatorTask: Task<Void, Never>?
    @ObservationIgnored
    var typingThrottleDate: Date?

    var pendingMediaAttachments: [PendingMediaAttachment] = []
    @ObservationIgnored
    private var videoThumbnailTasks: [UUID: Task<Void, Never>] = [:]
    var voiceMemoRecorder: VoiceMemoRecorder = VoiceMemoRecorder()
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
    var pendingInvite: PendingInvite?
    var pendingInviteConvoName: String = ""
    var pendingInviteImage: UIImage?

    var sendButtonEnabled: Bool {
        !messageText.isEmpty
            || !pendingMediaAttachments.isEmpty
            || pendingInvite != nil
            || pastedLinkPreview != nil
    }

    var canStageMoreMedia: Bool {
        pendingMediaAttachments.count < maxPendingMediaAttachments
    }

    var canStageSideConvo: Bool {
        pendingInvite == nil
    }

    var canRecordVoiceMemo: Bool {
        pendingMediaAttachments.isEmpty
    }

    private(set) var isSendingMedia: Bool = false
    var explodeState: ExplodeState = .ready

    var presentingConversationSettings: Bool = false
    var presentingProfileSettings: Bool = false

    /// The agent's most-recent unresolved `capability_request` for this conversation.
    /// When non-nil, `ConversationView` renders the picker card in the same slot the
    /// `ConversationOnboardingView` would otherwise occupy. Cleared on Approve / Deny /
    /// dismiss; replaced wholesale when a newer request arrives (per the "only show the
    /// last request" rule).
    var pendingCapabilityPickerLayout: CapabilityPickerLayout?
    var showsCapabilityApprovedToast: Bool = false
    var presentingProfileForMember: ConversationMember?
    var presentingNewConversationForInvite: NewConversationViewModel? {
        didSet { oldValue?.cleanUpIfNeeded() }
    }
    var presentingConversationForked: Bool = false
    var presentingReactionsForMessage: AnyMessage?
    var replyingToMessage: AnyMessage?
    var presentingShareView: Bool = false
    var presentingRevealMediaInfoSheet: Bool = false
    var presentingPhotosInfoSheet: Bool = false
    var presentingAssistantConfirmation: Bool = false
    var presentingExplodedInviteInfo: Bool = false
    var activeToast: IndicatorToastStyle?

    var assistantJoinForceErrorCode: Int?

    var isAssistantJoinPending: Bool {
        assistantJoinTask != nil || conversation.assistantJoinStatus == .pending
    }

    @ObservationIgnored
    private var assistantJoinTask: Task<Void, Never>?
    @ObservationIgnored
    private var assistantJoinTaskId: String?

    var autoRevealPhotos: Bool = false
    var sendReadReceipts: Bool = true
    var isViewingConversation: Bool = false

    private static let hasShownPhotosInfoSheetKey: String = "hasShownPhotosInfoSheet"
    private var hasShownPhotosInfoSheet: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownPhotosInfoSheetKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownPhotosInfoSheetKey) }
    }

    private static let hasShownAssistantConfirmationKey: String = "hasShownAssistantConfirmation"
    private var hasShownAssistantConfirmation: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownAssistantConfirmationKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownAssistantConfirmationKey) }
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
        defaults.removeObject(forKey: hasShownAssistantConfirmationKey)
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

    func onRequestAssistantJoin() {
        guard !hasShownAssistantConfirmation else {
            requestAssistantJoin()
            return
        }
        hasShownAssistantConfirmation = true
        presentingAssistantConfirmation = true
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

    @ObservationIgnored
    private var voiceMemoPlaybackTask: Task<Void, Never>?

    deinit {
        voiceMemoPlaybackTask?.cancel()
        pendingReadReceiptTask?.cancel()
        pendingTypingIndicatorTask?.cancel()
        loadConversationImageTask?.cancel()
        explodeTask?.cancel()
        assistantJoinTask?.cancel()
        convosButtonTask?.cancel()
        explodeDurationTask?.cancel()
    }

    // MARK: - Init

    static func create(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared
    ) async throws -> ConversationViewModel {
        let messagingService = session.messagingService()
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
        let messagingService = session.messagingServiceSync()
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
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared,
        applyGlobalDefaultsForNewConversation: Bool = false
    ) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService
        self.backgroundUploadManager = backgroundUploadManager
        self.applyGlobalDefaultsForNewConversation = applyGlobalDefaultsForNewConversation

        let messagesRepository = session.messagesRepository(for: conversation.id)
        self.conversationStateManager = messagingService.conversationStateManager(for: conversation.id)
        self.conversationRepository = conversationStateManager.draftConversationRepository
        let transcriptionService = session.voiceMemoTranscriptionService()
        let messagesListRepo = MessagesListRepository(
            messagesRepository: messagesRepository,
            transcriptRepository: session.voiceMemoTranscriptRepository(),
            conversationId: conversation.id,
            speechPermissionProvider: { transcriptionService.hasSpeechPermission() }
        )
        messagesListRepo.currentOtherMemberCount = conversation.membersWithoutCurrent.count
        self.messagesListRepository = messagesListRepo
        self.outgoingMessageWriter = conversationStateManager
        self.consentWriter = conversationStateManager.conversationConsentWriter
        self.localStateWriter = conversationStateManager.conversationLocalStateWriter
        self.metadataWriter = conversationStateManager.conversationMetadataWriter
        self.explosionWriter = messagingService.conversationExplosionWriter()
        self.reactionWriter = messagingService.reactionWriter()
        self.readReceiptWriter = messagingService.readReceiptWriter()

        let myProfileWriter = conversationStateManager.myProfileWriter
        let myProfileRepository = conversationRepository.myProfileRepository
        // MyProfileViewModel fills its "empty" profile with the current user's
        // inboxId. In single-inbox mode that's always the singleton; read it
        // off the first conversation member flagged isCurrentUser.
        let currentUserInboxId = conversation.members.first(where: { $0.isCurrentUser })?.profile.inboxId ?? ""
        myProfileViewModel = .init(
            inboxId: currentUserInboxId,
            myProfileWriter: myProfileWriter,
            myProfileRepository: myProfileRepository
        )

        self.photoPreferencesRepository = session.photoPreferencesRepository(for: conversation.id)
        self.photoPreferencesWriter = session.photoPreferencesWriter()
        self.attachmentLocalStateWriter = session.attachmentLocalStateWriter()
        self.voiceMemoTranscriptionService = transcriptionService
        self.typingIndicatorManager = .shared

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

        applyGlobalDefaultsForDraftConversationIfNeeded()
        observe()
        loadPhotoPreferences()
        observeTypingIndicators(typingIndicatorManager)

        if conversation.isPendingInvite {
            onboardingCoordinator.isWaitingForInviteAcceptance = true
        }
        startOnboarding()
        registerInlineAttachmentRecovery()
        scheduleVoiceMemoTranscriptionsIfNeeded(in: messages)
    }

    init(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        messagingService: any MessagingServiceProtocol,
        conversationStateManager: any ConversationStateManagerProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared,
        applyGlobalDefaultsForNewConversation: Bool = false
    ) {
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService
        self.backgroundUploadManager = backgroundUploadManager
        self.applyGlobalDefaultsForNewConversation = applyGlobalDefaultsForNewConversation

        self.conversationStateManager = conversationStateManager
        self.conversationRepository = conversationStateManager.draftConversationRepository
        let messagesRepository = conversationStateManager.draftConversationRepository.messagesRepository
        let transcriptionService = session.voiceMemoTranscriptionService()
        let messagesListRepo2 = MessagesListRepository(
            messagesRepository: messagesRepository,
            transcriptRepository: session.voiceMemoTranscriptRepository(),
            conversationId: conversation.id,
            speechPermissionProvider: { transcriptionService.hasSpeechPermission() }
        )
        messagesListRepo2.currentOtherMemberCount = conversation.membersWithoutCurrent.count
        self.messagesListRepository = messagesListRepo2
        self.outgoingMessageWriter = conversationStateManager
        self.consentWriter = conversationStateManager.conversationConsentWriter
        self.localStateWriter = conversationStateManager.conversationLocalStateWriter
        self.metadataWriter = conversationStateManager.conversationMetadataWriter
        self.explosionWriter = messagingService.conversationExplosionWriter()
        self.reactionWriter = messagingService.reactionWriter()
        self.readReceiptWriter = messagingService.readReceiptWriter()

        let myProfileWriter = conversationStateManager.myProfileWriter
        let myProfileRepository = conversationStateManager.draftConversationRepository.myProfileRepository
        let draftCurrentUserInboxId = conversation.members.first(where: { $0.isCurrentUser })?.profile.inboxId ?? ""
        myProfileViewModel = .init(
            inboxId: draftCurrentUserInboxId,
            myProfileWriter: myProfileWriter,
            myProfileRepository: myProfileRepository
        )

        self.photoPreferencesRepository = session.photoPreferencesRepository(for: conversation.id)
        self.photoPreferencesWriter = session.photoPreferencesWriter()
        self.attachmentLocalStateWriter = session.attachmentLocalStateWriter()
        self.voiceMemoTranscriptionService = transcriptionService
        self.typingIndicatorManager = .shared

        do {
            self.messages = try messagesListRepository.fetchInitial()
        } catch {
            Log.error("Error fetching messages: \(error.localizedDescription)")
            self.messages = []
        }

        Log.info("Created for draft conversation: \(conversation.id)")

        applyGlobalDefaultsForDraftConversationIfNeeded()
        observe()
        loadPhotoPreferences()
        observeTypingIndicators(typingIndicatorManager)
        registerInlineAttachmentRecovery()
        scheduleVoiceMemoTranscriptionsIfNeeded(in: messages)

        self.editingConversationName = conversation.name ?? ""
        self.editingDescription = conversation.description ?? ""
    }

    // MARK: - Private

    private func loadPhotoPreferences() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prefs = try await photoPreferencesRepository.preferences(for: conversation.id)
                let defaultAutoReveal: Bool = applyGlobalDefaultsForNewConversation ? GlobalConvoDefaults.shared.autoRevealPhotos : false
                setAutoRevealPhotosLocally(prefs?.autoReveal ?? defaultAutoReveal)
                let readReceiptsPref = prefs?.sendReadReceipts ?? GlobalConvoDefaults.shared.sendReadReceipts
                sendReadReceipts = readReceiptsPref
                messagesListRepository.sendReadReceipts = readReceiptsPref
            } catch {
                Log.error("Error loading photo preferences: \(error)")
            }
        }
    }

    private func observe() {
        messagesListRepository.startObserving()
        setupTypingIndicatorHandler()
        setupVoiceMemoPlaybackObserver()
        observeCapabilityRequests()
        messagesListRepository.messagesListPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self else { return }
                self.clearTypingForNewMessages(old: self.messages, new: messages)
                let messageCount = messages.countMessages
                let messagesChanged = messageCount != self.lastMessageCountForReadReceipt
                self.lastMessageCountForReadReceipt = messageCount
                self.messages = messages
                self.scheduleVoiceMemoTranscriptionsIfNeeded(in: messages)
                if messagesChanged {
                    self.sendReadReceiptIfNeeded()
                }
            }
            .store(in: &cancellables)

        conversationRepository.conversationPublisher
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] conversation in
                guard let self else { return }
                let previousId = self.conversation.id
                let wasViewingConversation = self.isViewingConversation
                self.conversation = conversation
                self.loadConversationImage(for: conversation)
                if conversation.id != previousId {
                    self.observePhotoPreferences(for: conversation.id)
                    self.loadPhotoPreferences()
                    self.observeCapabilityRequests(for: conversation.id)
                    if wasViewingConversation {
                        self.isViewingConversation = true
                        self.sendReadReceiptIfNeeded()
                    }
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

    private func observeCapabilityRequests() {
        observeCapabilityRequests(for: conversation.id)
    }

    private func observeCapabilityRequests(for conversationId: String) {
        guard conversationId != observedCapabilityRequestsConversationId else { return }
        observedCapabilityRequestsConversationId = conversationId

        let registry = session.capabilityProviderRegistry()
        let resolver = session.capabilityResolver()
        let handler = CapabilityRequestHandler()
        pendingCapabilityPickerLayout = nil
        latestObservedCapabilityRequest = nil
        locallyHandledCapabilityRequestIds.removeAll()
        capabilityRequestsCancellable?.cancel()
        capabilityRequestsCancellable = session.capabilityRequestRepository(for: conversationId)
            .pendingRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self else { return }
                // The user already approved/denied this request locally — keep the picker
                // hidden until the result row lands and the publisher emits a different
                // request (or nil). Without this guard, an unrelated DB change between the
                // tap and the result write re-emits the same pending request and revives
                // the card.
                if let request, self.locallyHandledCapabilityRequestIds.contains(request.requestId) {
                    return
                }
                self.latestObservedCapabilityRequest = request
                guard let request else {
                    self.pendingCapabilityPickerLayout = nil
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let layout = await handler.computeLayout(
                        request: request,
                        registry: registry,
                        resolver: resolver,
                        conversationId: conversationId
                    )
                    // Discard if a newer request arrived while we were computing —
                    // otherwise an out-of-order completion can stomp the latest UI.
                    guard self.latestObservedCapabilityRequest == request else { return }
                    // Also discard if the user already approved/denied this exact request
                    // locally between when this Task was spawned and now. The early-return
                    // on re-emission at the top of `sink` doesn't update
                    // `latestObservedCapabilityRequest`, so the staleness check above can't
                    // see that the user already answered.
                    guard !self.locallyHandledCapabilityRequestIds.contains(request.requestId) else { return }
                    self.pendingCapabilityPickerLayout = layout
                }
            }
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
                setAutoRevealPhotosLocally(prefs?.autoReveal ?? defaultAutoRevealForNewConversation)
                let readReceiptsPref = prefs?.sendReadReceipts ?? GlobalConvoDefaults.shared.sendReadReceipts
                sendReadReceipts = readReceiptsPref
                messagesListRepository.sendReadReceipts = readReceiptsPref
            }
    }

    private var defaultAutoRevealForNewConversation: Bool {
        applyGlobalDefaultsForNewConversation ? GlobalConvoDefaults.shared.autoRevealPhotos : false
    }

    private func applyGlobalDefaultsForDraftConversationIfNeeded() {
        guard applyGlobalDefaultsForNewConversation else { return }
        guard conversation.isDraft else { return }
        _editingIncludeInfoInPublicPreview = GlobalConvoDefaults.shared.includeInfoWithInvites
    }

    private func setAutoRevealPhotosLocally(_ autoReveal: Bool) {
        autoRevealPhotos = autoReveal
    }

    func setSendReadReceipts(_ value: Bool) {
        sendReadReceipts = value
        messagesListRepository.sendReadReceipts = value
        Task { [weak self] in
            guard let self else { return }
            do {
                try await photoPreferencesWriter.setSendReadReceipts(value, for: conversation.id)
            } catch {
                Log.error("Error setting sendReadReceipts: \(error)")
            }
        }
    }

    private func setAutoRevealPhotosPersisted(_ autoReveal: Bool) {
        guard autoRevealPhotos != autoReveal else { return }
        autoRevealPhotos = autoReveal
        persistAutoReveal(autoReveal)
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
        // Draft ids are ephemeral placeholders (e.g. "draft-<UUID>"). Running the
        // coordinator against them would write hasSetProfileForConversation_<uuid>
        // flags that are never read again — the real id arrives later via the
        // conversation publisher and triggers startOnboarding from didSet.
        guard !conversation.isDraft else { return }
        Task { @MainActor in
            await onboardingCoordinator.start(
                for: conversation.id,
                isConversationCreator: conversation.creator.isCurrentUser
            )
        }
    }

    func inviteWasAccepted() {
        Task { @MainActor in
            await onboardingCoordinator.inviteWasAccepted(for: conversation.id)
        }
    }

    // MARK: - Capability picker

    /// Replaces any pending capability request with `layout`. When the agent sends a new
    /// `capability_request` and we want the picker to display, the host computes the
    /// layout via `CapabilityRequestHandler.computeLayout` and calls this. Setting nil
    /// hides the picker and lets the onboarding view take its slot back.
    func presentCapabilityPicker(_ layout: CapabilityPickerLayout?) {
        pendingCapabilityPickerLayout = layout
    }

    /// User tapped Approve in the picker card with this provider selection.
    /// Persists the resolution so future tool calls route to the same set, then
    /// posts a `capability_request_result(.approved)` reply for the agent.
    func onCapabilityApprove(providerIds: Set<ProviderID>) {
        guard let request = pendingCapabilityPickerLayout?.request else {
            pendingCapabilityPickerLayout = nil
            return
        }
        approveCapabilityRequest(request, providerIds: providerIds, conversationId: conversation.id)
    }

    /// User tapped Deny. Clears any prior resolution for this verb so a subsequent
    /// tool call doesn't silently route through stale state, then posts a
    /// `capability_request_result(.denied)` reply for the agent.
    func onCapabilityDeny() {
        guard let request = pendingCapabilityPickerLayout?.request else {
            pendingCapabilityPickerLayout = nil
            return
        }
        denyCapabilityRequest(request, conversationId: conversation.id)
    }

    private func approveCapabilityRequest(
        _ request: CapabilityRequest,
        providerIds: Set<ProviderID>,
        conversationId: String
    ) {
        locallyHandledCapabilityRequestIds.insert(request.requestId)
        // Only dismiss the picker if it's still showing *this* request — a newer
        // request might have arrived during the async hop and replaced the layout,
        // and we mustn't blow that one away on the old request's behalf.
        if pendingCapabilityPickerLayout?.request.requestId == request.requestId {
            pendingCapabilityPickerLayout = nil
        }
        sendCapabilityResult(
            request: request,
            status: .approved,
            providerIds: providerIds,
            conversationId: conversationId
        )
    }

    private func denyCapabilityRequest(_ request: CapabilityRequest, conversationId: String) {
        locallyHandledCapabilityRequestIds.insert(request.requestId)
        if pendingCapabilityPickerLayout?.request.requestId == request.requestId {
            pendingCapabilityPickerLayout = nil
        }
        sendCapabilityResult(
            request: request,
            status: .denied,
            providerIds: [],
            conversationId: conversationId
        )
    }

    private func sendCapabilityResult(
        request: CapabilityRequest,
        status: CapabilityRequestResult.Status,
        providerIds: Set<ProviderID>,
        conversationId: String
    ) {
        let resolver = session.capabilityResolver()
        let writer = messagingService.capabilityRequestResultWriter()
        Task {
            // The agent's contract is that a result is *always* posted — even cancel
            // and deny — so we keep going on a resolver-side error and let the agent
            // see the user's intent. Local persistence failure is logged and surfaced
            // separately if it ever needs UI surfacing; it must not strand the agent.
            //
            // Snapshot the resolver's current providerIds for this (subject, verb,
            // conversation) tuple before mutating it. The diff (`newlyApprovedProviderIds`)
            // is what the cloud persist path uses to decide whether to fire a
            // connection_event — fan-in semantics are per-(provider, verb), so a
            // second verb approval on a provider already granted at the connection
            // level still needs its own group-update line.
            let askerInboxId = request.askerInboxId
            let previouslyApproved: Set<ProviderID>
            if status == .approved {
                previouslyApproved = await resolver.resolution(
                    subject: request.subject,
                    capability: request.capability,
                    conversationId: conversationId,
                    grantedToInboxId: askerInboxId
                )
            } else {
                previouslyApproved = []
            }
            let newlyApprovedProviderIds = providerIds.subtracting(previouslyApproved)

            do {
                switch status {
                case .approved:
                    try await resolver.setResolution(
                        providerIds,
                        subject: request.subject,
                        capability: request.capability,
                        conversationId: conversationId,
                        grantedToInboxId: askerInboxId
                    )
                case .denied, .cancelled:
                    try await resolver.clearResolution(
                        subject: request.subject,
                        capability: request.capability,
                        conversationId: conversationId,
                        grantedToInboxId: askerInboxId
                    )
                }
            } catch {
                Log.error("Capability resolver update failed (still posting result to agent): \(error.localizedDescription)")
            }

            let availableActions = await self.availableActions(
                for: providerIds.sorted(by: { $0.rawValue < $1.rawValue }),
                capability: request.capability
            )
            let result = CapabilityRequestResult(
                requestId: request.requestId,
                status: status,
                subject: request.subject,
                capability: request.capability,
                providers: providerIds.sorted(by: { $0.rawValue < $1.rawValue }),
                availableActions: availableActions
            )
            if status == .approved {
                let sortedIds = providerIds.sorted(by: { $0.rawValue < $1.rawValue })
                await Self.persistApprovedDeviceCapabilities(
                    providerIds: sortedIds,
                    capability: request.capability,
                    conversationId: conversationId,
                    grantedToInboxId: askerInboxId,
                    session: session
                )
                await Self.persistApprovedCloudCapabilities(
                    providerIds: sortedIds,
                    newlyApprovedProviderIds: newlyApprovedProviderIds,
                    capability: request.capability,
                    conversationId: conversationId,
                    grantedToInboxId: askerInboxId,
                    session: session
                )
            }

            do {
                try await writer.sendResult(result, in: conversationId)
                if status == .approved {
                    await MainActor.run { [weak self] in
                        self?.flashCapabilityApprovedToast()
                    }
                }
            } catch {
                Log.error("Failed to send capability_request_result: \(error.localizedDescription)")
            }
        }
    }

    private func availableActions(
        for providerIds: [ProviderID],
        capability: ConnectionCapability
    ) async -> [CapabilityRequestResult.AvailableAction] {
        var actions: [CapabilityRequestResult.AvailableAction] = []

        for providerId in providerIds {
            if let kind = ConnectionKind.fromDeviceProviderId(providerId),
               let source = await Self.deviceActionSchemas(for: kind) {
                let schemas = source
                    .filter { $0.capability == capability }
                    .sorted(by: { $0.actionName < $1.actionName })
                actions.append(contentsOf: schemas.map {
                    CapabilityRequestResult.AvailableAction(
                        providerId: providerId,
                        kind: kind,
                        actionName: $0.actionName,
                        summary: $0.summary,
                        inputs: $0.inputs.map(Self.capabilityActionParameter(from:)),
                        outputs: $0.outputs.map(Self.capabilityActionParameter(from:))
                    )
                })
                continue
            }
        }

        return actions.sorted {
            if $0.providerId.rawValue != $1.providerId.rawValue {
                return $0.providerId.rawValue < $1.providerId.rawValue
            }
            return $0.actionName < $1.actionName
        }
    }

    private static func deviceActionSchemas(for kind: ConnectionKind) async -> [ActionSchema]? {
        switch kind {
        case .calendar:
            return await CalendarDataSink().actionSchemas()
        case .contacts:
            return await ContactsDataSink().actionSchemas()
        case .photos:
            return await PhotosDataSink().actionSchemas()
        case .health:
            return await HealthDataSink().actionSchemas()
        case .music:
            return await MusicDataSink().actionSchemas()
        case .homeKit:
            return await HomeKitDataSink().actionSchemas()
        case .location, .motion, .screenTime:
            return nil
        }
    }

    private static func persistApprovedDeviceCapabilities(
        providerIds: [ProviderID],
        capability: ConnectionCapability,
        conversationId: String,
        grantedToInboxId: String,
        session: any SessionManagerProtocol
    ) async {
        let store = session.connectionEnablementStore()
        let eventWriter = session.messagingService().connectionEventWriter()
        for providerId in providerIds {
            guard let kind = ConnectionKind.fromDeviceProviderId(providerId) else { continue }
            let wasEnabled = await store.isEnabled(
                kind: kind,
                capability: capability,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId
            )
            await store.setEnabled(
                true,
                kind: kind,
                capability: capability,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId
            )
            if !wasEnabled {
                try? await eventWriter.sendGranted(
                    providerId: providerId.rawValue,
                    capability: capability,
                    grantedToInboxId: grantedToInboxId,
                    in: conversationId
                )
            }
        }
    }

    /// For each approved `composio.<service>` provider, ensure a per-conversation
    /// `CloudConnectionGrant` exists against the matching active `CloudConnection` and
    /// emit a `connection_event granted` if the grant is newly created. Skips providers
    /// whose CloudConnection isn't active locally — those would have been created by the
    /// caller (e.g. picker → connectCloudProvider) and the publisher snapshot taken here
    /// races against that path; if we miss it the next sync corrects state.
    private static func persistApprovedCloudCapabilities(
        providerIds: [ProviderID],
        newlyApprovedProviderIds: Set<ProviderID>,
        capability: ConnectionCapability,
        conversationId: String,
        grantedToInboxId: String,
        session: any SessionManagerProtocol
    ) async {
        let messagingService = session.messagingService()
        let grantWriter = messagingService.connectionGrantWriter()
        let eventWriter = messagingService.connectionEventWriter()
        let repository = session.cloudConnectionRepository()
        let activeConnections = (try? await repository.connections()) ?? []
        let existingGrants = (try? await repository.grants(for: conversationId)) ?? []
        let existingGrantedKeys = Set(existingGrants.map { GrantKey(connectionId: $0.connectionId, grantedToInboxId: $0.grantedToInboxId) })

        for providerId in providerIds {
            guard let serviceId = providerId.cloudServiceId else { continue }
            guard let connection = activeConnections.first(where: { $0.serviceId == serviceId }) else { continue }

            // The grant row is per-(connection, conversation, agent). Two agents
            // approved for the same connection get two rows; the same agent re-
            // approving the same connection is a no-op for the grant write but
            // still needs its own connection_event.
            let grantKey = GrantKey(connectionId: connection.id, grantedToInboxId: grantedToInboxId)
            if !existingGrantedKeys.contains(grantKey) {
                do {
                    try await grantWriter.grantConnection(
                        connection.id,
                        to: conversationId,
                        grantedToInboxId: grantedToInboxId
                    )
                } catch {
                    Log.error("Failed to persist cloud grant for \(providerId.rawValue) → \(grantedToInboxId): \(error.localizedDescription)")
                    continue
                }
            }

            // Fan-in is per-(providerId, verb): if the resolver already had
            // this providerId for this verb (re-approval after deny, picker
            // shown twice), don't echo a duplicate group-update message.
            guard newlyApprovedProviderIds.contains(providerId) else { continue }
            try? await eventWriter.sendGranted(
                providerId: providerId.rawValue,
                capability: capability,
                grantedToInboxId: grantedToInboxId,
                in: conversationId
            )
        }
    }

    private struct GrantKey: Hashable {
        let connectionId: String
        let grantedToInboxId: String
    }

    private static func capabilityActionParameter(
        from parameter: ActionParameter
    ) -> CapabilityRequestResult.Parameter {
        CapabilityRequestResult.Parameter(
            name: parameter.name,
            type: capabilityActionParameterType(parameter.type),
            description: parameter.description,
            isRequired: parameter.isRequired
        )
    }

    private static func capabilityActionParameterType(_ type: ActionParameter.ParameterType) -> String {
        switch type {
        case .string:
            return "string"
        case .bool:
            return "bool"
        case .int:
            return "int"
        case .double:
            return "double"
        case .date:
            return "date"
        case .iso8601DateTime:
            return "iso8601"
        case .enumValue(let allowed):
            return "enum(\(allowed.joined(separator: ",")))"
        case .arrayOf(let element):
            return "array<\(capabilityActionParameterType(element))>"
        }
    }

    private func flashCapabilityApprovedToast() {
        showsCapabilityApprovedToast = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.0))
            await MainActor.run { [weak self] in
                self?.showsCapabilityApprovedToast = false
            }
        }
    }

    /// User tapped a Connect row. Routes to the matching path for the provider's
    /// kind: device providers go through `DeviceConnectionAuthorizer` for the iOS
    /// permission prompt, cloud providers run OAuth via `CloudConnectionManager`.
    /// On success either path treats the connect tap itself as the user's approval —
    /// they came to this card from a `capability_request`, just granted access, and
    /// would otherwise have to tap Approve again on the same card. On cancel/decline
    /// the picker recomputes so the user can pick a different provider or deny.
    func onCapabilityConnect(providerId: ProviderID) {
        if let kind = ConnectionKind.fromDeviceProviderId(providerId) {
            connectDeviceProvider(kind: kind, providerId: providerId)
            return
        }
        if let serviceId = providerId.cloudServiceId {
            connectCloudProvider(serviceId: serviceId, providerId: providerId)
            return
        }
        Log.warning("Unsupported provider for Connect: \(providerId.rawValue)")
    }

    private func connectDeviceProvider(kind: ConnectionKind, providerId: ProviderID) {
        guard let request = pendingCapabilityPickerLayout?.request else { return }
        let conversationId = conversation.id
        let session = self.session
        let registry = session.capabilityProviderRegistry()
        let authorizer = session.deviceConnectionAuthorizer()
        Task { [weak self] in
            do {
                _ = try await authorizer.requestAuthorization(for: kind)
            } catch {
                Log.error("Authorization request failed for \(kind.rawValue): \(error.localizedDescription)")
            }
            let status = await authorizer.currentAuthorization(for: kind)
            let isLinked = status.canDeliverData
            if let spec = DeviceCapabilityProvider.defaultSpecs.first(where: { $0.kind == kind }) {
                // Capture authorizer + kind, not a fixed Bool — the user can revoke
                // permission in Settings later, and the registry needs the live state.
                let updated = DeviceCapabilityProvider(
                    id: spec.id,
                    subject: spec.subject,
                    displayName: spec.displayName,
                    iconName: spec.iconName,
                    capabilities: spec.capabilities,
                    subjectNounPhrase: spec.subjectNounPhrase,
                    linkedByUser: {
                        await authorizer.currentAuthorization(for: kind).canDeliverData
                    }
                )
                await registry.register(updated)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if isLinked {
                    // Always approve the *captured* request — a newer request might
                    // have arrived during the OS prompt and replaced the picker
                    // layout's request, and we must not approve it on its behalf.
                    // Also pass the captured conversationId so the result lands in
                    // the conversation that originated the request even if the user
                    // navigated away during the prompt.
                    self.approveCapabilityRequest(request, providerIds: [providerId], conversationId: conversationId)
                } else {
                    self.recomputeCapabilityPickerLayout(for: request, conversationId: conversationId)
                }
            }
        }
    }

    private func connectCloudProvider(serviceId: String, providerId: ProviderID) {
        guard let request = pendingCapabilityPickerLayout?.request else { return }
        let conversationId = conversation.id
        let manager = session.cloudConnectionManager(callbackURLScheme: ConfigManager.shared.appUrlScheme)
        Task { [weak self] in
            do {
                _ = try await manager.connect(serviceId: serviceId)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // The cloud-connection observer in SessionManager will register the
                    // newly-linked provider; approving here is safe even if that hasn't
                    // ticked yet because the resolver only stores the providerId.
                    self.approveCapabilityRequest(request, providerIds: [providerId], conversationId: conversationId)
                }
            } catch let oauthError as OAuthError {
                if case .cancelled = oauthError {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.recomputeCapabilityPickerLayout(for: request, conversationId: conversationId)
                    }
                } else {
                    Log.error("OAuth failed for \(serviceId): \(oauthError.localizedDescription)")
                }
            } catch {
                Log.error("Cloud connect failed for \(serviceId): \(error.localizedDescription)")
            }
        }
    }

    private func recomputeCapabilityPickerLayout(for request: CapabilityRequest, conversationId: String) {
        let registry = session.capabilityProviderRegistry()
        let resolver = session.capabilityResolver()
        let handler = CapabilityRequestHandler()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let layout = await handler.computeLayout(
                request: request,
                registry: registry,
                resolver: resolver,
                conversationId: conversationId
            )
            // If a newer request arrived OR the user already approved/denied this one,
            // don't revive the picker with a stale layout.
            guard self.latestObservedCapabilityRequest == request,
                  !self.locallyHandledCapabilityRequestIds.contains(request.requestId) else {
                return
            }
            self.pendingCapabilityPickerLayout = layout
        }
    }

    func onConversationInfoTap(focusCoordinator: FocusCoordinator) {
        guard !isWaitingForInviteAcceptance else { return }
        if conversation.shouldShowQuickEdit {
            focusCoordinator.moveFocus(to: .conversationName)
        } else {
            presentingConversationSettings = true
        }
    }

    func onConversationInfoLongPress(focusCoordinator: FocusCoordinator) {
        guard !isWaitingForInviteAcceptance else { return }
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

    func addFileAttachment(url: URL, filename: String, mimeType: String, fileSize: Int) {
        guard canStageMoreMedia else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let attachment = PendingFileAttachment(url: url, filename: filename, mimeType: mimeType, fileSize: fileSize)
        pendingMediaAttachments.append(.file(attachment))
    }

    func addVideoAttachment(url: URL) {
        guard canStageMoreMedia else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let attachment = PendingVideoAttachment(url: url)
        let attachmentId = attachment.id
        pendingMediaAttachments.append(.video(attachment))

        videoThumbnailTasks[attachmentId] = Task { [weak self] in
            do {
                let service = VideoCompressionService()
                let asset = AVURLAsset(url: url)
                let thumbnailData = try await service.generateThumbnail(for: asset)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard let index = self.pendingMediaAttachments.firstIndex(where: { $0.id == attachmentId }),
                          case .video(var video) = self.pendingMediaAttachments[index] else { return }
                    video.thumbnail = UIImage(data: thumbnailData)
                    self.pendingMediaAttachments[index] = .video(video)
                    self.videoThumbnailTasks.removeValue(forKey: attachmentId)
                }
            } catch {
                Log.error("Failed to generate video thumbnail: \(error)")
            }
        }

        let messageWriter = cachedMessageWriter
        Task { [weak self] in
            do {
                let trackingKey = try await messageWriter.startEagerVideoUpload(at: url)
                await MainActor.run {
                    guard let self else { return }
                    guard let index = self.pendingMediaAttachments.firstIndex(where: { $0.id == attachmentId }),
                          case .video(var video) = self.pendingMediaAttachments[index] else {
                        // User removed the attachment before the eager upload tracking
                        // key was written back. Cancel the in-flight pipeline.
                        Task { await messageWriter.cancelEagerUpload(trackingKey: trackingKey) }
                        return
                    }
                    video.eagerUploadKey = trackingKey
                    self.pendingMediaAttachments[index] = .video(video)
                }
            } catch {
                Log.error("Error starting eager video upload: \(error)")
            }
        }
        onPhotoAttached()
    }

    func addPhotoAttachment(_ image: UIImage) {
        guard canStageMoreMedia else { return }
        let attachment = PendingPhotoAttachment(image: image)
        let attachmentId = attachment.id
        pendingMediaAttachments.append(.photo(attachment))

        let messageWriter = cachedMessageWriter
        Task { [weak self] in
            do {
                let trackingKey = try await messageWriter.startEagerUpload(image: image)
                await MainActor.run {
                    guard let self else { return }
                    guard let index = self.pendingMediaAttachments.firstIndex(where: { $0.id == attachmentId }),
                          case .photo(var photo) = self.pendingMediaAttachments[index] else {
                        // User removed the attachment before upload started. Cancel the upload.
                        Task { await messageWriter.cancelEagerUpload(trackingKey: trackingKey) }
                        return
                    }
                    photo.eagerUploadKey = trackingKey
                    self.pendingMediaAttachments[index] = .photo(photo)
                }
            } catch {
                Log.error("Error starting eager upload: \(error)")
            }
        }
        onPhotoAttached()
    }

    func removeMediaAttachment(id: UUID) {
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = pendingMediaAttachments.remove(at: index)
        cleanupAttachment(attachment)
    }

    private func cleanupAttachment(_ attachment: PendingMediaAttachment) {
        switch attachment {
        case .photo(let photo):
            if let trackingKey = photo.eagerUploadKey {
                let messageWriter = cachedMessageWriter
                Task { await messageWriter.cancelEagerUpload(trackingKey: trackingKey) }
            }
        case .video(let video):
            videoThumbnailTasks[video.id]?.cancel()
            videoThumbnailTasks.removeValue(forKey: video.id)
            if let trackingKey = video.eagerUploadKey {
                let messageWriter = cachedMessageWriter
                Task { await messageWriter.cancelEagerUpload(trackingKey: trackingKey) }
            } else {
                // Pipeline hadn't returned a tracking key yet; the source temp is
                // still ours to clean up.
                try? FileManager.default.removeItem(at: video.url)
            }
        case .file(let file):
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    func setupVoiceMemoPlaybackObserver() {
        NotificationCenter.default.removeObserver(self, name: .voiceMemoPlaybackRequested, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVoiceMemoPlaybackRequested(_:)),
            name: .voiceMemoPlaybackRequested,
            object: nil
        )
    }

    @objc
    private func handleVoiceMemoPlaybackRequested(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let messageId = userInfo["messageId"] as? String,
              let attachmentKey = userInfo["attachmentKey"] as? String else { return }

        voiceMemoPlaybackTask?.cancel()
        voiceMemoPlaybackTask = Task { @MainActor in
            let player = VoiceMemoPlayer.shared
            if player.currentlyPlayingMessageId == messageId {
                if player.state == .playing {
                    player.pause()
                    return
                } else if player.state == .paused {
                    player.resume()
                    return
                }
            }

            do {
                let loader = RemoteAttachmentLoader()
                let loaded = try await loader.loadAttachmentData(from: attachmentKey)
                guard !Task.isCancelled else { return }
                try player.play(data: loaded.data, messageId: messageId)
            } catch is CancellationError {
                return
            } catch {
                Log.error("Failed to play voice memo: \(error)")
            }
        }
    }

    func onVoiceMemoTapped() {
        guard case .idle = voiceMemoRecorder.state else { return }
        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
            do {
                try voiceMemoRecorder.startRecording()
            } catch {
                Log.error("Failed to start voice memo recording: \(error)")
            }
        }
    }

    func sendVoiceMemo() {
        guard case .recorded(let url, let duration) = voiceMemoRecorder.state else { return }
        let levels = voiceMemoRecorder.audioLevels
        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
            voiceMemoRecorder.resetState()
        }

        let messageWriter = cachedMessageWriter
        let replyTarget = replyingToMessage
        replyingToMessage = nil

        Task {
            do {
                _ = try await messageWriter.sendVoiceMemo(
                    at: url,
                    duration: duration,
                    waveformLevels: levels.isEmpty ? nil : levels,
                    replyToMessageId: replyTarget?.messageId
                )
            } catch {
                Log.error("Error sending voice memo: \(error)")
            }
        }
    }

    func onSendMessage(focusCoordinator: FocusCoordinator) {
        let hasText = !messageText.isEmpty
        let hasMedia = !pendingMediaAttachments.isEmpty
        let hasInvite = pendingInvite != nil
        let hasLinkPreview = pastedLinkPreview != nil

        guard hasText || hasMedia || hasInvite || hasLinkPreview else { return }

        let prevMessageText = messageText
        let replyTarget = replyingToMessage
        let prevMediaAttachments = pendingMediaAttachments
        let prevInviteURL = pendingInvite?.fullURL
        let sideConvoName = pendingInviteConvoName
        let sideConvoLinkedId = pendingInvite?.linkedConversationId
        let sideConvoExplodeDuration = pendingInvite?.explodeDuration
        let sideConvoImage = pendingInviteImage
        let prevLinkURL = pastedLinkPreview?.url

        stopTyping()
        messageText = ""
        replyingToMessage = nil
        pendingMediaAttachments = []
        videoThumbnailTasks.values.forEach { $0.cancel() }
        videoThumbnailTasks.removeAll()
        pendingInvite = nil
        pendingInviteConvoName = ""
        pendingInviteImage = nil
        pastedLinkPreview = nil
        focusCoordinator.endEditing(for: .message, context: .conversation)

        let messageWriter = cachedMessageWriter

        Task { [weak self] in
            guard let self else { return }

            let sideConvoResult = await finalizeSideConvo(
                inviteURL: prevInviteURL,
                name: sideConvoName,
                image: sideConvoImage,
                explodeDuration: sideConvoExplodeDuration,
                linkedId: sideConvoLinkedId,
                messageWriter: messageWriter
            )
            let inviteURL = sideConvoResult.inviteURL
            let pendingInviteMessageId = sideConvoResult.pendingMessageId

            do {
                // Send each media attachment as its own message, in bar order.
                // The first attachment carries the reply target (if any); subsequent
                // attachments and trailing text/invite/link are not replies.
                let mediaTookReply = try await sendMediaAttachmentsSequentially(
                    prevMediaAttachments,
                    replyTarget: replyTarget,
                    messageWriter: messageWriter
                )

                let trailingReplyTarget: AnyMessage? = mediaTookReply ? nil : replyTarget
                let finalInviteURL = pendingInviteMessageId != nil ? nil : inviteURL
                try await sendTextAndLinksIfNeeded(
                    text: hasText ? prevMessageText : nil,
                    inviteURL: finalInviteURL,
                    linkURL: prevLinkURL,
                    photoTrackingKey: nil,
                    replyTarget: trailingReplyTarget,
                    messageWriter: messageWriter
                )
            } catch {
                Log.error("Error sending message: \(error)")
            }

            isSendingMedia = false
        }
    }

    private func finalizeSideConvo(
        inviteURL: String?,
        name: String,
        image: UIImage?,
        explodeDuration: ExplodeDuration?,
        linkedId: String?,
        messageWriter: any OutgoingMessageWriterProtocol
    ) async -> (inviteURL: String?, pendingMessageId: String?) {
        var inviteURL = inviteURL
        var pendingMessageId: String?

        guard let linkedId else {
            return (inviteURL, nil)
        }

        do {
            let messagingService = session.messagingService()
            let metadataWriter = messagingService.conversationMetadataWriter()
            try await metadataWriter.updateIncludeInfoInPublicPreview(true, for: linkedId)
            if !name.isEmpty {
                try await metadataWriter.updateName(name, for: linkedId)
            }
            if let explodeDuration {
                let explosionWriter = messagingService.conversationExplosionWriter()
                let expiresAt = Date().addingTimeInterval(explodeDuration.timeInterval)
                try await explosionWriter.scheduleExplosion(conversationId: linkedId, expiresAt: expiresAt)
            }
            if let updatedInvite = try await metadataWriter.refreshInvite(for: linkedId) {
                inviteURL = updatedInvite.inviteURLString
            }
        } catch {
            Log.error("Failed to finalize side convo metadata: \(error)")
        }

        guard let image, let inviteURL else {
            return (inviteURL, nil)
        }

        if let invite = MessageInvite.from(text: inviteURL) {
            ImageCache.shared.cacheAfterUpload(image, for: invite, url: invite.imageURL?.absoluteString ?? invite.inviteSlug)
        }
        pendingMessageId = try? await messageWriter.insertPendingInvite(text: inviteURL)

        do {
            let messagingService = session.messagingService()
            let metadataWriter = messagingService.conversationMetadataWriter()
            let stateManager = messagingService.conversationStateManager(for: linkedId)
            if let convo = try stateManager.draftConversationRepository.fetchConversation() {
                try await metadataWriter.updateImage(image, for: convo)
                try await metadataWriter.updateIncludeInfoInPublicPreview(true, for: linkedId)
                if !name.isEmpty {
                    try await metadataWriter.updateName(name, for: linkedId)
                }
                if let updatedInvite = try await metadataWriter.refreshInvite(for: linkedId),
                   let pendingMessageId {
                    try await messageWriter.finalizeInvite(clientMessageId: pendingMessageId, finalText: updatedInvite.inviteURLString)
                }
            }
        } catch {
            Log.error("Failed to upload side convo image: \(error)")
            if let pendingMessageId {
                do {
                    try await messageWriter.finalizeInvite(clientMessageId: pendingMessageId, finalText: inviteURL)
                } catch {
                    // Even though the fallback finalize failed, the pending
                    // invite row still exists in the DB — returning nil here
                    // would signal "caller should send the invite" and cause
                    // a duplicate send. Keep returning the pendingMessageId
                    // so the caller treats the invite as already in flight;
                    // the dangling pending row will surface through the
                    // normal retry/failure UI.
                    Log.error("Failed to finalize side convo invite fallback: \(error)")
                }
            }
        }

        return (inviteURL, pendingMessageId)
    }

    /// Send each staged media attachment as its own message, in bar order, awaiting each
    /// publish so they arrive in order on the recipient. The first attachment carries the
    /// reply target (if any). Returns true if a media attachment was sent and consumed
    /// the reply target.
    ///
    /// If any attachment fails, the chain stops — that attachment surfaces as a failed
    /// bubble via the existing markMessageFailed path inside the writer; subsequent
    /// attachments and the trailing text/invite/link are not sent.
    private func sendMediaAttachmentsSequentially(
        _ attachments: [PendingMediaAttachment],
        replyTarget: AnyMessage?,
        messageWriter: any OutgoingMessageWriterProtocol
    ) async throws -> Bool {
        guard !attachments.isEmpty else { return false }
        isSendingMedia = true

        var consumedReply = false
        var nextIndex: Int = 0
        do {
            for (index, attachment) in attachments.enumerated() {
                nextIndex = index + 1
                let attachmentReplyId: String? = consumedReply ? nil : replyTarget?.messageId
                switch attachment {
                case .photo(let photo):
                    try await sendStagedPhoto(photo, replyToMessageId: attachmentReplyId, messageWriter: messageWriter)
                case .video(let video):
                    try await sendStagedVideo(video, replyToMessageId: attachmentReplyId, messageWriter: messageWriter)
                case .file(let file):
                    _ = try await messageWriter.sendFile(
                        at: file.url,
                        filename: file.filename,
                        mimeType: file.mimeType,
                        replyToMessageId: attachmentReplyId
                    )
                    try? FileManager.default.removeItem(at: file.url)
                }
                consumedReply = true
            }
            return true
        } catch {
            // Include the failed attachment (at nextIndex - 1) so its eager upload
            // tracking key gets cancelled / its temp file gets deleted alongside the
            // unsent rest.
            let failedAndUnsentStart: Int = max(0, nextIndex - 1)
            for unsent in attachments[failedAndUnsentStart...] {
                cleanupAttachment(unsent)
            }
            throw error
        }
    }

    private func sendStagedPhoto(
        _ photo: PendingPhotoAttachment,
        replyToMessageId: String?,
        messageWriter: any OutgoingMessageWriterProtocol
    ) async throws {
        // Reuse the eager upload that started when the photo was staged, falling back to
        // a fresh start if the upload hadn't kicked off yet (race: user staged + sent
        // before the eager-upload task had a chance to write back the tracking key).
        let trackingKey: String
        let isFreshKey: Bool
        if let existing = photo.eagerUploadKey {
            trackingKey = existing
            isFreshKey = false
        } else {
            trackingKey = try await messageWriter.startEagerUpload(image: photo.image)
            isFreshKey = true
        }
        do {
            if let replyToMessageId {
                try await messageWriter.sendEagerPhotoReply(trackingKey: trackingKey, toMessageWithClientId: replyToMessageId)
            } else {
                try await messageWriter.sendEagerPhoto(trackingKey: trackingKey)
            }
        } catch {
            // The freshly-obtained key isn't on the PendingPhotoAttachment yet,
            // so cleanupAttachment in the outer catch wouldn't know to cancel
            // it. Cancel directly so the pipeline doesn't orphan resources.
            if isFreshKey {
                await messageWriter.cancelEagerUpload(trackingKey: trackingKey)
            }
            throw error
        }
    }

    private func sendStagedVideo(
        _ video: PendingVideoAttachment,
        replyToMessageId: String?,
        messageWriter: any OutgoingMessageWriterProtocol
    ) async throws {
        // Reuse the eager pipeline started at staging time, falling back to a
        // fresh start if Send happened before the tracking key was written back.
        let trackingKey: String
        let isFreshKey: Bool
        if let existing = video.eagerUploadKey {
            trackingKey = existing
            isFreshKey = false
        } else {
            trackingKey = try await messageWriter.startEagerVideoUpload(at: video.url)
            isFreshKey = true
        }
        do {
            if let replyToMessageId {
                try await messageWriter.sendEagerVideoReply(trackingKey: trackingKey, toMessageWithClientId: replyToMessageId)
            } else {
                try await messageWriter.sendEagerVideo(trackingKey: trackingKey)
            }
        } catch {
            // The freshly-obtained key isn't on the PendingVideoAttachment yet,
            // so cleanupAttachment in the outer catch wouldn't know to cancel
            // it. Cancel directly so the pipeline doesn't orphan resources.
            if isFreshKey {
                await messageWriter.cancelEagerUpload(trackingKey: trackingKey)
            }
            throw error
        }
    }

    private func sendTextAndLinksIfNeeded(
        text: String?,
        inviteURL: String?,
        linkURL: String?,
        photoTrackingKey: String?,
        replyTarget: AnyMessage?,
        messageWriter: any OutgoingMessageWriterProtocol
    ) async throws {
        let hasAttachment = photoTrackingKey != nil

        if let inviteURL {
            if replyTarget != nil && !hasAttachment && text == nil, let replyTarget {
                try await messageWriter.sendReply(text: inviteURL, afterPhoto: photoTrackingKey, toMessageWithClientId: replyTarget.messageId)
            } else {
                try await messageWriter.send(text: inviteURL, afterPhoto: photoTrackingKey)
            }
        }

        if let linkURL {
            if replyTarget != nil && !hasAttachment && text == nil && inviteURL == nil, let replyTarget {
                try await messageWriter.sendReply(text: linkURL, afterPhoto: photoTrackingKey, toMessageWithClientId: replyTarget.messageId)
            } else {
                try await messageWriter.send(text: linkURL, afterPhoto: photoTrackingKey)
            }
        }

        if let text {
            if replyTarget != nil && !hasAttachment, let replyTarget {
                try await messageWriter.sendReply(text: text, afterPhoto: photoTrackingKey, toMessageWithClientId: replyTarget.messageId)
            } else {
                try await messageWriter.send(text: text, afterPhoto: photoTrackingKey)
            }
        }
    }

    var replyingToAudioTranscriptText: String? {
        guard let replyingToMessage,
              replyingToMessage.content.primaryVoiceMemoAttachment != nil
        else { return nil }
        for item in messages {
            guard case .messages(let group) = item else { continue }
            if let transcript = group.voiceMemoTranscripts[replyingToMessage.messageId] {
                return transcript.text
            }
        }
        return nil
    }

    func onReply(_ message: AnyMessage) {
        replyingToMessage = message
    }

    func cancelReply() {
        replyingToMessage = nil
    }

    func retryTranscript(for item: VoiceMemoTranscriptListItem) {
        let service = voiceMemoTranscriptionService
        let messageId = item.parentMessageId
        let conversationId = item.conversationId
        let attachmentKey = item.attachmentKey
        let mimeType = item.mimeType ?? "audio/m4a"
        Task.detached(priority: .userInitiated) {
            await service.retry(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                mimeType: mimeType
            )
        }
    }

    func retryMessage(_ message: AnyMessage) {
        let messageWriter = cachedMessageWriter
        let messageId = message.messageId
        Task {
            do {
                try await messageWriter.retryFailedMessage(id: messageId)
            } catch {
                Log.error("Failed to retry message: \(error.localizedDescription)")
            }
        }
    }

    private func registerInlineAttachmentRecovery() {
        Task { [weak self] in
            guard let messagingService = self?.messagingService else { return }
            guard let result = try? await messagingService.sessionStateManager.waitForInboxReadyResult() else { return }
            await InlineAttachmentRecovery.shared.setProvider(result.client.conversationsProvider)
        }
    }

    func deleteMessage(_ message: AnyMessage) {
        let messageWriter = cachedMessageWriter
        let messageId = message.messageId
        Task {
            do {
                try await messageWriter.deleteFailedMessage(id: messageId)
            } catch {
                Log.error("Failed to delete message: \(error.localizedDescription)")
            }
        }
    }

    func onUseProfile(_ profile: Profile, _ profileImage: UIImage?) {
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
        if invite.isConversationExpired || invite.isInviteExpired {
            presentingExplodedInviteInfo = true
            return
        }
        presentingNewConversationForInvite = NewConversationViewModel(
            session: session,
            mode: .joinInvite(code: invite.inviteSlug)
        )
    }

    func onDisplayNameEndedEditing(focusCoordinator: FocusCoordinator, context: FocusTransitionContext) {
        isEditingDisplayName = false

        let pickedImage = myProfileViewModel.profileImage
        _ = myProfileViewModel.onEndedEditing(for: conversation.id)

        onboardingCoordinator.handleDisplayNameEndedEditing(
            displayName: myProfileViewModel.editingDisplayName,
            profileImage: pickedImage
        )

        if onboardingCoordinator.isSettingUpProfile {
            focusCoordinator.endEditing(for: .displayName, context: .onboardingProfile)
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

    func copyInviteLink() {
        let urlString = invite.inviteURLString
        guard !urlString.isEmpty else { return }
        UIPasteboard.general.string = urlString
    }

    func requestAssistantJoin() {
        let slug = invite.urlSlug
        guard !slug.isEmpty else { return }

        assistantJoinTask?.cancel()

        let forceErrorCode = assistantJoinForceErrorCode
        let conversationId = conversation.id
        let requestId = UUID().uuidString
        let taskId = requestId
        assistantJoinTask = Task { [weak self, session] in
            await Self.broadcastAssistantJoinRequest(
                status: .pending, requestId: requestId,
                conversationId: conversationId, session: session
            )

            do {
                _ = try await session.requestAgentJoin(
                    slug: slug,
                    instructions: "You're a Convos Assistant",
                    forceErrorCode: forceErrorCode
                )
            } catch is CancellationError {
                await MainActor.run { self?.clearAssistantJoinTask(id: taskId) }
                return
            } catch let error as APIError {
                let status: AssistantJoinStatus
                if case .noAgentsAvailable = error { status = .noAgentsAvailable } else { status = .failed }
                await Self.broadcastAssistantJoinRequest(
                    status: status, requestId: requestId,
                    conversationId: conversationId, session: session
                )
                await MainActor.run {
                    self?.clearAssistantJoinTask(id: taskId)
                    self?.onAssistantJoinError()
                }
                return
            } catch {
                await Self.broadcastAssistantJoinRequest(
                    status: .failed, requestId: requestId,
                    conversationId: conversationId, session: session
                )
                await MainActor.run {
                    self?.clearAssistantJoinTask(id: taskId)
                    self?.onAssistantJoinError()
                }
                return
            }
            await MainActor.run { self?.clearAssistantJoinTask(id: taskId) }
        }
        assistantJoinTaskId = taskId
    }

    private static func broadcastAssistantJoinRequest(
        status: AssistantJoinStatus,
        requestId: String,
        conversationId: String,
        session: any SessionManagerProtocol
    ) async {
        do {
            let messagingService = session.messagingService()
            let inboxResult = try await messagingService.sessionStateManager.waitForInboxReadyResult()
            guard let xmtpConversation = try await inboxResult.client.conversation(with: conversationId) else {
                Log.warning("Could not find XMTP conversation to broadcast assistant join request")
                return
            }
            // Derive requestedBy from the ready inbox rather than accepting it
            // as a parameter. An earlier draft fell back to "" when the session
            // wasn't ready yet; that empty string would land in the XMTP
            // message payload as `requestedByInboxId`.
            let request = AssistantJoinRequest(
                status: status,
                requestedByInboxId: inboxResult.client.inboxId,
                requestId: requestId
            )
            try await xmtpConversation.sendAssistantJoinRequest(request)
        } catch {
            Log.warning("Failed to broadcast assistant join request: \(error.localizedDescription)")
        }
    }

    private func clearAssistantJoinTask(id: String) {
        guard assistantJoinTaskId == id else { return }
        assistantJoinTask = nil
        assistantJoinTaskId = nil
    }

    private func onAssistantJoinError() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func leaveConvo() {
        // Note: the old per-conversation `session.deleteInbox` call is a no-op
        // post-hotfix. A proper group-leave path (group.leaveGroup() + local
        // row delete) is tracked as a follow-up to C11. Notification post
        // keeps the list UI in sync for now.
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.presentingConversationSettings = false
                self.conversation.postLeftConversationNotification()
            }
        }
    }

    func blockAndLeaveConvo() {
        let consentWriter = consentWriter
        let conversation = conversation
        Task { [weak self] in
            guard let self else { return }
            do {
                try await consentWriter.delete(conversation: conversation)
                await MainActor.run {
                    self.presentingConversationSettings = false
                    self.conversation.postLeftConversationNotification()
                }
            } catch {
                Log.error("Error blocking and leaving convo: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func conversationMetadataDebugText() async -> String {
        do {
            let messagingService = session.messagingService()
            let inboxResult = try await messagingService.sessionStateManager.waitForInboxReadyResult()
            let client = inboxResult.client
            return try await client.conversationMetadataDebugInfo(
                conversationId: conversation.id,
                clientConversationId: conversation.clientConversationId
            ).debugText
        } catch {
            return metadataDebugFallbackText(reason: error.localizedDescription)
        }
    }

    @MainActor
    func hiddenMessagesDebugInfo() async throws -> [HiddenMessageDebugEntry] {
        let messagingService = session.messagingService()
        let inboxResult = try await messagingService.sessionStateManager.waitForInboxReadyResult()
        return try await inboxResult.client.hiddenMessagesDebugInfo(conversationId: conversation.id)
    }

    var assistantInstanceId: String? {
        guard let agent = conversation.members.first(where: \.isAgent),
              case .string(let value) = agent.profile.metadata?["instanceId"],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// Live map of agent inbox id → display name, sourced from the conversation's
    /// current members. Consumed by the messages list to render
    /// `.grantedAgent`-actor connection_event summaries with the granted agent's
    /// name, and by the capability picker card to label the asker. Inbox-id keying
    /// keeps the rendered text in sync with ProfileUpdate-driven renames without
    /// re-running the messages-list processor.
    var agentNamesByInboxId: [String: String] {
        Dictionary(
            uniqueKeysWithValues: conversation.members
                .filter { $0.isAgent }
                .map { ($0.profile.inboxId, $0.displayName) }
        )
    }

    func makeAssistantFilesLinksRepository() -> AssistantFilesLinksRepository {
        session.assistantFilesLinksRepository(for: conversation.id)
    }

    func makeConversationConnectionsViewModel() -> ConversationConnectionsViewModel {
        // Snapshot of agent inbox ids at view-model creation. Per-conversation toggles
        // fan out one grant row per agent currently in the conversation; if membership
        // changes mid-life of the view model, callers can recreate it (the view model is
        // shaped per ConversationInfo presentation, so that already happens naturally).
        let agentInboxIds = conversation.members
            .filter { $0.isAgent }
            .map { $0.profile.inboxId }
        return ConversationConnectionsViewModel(
            conversationId: conversation.id,
            agentInboxIds: agentInboxIds,
            cloudConnectionManager: session.cloudConnectionManager(callbackURLScheme: ConfigManager.shared.appUrlScheme),
            cloudConnectionRepository: session.cloudConnectionRepository(),
            grantWriter: messagingService.connectionGrantWriter(),
            connectionEventWriter: messagingService.connectionEventWriter(),
            enablementStore: session.connectionEnablementStore(),
            capabilityResolver: session.capabilityResolver()
        )
    }

    @MainActor
    func restoreInviteTagIfMissing(_ expectedTag: String) async throws {
        let trimmedTag = expectedTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else { return }

        let messagingService = session.messagingService()
        let inboxResult = try await messagingService.sessionStateManager.waitForInboxReadyResult()
        let client = inboxResult.client
        guard let xmtpConversation = try await client.conversation(with: conversation.id),
              case .group(let group) = xmtpConversation else {
            throw NSError(domain: "ConversationViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "XMTP group not found"])
        }

        try await group.restoreInviteTagIfMissing(trimmedTag)
    }

    @MainActor
    func exportDebugLogs() async throws -> URL {
        let environment = ConfigManager.shared.currentEnvironment

        var conversationDebugURL: URL?
        do {
            conversationDebugURL = try await withThrowingTimeout(seconds: 10) { [self] in
                let messagingService = session.messagingService()
                let inboxResult = try await messagingService.sessionStateManager.waitForInboxReadyResult()
                let client = inboxResult.client
                guard let xmtpConversation = try await client.conversation(with: conversation.id) else {
                    return nil
                }
                return try await xmtpConversation.exportDebugLogs()
            }
        } catch {
            Log.warning("Could not get XMTP debug info (will still export app + XMTP logs): \(error.localizedDescription)")
        }

        let debugInfoURL = conversationDebugURL
        return try await Task.detached {
            try DebugLogExporter.exportAllLogs(
                environment: environment,
                conversationDebugInfo: debugInfoURL
            )
        }.value
    }

    private func metadataDebugFallbackText(reason: String) -> String {
        [
            "conversationId: \(conversation.id)",
            "clientConversationId: \(conversation.clientConversationId)",
            "error: \(reason)"
        ].joined(separator: "\n")
    }

    private func withThrowingTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
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
        let conversationId = conversationStateManager.conversationId
        Task { [weak self] in
            guard let self else { return }
            do {
                try await reactionWriter.toggleReaction(
                    emoji: emoji,
                    to: messageId,
                    in: conversationId
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
        let conversationId = conversationStateManager.conversationId
        Task { [weak self] in
            guard let self else { return }
            do {
                try await reactionWriter.toggleReaction(
                    emoji: emoji,
                    to: messageId,
                    in: conversationId
                )
            } catch {
                Log.error("Error toggling reaction: \(error)")
            }
        }
    }

    func removeReaction(_ reaction: MessageReaction, from message: AnyMessage) {
        let conversationId = conversationStateManager.conversationId
        Task { [weak self] in
            guard let self else { return }
            do {
                try await reactionWriter.removeReaction(
                    emoji: reaction.emoji,
                    from: message.messageId,
                    in: conversationId
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

        guard !autoRevealPhotos else { return }

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
        setAutoRevealPhotosPersisted(autoReveal)
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
                Log.info("Explode complete: conversation removed locally, other members removed and creator left the MLS group")
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

// MARK: - Linked Conversation Explosion

extension ConversationViewModel {
    func setInviteExplodeDuration(_ duration: ExplodeDuration?) {
        pendingInvite?.explodeDuration = duration
    }

    func updateLinkedConversationName(_ name: String) {
        guard let conversationId = pendingInvite?.linkedConversationId else { return }
        Task { [weak self, session] in
            guard let self else { return }
            do {
                let messagingService = session.messagingService()
                let metadataWriter = messagingService.conversationMetadataWriter()
                try await metadataWriter.updateName(name, for: conversationId)
                let updatedInvite = try await metadataWriter.refreshInvite(for: conversationId)
                guard let updatedInvite else { return }
                await MainActor.run {
                    self.pendingInvite?.fullURL = updatedInvite.inviteURLString
                }
            } catch {
                Log.error("Failed to update linked conversation name: \(error)")
            }
        }
    }
}

// MARK: - Invite URL Detection

extension ConversationViewModel {
    func checkForInviteURL() {
        guard pendingInvite == nil else { return }

        if let result = InviteURLDetector.detectInviteURL(in: messageText) {
            convosButtonTask?.cancel()
            convosButtonCancellable?.cancel()
            pendingInvite = PendingInvite(code: result.code, fullURL: result.fullURL, range: result.range)
            messageText = InviteURLDetector.removeInviteURL(from: messageText, range: result.range)
        }
    }

    func clearPendingInvite() {
        // Old code would destroy the linked conversation's per-conversation
        // inbox via session.deleteInbox — that's a no-op in single-inbox and
        // would wipe the whole account if it weren't. Simply dropping the
        // pendingInvite state is the correct single-inbox behavior; the
        // linked draft conversation remains locally until the user explicitly
        // discards it.
        pendingInvite = nil
        pendingInviteConvoName = ""
        pendingInviteImage = nil
    }

    func onConvosButtonTapped() {
        guard pendingInvite == nil, convosButtonTask == nil else { return }
        convosButtonTask = Task { [session] in
            defer { convosButtonTask = nil }
            let (messagingService, existingConversationId) = await session.prepareNewConversation()

            guard !Task.isCancelled else { return }

            let stateManager: any ConversationStateManagerProtocol
            if let existingConversationId {
                stateManager = messagingService.conversationStateManager(for: existingConversationId)
            } else {
                stateManager = messagingService.conversationStateManager()
                do {
                    try await stateManager.createConversation()
                } catch {
                    Log.error("Failed to create conversation for Convos button: \(error)")
                    return
                }
            }

            guard !Task.isCancelled else { return }

            convosButtonCancellable = stateManager.draftConversationRepository.conversationPublisher
                .compactMap { $0 }
                .first { $0.invite?.urlSlug.isEmpty == false }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] convo in
                    guard let self, self.pendingInvite == nil, let convoInvite = convo.invite else { return }
                    let urlString = convoInvite.inviteURLString
                    let emptyRange = urlString.startIndex ..< urlString.startIndex
                    self.pendingInvite = PendingInvite(
                        code: convoInvite.urlSlug,
                        fullURL: urlString,
                        range: emptyRange,
                        linkedConversationId: convo.id
                    )
                    self.convosButtonCancellable = nil
                    self.setInviteExplodeDuration(.twentyFourHours)
                }
        }
    }
}
