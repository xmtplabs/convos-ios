import AVFoundation
import Combine
import ConvosConnections
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
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

/// A pasted agent-share link staged as a composer chip. `share` is the parsed
/// link (sent verbatim on send); `resolved` is the agent's public profile once
/// the resolver returns (nil while resolving -> chip shows its placeholder).
struct PendingAgentShare {
    let share: MessageAgentShare
    var resolved: AgentShareInfo?
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

    /// Mirrors `HydratedAttachment.isHTMLFile` so the composer's staged-file
    /// preview can match the in-chat HTML tile (square thumbnail) instead of
    /// the generic filename + type chip.
    var isHTMLFile: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            return true
        }
        return mimeType.lowercased() == "text/html"
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

/// Snapshot of a recorded voice memo handed from the agent builder to
/// `sendBuilderBundle`. Carries the source URL, duration, and waveform
/// levels so the builder can release its recorder state before the bundle
/// finishes uploading.
struct BuilderVoiceMemoSnapshot: Sendable {
    let url: URL
    let duration: TimeInterval
    let levels: [Float]
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
class ConversationViewModel: Identifiable, Hashable { // swiftlint:disable:this type_body_length
    nonisolated var id: String { _identifiableId }
    private let _identifiableId: String = UUID().uuidString

    nonisolated static func == (lhs: ConversationViewModel, rhs: ConversationViewModel) -> Bool {
        lhs._identifiableId == rhs._identifiableId
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(_identifiableId)
    }

    /// Set by `AgentBuilderViewModel.commit` at the moment of Make. Drives
    /// the in-stream summary cell at the top of the messages list and filters
    /// out any messages with `sentAt < summary.cutoffDate` (so the user's
    /// prompt messages and any pre-Make agent chatter don't double-up
    /// alongside the card). Persisted via `AgentBuilderSummaryWriter`
    /// and rehydrated on init via `AgentBuilderSummaryRepository` so the
    /// card survives quitting the app or navigating away and back.
    var agentBuilderSummary: AgentBuilderSummary? {
        didSet {
            messagesListRepository.agentBuilderSummary = agentBuilderSummary
            scheduleAgentBuilderPlaceholderExpiry()
        }
    }

    /// Flips true once the post-commit agent-builder placeholder window
    /// (`AgentBuilderPlaceholder.displayDuration` past the summary's
    /// `cutoffDate`) elapses without a verified agent joining. Stops the
    /// optimistic Convos-verified placeholder from lingering forever on an
    /// agent that joined but never published attestation -- see
    /// `shouldRenderAsPendingAgentBuilder`.
    private var agentBuilderPlaceholderExpired: Bool = false

    /// The agent identity an agent-template flow asked us to paint
    /// optimistically before the real verified agent joins -- the template
    /// name + emoji/photo for the "Chat on a contact" path, or a neutral
    /// placeholder (upgraded in place once the resolve returns) for the
    /// `convos://template/<id>` deep link. Lives on the view model (not the
    /// `Conversation` value) so it survives the draft -> real conversation
    /// swap. Drives the "with identity" case of `pendingAgentPresentation`.
    private(set) var optimisticAgentIdentity: AgentShareInfo?

    /// `true` once an agent-template flow activates the optimistic overlay.
    /// Mirrors the agent-builder placeholder machinery: time-boxed via
    /// `optimisticAgentExpired` so a join that never lands doesn't leave a
    /// permanent fake-verified agent.
    private var optimisticAgentActive: Bool = false

    /// Flips `true` when the optimistic-agent window
    /// (`AgentBuilderPlaceholder.displayDuration` after activation) elapses
    /// without a real verified agent joining, dropping the optimistic
    /// presentation so the conversation falls back to its real identity.
    private var optimisticAgentExpired: Bool = false

    @ObservationIgnored
    private var optimisticAgentExpiryTask: Task<Void, Never>?

    // MARK: - Private

    let session: any SessionManagerProtocol
    let messagingService: any MessagingServiceProtocol
    let coreActions: any CoreActions
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
    /// Armed by `NewConversationViewModel.markSeeded(expectingMemberCount:)`
    /// for VMs whose initial `conversation` was synthesized from picker
    /// contacts. The publisher subscription uses these to ignore early
    /// DB emissions whose member count has not yet caught up to the
    /// synthetic - otherwise the chat indicator briefly flips back to
    /// the empty-conversation placeholder while the state machine's
    /// addMembers hook is still in flight. Default state is "gate
    /// open", so VMs constructed via any other path (DB hydration,
    /// regular conversation open, etc.) are unaffected.
    private var expectedSeededMemberCount: Int = 0
    private var hasMetSeededExpectation: Bool = true
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
    private var thinkingSessionsCancellable: AnyCancellable?
    @ObservationIgnored
    private var observedThinkingSessionsConversationId: String?
    @ObservationIgnored
    private var agentBuilderSummaryCancellable: AnyCancellable?
    @ObservationIgnored
    private var observedAgentBuilderSummaryConversationId: String?
    @ObservationIgnored
    private var agentBuilderPlaceholderExpiryTask: Task<Void, Never>?
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
            syncVerifiedAgentToRepo()
            presentingConversationForked = shouldPresentConversationForked
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

    /// Set to `false` by the Agent Builder right before `Make` is tapped
    /// so the contact card stays hidden while the chat settles in, then
    /// flipped back to `true` after a short delay so the card slides in with
    /// presence. Defaults to `true` — existing conversations opened from the
    /// list show the card on first render with no deferral.
    var allowsContactCard: Bool = true {
        didSet {
            guard oldValue != allowsContactCard else { return }
            syncVerifiedAgentToRepo()
        }
    }

    /// Forwards the verified Convos agent from the conversation members
    /// to the messages-list repository — gated by `allowsContactCard` so the
    /// caller can defer the card without changing the underlying conversation.
    ///
    /// When no real verified agent has joined yet but an agent-template flow
    /// is painting an optimistic identity (and that identity has enough to
    /// render a card), feed a presentation-only synthetic agent member so the
    /// processor synthesizes the contact card immediately. The synthetic
    /// member is only ever handed to the repository here -- it is never
    /// inserted into `conversation.members`.
    ///
    /// Once the real agent joins, its profile can briefly lack the
    /// `description` metadata (the agent writes it after joining), so the
    /// template description from the optimistic identity is kept as a
    /// fallback -- otherwise the card would regress from the template
    /// description back to the pulsing placeholder until the agent's own
    /// description arrives.
    private func syncVerifiedAgentToRepo() {
        let realAgent: ConversationMember? = conversation.members.first(where: \.isVerifiedConvosAgent)
        let agent: ConversationMember?
        if let realAgent {
            agent = realAgent.withFallbackAgentDescription(optimisticAgentIdentity?.descriptionText)
        } else if let presentation = pendingAgentPresentation,
                  presentation.showsContactCard,
                  let identity = optimisticAgentIdentity {
            agent = identity.optimisticCardMember(conversationId: conversation.id)
        } else {
            agent = nil
        }
        messagesListRepository.verifiedAgent = allowsContactCard ? agent : nil
    }

    /// Activate the optimistic agent overlay for an agent-template flow.
    /// Idempotent: calling again only refreshes the identity (so a deep-link
    /// resolve can upgrade the placeholder in place) without restarting the
    /// time-box. The window mirrors the agent-builder placeholder so a join
    /// that never lands eventually drops the optimistic styling rather than
    /// reading an unverified (or absent) agent as a verified Convos one.
    func activateOptimisticAgent(identity: AgentShareInfo?) {
        optimisticAgentIdentity = identity
        guard !optimisticAgentActive else {
            syncVerifiedAgentToRepo()
            return
        }
        optimisticAgentActive = true
        optimisticAgentExpired = false
        syncVerifiedAgentToRepo()
        optimisticAgentExpiryTask?.cancel()
        optimisticAgentExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AgentBuilderPlaceholder.displayDuration))
            guard !Task.isCancelled else { return }
            self?.optimisticAgentExpired = true
            self?.syncVerifiedAgentToRepo()
        }
    }

    /// Upgrade the optimistic identity in place once the agent-template deep
    /// link's async resolve returns the real profile. Keeps the running
    /// time-box; the computed `pendingAgentPresentation` and the repo card
    /// refresh from the new identity.
    func applyOptimisticAgentIdentity(_ info: AgentShareInfo) {
        guard optimisticAgentActive else {
            activateOptimisticAgent(identity: info)
            return
        }
        optimisticAgentIdentity = info
        syncVerifiedAgentToRepo()
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
        if let presentation = pendingAgentPresentation {
            return presentation.name ?? "Agent"
        }
        return conversation.computedDisplayName(memberNameOverride: contactNameLookup)
    }

    /// Unified optimistic pending-agent rendering for the indicator and the
    /// contact card. `nil` when the conversation should render normally.
    ///
    /// The agent-template flows ("Chat on a contact" + the
    /// `convos://template/<id>` deep link) take priority and supply the real
    /// identity (`showsContactCard == true`). The Agent Builder is the
    /// generic "no identity" case (`name`/`emoji` nil, `showsContactCard
    /// == false`) -- it keeps its own gating in
    /// `shouldRenderAsPendingAgentBuilder` and its own summary card. Both
    /// drop the moment a real verified Convos agent joins
    /// `conversation.members`, and both are time-boxed as a backstop.
    var pendingAgentPresentation: PendingAgentPresentation? {
        let hasRealVerifiedAgent: Bool = conversation.members.contains(where: \.isVerifiedConvosAgent)
        if optimisticAgentActive, !optimisticAgentExpired, !hasRealVerifiedAgent {
            let identity = optimisticAgentIdentity
            let hasIdentity: Bool = (identity?.displayName?.isEmpty == false) || (identity?.emoji?.isEmpty == false)
            return PendingAgentPresentation(
                name: identity?.displayName,
                emoji: identity?.emoji,
                avatarURL: identity?.avatarURL,
                agentDescription: identity?.descriptionText,
                showsContactCard: hasIdentity
            )
        }
        if shouldRenderAsPendingAgentBuilder {
            return PendingAgentPresentation(
                name: nil,
                emoji: nil,
                avatarURL: nil,
                agentDescription: nil,
                showsContactCard: false
            )
        }
        return nil
    }

    /// `true` while the conversation should show any optimistic pending-agent
    /// rendering (builder or template). Kept as the indicator's
    /// `forcedAgentVerification` gate (see `MainTabView` /
    /// `ConversationPresenter`).
    var shouldRenderAsPendingAgent: Bool {
        pendingAgentPresentation != nil
    }

    /// `true` while the conversation is in (or was created via) the agent
    /// builder UX and no verified agent has joined yet. The generic "no
    /// identity" input to `pendingAgentPresentation` — surfaces the "New
    /// Agent" / "Agent" placeholder name and the add-agent glyph via
    /// `forcedAgentVerification` so the chat header doesn't fall back to the
    /// generic "New Convo" label + emoji circle while the agent is still
    /// provisioning. Flips false the moment the verified agent actually
    /// appears in `conversation.members`, at which point the regular
    /// member-driven avatar / display name path takes over naturally.
    var shouldRenderAsPendingAgentBuilder: Bool {
        guard isInAgentBuilderFlow || agentBuilderSummary != nil else { return false }
        // Pre-commit: while drafting in the builder (no summary yet), always
        // show the generic agent placeholder -- even if a verified agent has
        // silently joined the draft in the background. The user hasn't tapped
        // Make, so the indicator stays generic ("New Agent" / "Draft").
        if isInAgentBuilderFlow, agentBuilderSummary == nil {
            return true
        }
        // A real verified Convos agent joined -> drop the placeholder
        // immediately, even while the builder view is still mounted. The
        // builder view stays on screen through the post-Make morph, so gating
        // on `isInAgentBuilderFlow` alone pinned "Joining..." on forever even
        // after the agent verified.
        guard !conversation.members.contains(where: \.isVerifiedConvosAgent) else { return false }
        // No verified agent yet -> keep the optimistic verified placeholder
        // only within the time-box past the commit. If the agent never
        // verifies (e.g. it joins without publishing attestation), this stops
        // the placeholder lingering forever and reading an unverified agent as
        // a verified Convos one.
        return !agentBuilderPlaceholderExpired
    }

    /// (Re)arm the post-commit placeholder time-box whenever the summary
    /// changes. Anchored on the summary's `cutoffDate` so the window is correct
    /// across relaunches: a summary rehydrated after its window has already
    /// elapsed expires immediately rather than restarting the clock. Cleared
    /// (no summary) resets to not-expired so a fresh draft starts clean.
    private func scheduleAgentBuilderPlaceholderExpiry() {
        agentBuilderPlaceholderExpiryTask?.cancel()
        guard let summary = agentBuilderSummary else {
            agentBuilderPlaceholderExpired = false
            return
        }
        let remaining: TimeInterval = AgentBuilderPlaceholder.remainingDisplayTime(since: summary.cutoffDate)
        guard remaining > 0 else {
            agentBuilderPlaceholderExpired = true
            return
        }
        agentBuilderPlaceholderExpired = false
        agentBuilderPlaceholderExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.agentBuilderPlaceholderExpired = true
        }
    }

    /// Inbox-to-contact-name lookup used for auto-generated unnamed-group
    /// titles in the chat header. Adapted from the unified
    /// `ContactsRepository.contact(for:)` resolver to the name-only
    /// shape ConvosCore expects; returns nil when the inbox is not a
    /// contact (or the contact has no display name) so the legacy
    /// precedence applies.
    private func contactNameLookup(_ inboxId: String) -> String? {
        messagingService.contactsRepository().contactName(for: inboxId)
    }
    var conversationInfoSubtitle: String {
        if let expiresAt = scheduledExplosionDate {
            return ExplosionDurationFormatter.countdown(until: expiresAt)
        }
        if shouldRenderAsPendingAgent {
            return "Joining..."
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
        if isEditingConversationName {
            return editingConversationName
        }
        if let presentation = pendingAgentPresentation {
            return presentation.name ?? "New Agent"
        }
        return conversation.computedDisplayName(memberNameOverride: contactNameLookup)
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

    /// Active thinking sessions for this conversation, sourced from
    /// `ThinkingSessionRepository`. Drives the in-list thinking bubble in
    /// `messagesWithIndicators`. Mirror of how `typingMembers` drives the
    /// typing bubble, but persisted in GRDB rather than in-memory.
    var thinkingSessions: [ThinkingSessionRecord] = []

    @ObservationIgnored
    var isTypingSent: Bool = false
    @ObservationIgnored
    var typingResetTask: Task<Void, Never>?
    @ObservationIgnored
    var pendingTypingIndicatorTask: Task<Void, Never>?
    @ObservationIgnored
    var typingThrottleDate: Date?

    var pendingMediaAttachments: [PendingMediaAttachment] = []
    /// True while the Agent Builder commit is mid-flight — i.e. between
    /// `Make` being tapped and `sendBuilderBundle` finishing. The composer
    /// hides staged chips while this is set so the user doesn't see the
    /// pre-Make staging state lingering during the upload/publish window.
    /// `pendingMediaAttachments` is intentionally left alive across this
    /// window so the per-attachment eager-upload start tasks can still
    /// write back their `eagerUploadKey` instead of cancelling.
    var isAwaitingBuilderBundleSend: Bool = false
    /// True while the user is interacting with the Agent Builder for
    /// this conversation — set on builder appear, cleared on disappear (or
    /// when the agent actually joins). Used by
    /// `ConversationViewModel+ThinkingIndicators` to route agent
    /// thinking sessions under the contact card instead of the inline
    /// footer, and read by the messages-list processor so it can suppress
    /// the legacy "Agent joined" update row for the duration of the builder
    /// UX. Independent of whether the conversation was created via the
    /// builder — the same flow will run when adding an agent to an existing
    /// conversation.
    ///
    /// Backed by `messagesListRepository` (its single owner, which feeds the
    /// processor) rather than a mirrored stored copy, so there's one value to
    /// keep in sync across the placeholder-to-real VM swap instead of two.
    var isInAgentBuilderFlow: Bool {
        get { messagesListRepository.isInAgentBuilderFlow }
        set { messagesListRepository.isInAgentBuilderFlow = newValue }
    }
    @ObservationIgnored
    private var videoThumbnailTasks: [UUID: Task<Void, Never>] = [:]
    /// Background tasks that assign `eagerUploadKey` to a freshly-added
    /// photo / video attachment. The assignment runs asynchronously after
    /// `startEagerUpload` returns, so `awaitPendingMediaUploads` must wait
    /// for these tasks first — otherwise a caller can race ahead and find
    /// `eagerUploadKey == nil`, silently dropping the attachment from a
    /// `MultiRemoteAttachment` bundle.
    @ObservationIgnored
    private var eagerUploadStartTasks: [UUID: Task<Void, Never>] = [:]
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

    /// A pasted agent-share link staged as a composer chip. Display-only: the
    /// agent's name / emoji come from the resolver, not the sender, so unlike
    /// `pendingInvite` there are no editable fields. The URL is sent verbatim
    /// on send (and auto-classifies as an agent-share message).
    var pendingAgentShare: PendingAgentShare?

    var sendButtonEnabled: Bool {
        !messageText.isEmpty
            || !pendingMediaAttachments.isEmpty
            || pendingInvite != nil
            || pendingAgentShare != nil
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
    /// Drives the contact detail sheet opened by tapping a shared agent's
    /// message card when no agent running that template is a member of this
    /// conversation. Carries a placeholder `Contact` built from the share
    /// link's resolved profile; the card's "New chat" action spawns a fresh
    /// instance of the template. Mirrors `presentingProfileForMember`.
    var presentingContactForAgentShare: Contact?
    /// Conversation IDs whose forked info sheet was dismissed this app session.
    /// The conversation row updates on every observed change (new message, read
    /// receipt, metadata), so without this the sheet would re-present after
    /// every dismissal. Cleared on app relaunch.
    private static var forkedSheetDismissedConversationIds: Set<String> = []
    var presentingConversationForked: Bool = false {
        didSet {
            guard oldValue, !presentingConversationForked, conversation.isForked else { return }
            Self.forkedSheetDismissedConversationIds.insert(conversation.id)
        }
    }
    private var shouldPresentConversationForked: Bool {
        conversation.isForked && !Self.forkedSheetDismissedConversationIds.contains(conversation.id)
    }
    var presentingReactionsForMessage: AnyMessage?
    var presentingReadByForGroup: MessagesGroup?
    var presentingThinkingDetail: ThinkingSessionDescriptor?
    var replyingToMessage: AnyMessage?
    var presentingShareView: Bool = false
    var presentingRevealMediaInfoSheet: Bool = false
    var presentingPhotosInfoSheet: Bool = false
    /// Drives the "New Agent" context-menu builder sheet, scoped to this
    /// existing conversation. The builder defers the agent join until the
    /// user taps Make (see `AgentBuilderViewModel.existingConversationId`),
    /// so we only add the agent once they confirm.
    var presentingAgentBuilder: AgentBuilderViewModel?
    /// Drives the first-run agents explainer shown before the builder. Its
    /// "Make an agent" button sets `pendingAgentBuilderAfterIntro` and dismisses;
    /// the sheet's onDismiss then opens the builder. Dismissing without the
    /// button leaves the builder unopened.
    var presentingAgentsIntro: Bool = false
    var pendingAgentBuilderAfterIntro: Bool = false
    var presentingExplodedInviteInfo: Bool = false
    /// Drives the upsell sheet shown when the user taps the
    /// "<agent> is out of processing power" cell. Surfaces `PaywallView`
    /// against `SubscriptionServices.shared`.
    var presentingPaywall: Bool = false
    /// Mirrors `CreditsServices.shared.currentBalance?.isDepleted`, refreshed
    /// via the balance publisher. Drives the in-stream out-of-credits cell
    /// insertion in `MessagesViewController` and the inline status surfaces.
    var creditsDepleted: Bool = CreditsServices.shared.currentBalance?.isDepleted ?? false
    var activeToast: IndicatorToastStyle?

    var agentJoinForceErrorCode: Int?

    var isAgentJoinPending: Bool {
        agentJoinTask != nil || conversation.agentJoinStatus == .pending
    }

    @ObservationIgnored
    private var agentJoinTask: Task<Void, Never>?
    @ObservationIgnored
    private var agentJoinTaskId: String?

    var autoRevealPhotos: Bool = GlobalConvoDefaults.shared.autoRevealPhotos
    var sendReadReceipts: Bool = true
    var isViewingConversation: Bool = false

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
        defaults.removeObject(forKey: hasShownAgentsIntroKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(revealToastKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func onPhotoAttached() {
        // The "Pics are personal" first-attachment info sheet is disabled
        // for now — neither the agent-builder flow nor the regular
        // composer should interrupt the user with it on attach.
    }

    /// A fresh agent builder scoped to this conversation. The "New Agent"
    /// entries take the user through the same builder flow as the home screen
    /// but defer the agent join until they tap Make, so the brief they compose
    /// is what the agent receives. Surfaces nested inside another sheet (the
    /// Info sheet, Members list) present this from their own `.sheet` so it
    /// stacks on top; the top-level chat menu uses `presentAgentBuilder()`.
    func makeAgentBuilderViewModel() -> AgentBuilderViewModel {
        AgentBuilderViewModel(session: session, existingConversationId: conversation.id, coreActions: coreActions)
    }

    private static let hasShownAgentsIntroKey: String = "hasShownAgentsIntro"

    /// First-run gate for the "New Agent" agents explainer: returns `true`
    /// exactly once (the first "New Agent" tap, from any in-chat surface) and
    /// marks it shown. Callers present `AgentsInfoView` when this is true and
    /// open the builder only if the user taps its "Make an agent" button.
    func consumeAgentsIntroGate() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.hasShownAgentsIntroKey) else { return false }
        defaults.set(true, forKey: Self.hasShownAgentsIntroKey)
        return true
    }

    /// Present the agent builder from the top-level `ConversationView` (the
    /// in-chat "+"/context menu and the new-convo "Invite members" capsule,
    /// neither of which has another sheet up). On the first-ever tap, show the
    /// agents explainer first; the builder opens only if the user taps
    /// "Make an agent" (handled by `presentAgentBuilderAfterIntroIfNeeded()`
    /// from the intro sheet's onDismiss).
    func presentAgentBuilder() {
        guard presentingAgentBuilder == nil, !presentingAgentsIntro else { return }
        if consumeAgentsIntroGate() {
            presentingAgentsIntro = true
        } else {
            presentingAgentBuilder = makeAgentBuilderViewModel()
        }
    }

    /// Called from the intro sheet's onDismiss: opens the builder only if the
    /// user opted in via "Make an agent" (which sets the pending flag).
    func presentAgentBuilderAfterIntroIfNeeded() {
        guard pendingAgentBuilderAfterIntro else { return }
        pendingAgentBuilderAfterIntro = false
        presentingAgentBuilder = makeAgentBuilderViewModel()
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
        // Intentionally not cancelled here. A requested agent join is a
        // durable backend trigger that should complete even after the user
        // closes the conversation view (which deallocates this VM). The
        // in-flight request holds `session` strongly and finishes on its own;
        // tying it to the view lifecycle was cancelling joins mid-request, so
        // the backend never provisioned the agent.
        convosButtonTask?.cancel()
        explodeDurationTask?.cancel()
        agentBuilderPlaceholderExpiryTask?.cancel()
    }

    // MARK: - Init

    static func create(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared,
        coreActions: any CoreActions = NoOpCoreActions()
    ) async throws -> ConversationViewModel {
        let messagingService = session.messagingService()
        return ConversationViewModel(
            conversation: conversation,
            session: session,
            messagingService: messagingService,
            backgroundUploadManager: backgroundUploadManager,
            coreActions: coreActions
        )
    }

    static func createSync(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        coreActions: any CoreActions = NoOpCoreActions()
    ) -> ConversationViewModel {
        let messagingService = session.messagingServiceSync()
        return ConversationViewModel(
            conversation: conversation,
            session: session,
            messagingService: messagingService,
            coreActions: coreActions
        )
    }

    init(
        conversation: Conversation,
        session: any SessionManagerProtocol,
        messagingService: any MessagingServiceProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = BackgroundUploadManager.shared,
        applyGlobalDefaultsForNewConversation: Bool = false,
        coreActions: any CoreActions = NoOpCoreActions()
    ) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService
        self.coreActions = coreActions
        self.backgroundUploadManager = backgroundUploadManager
        self.applyGlobalDefaultsForNewConversation = applyGlobalDefaultsForNewConversation

        let messagesRepository = session.messagesRepository(for: conversation.id)
        self.conversationStateManager = messagingService.conversationStateManager(for: conversation.id)
        self.conversationRepository = conversationStateManager.draftConversationRepository
        let transcriptionService = session.voiceMemoTranscriptionService()
        let messagesListRepo = MessagesListRepository(
            messagesRepository: messagesRepository,
            transcriptRepository: session.voiceMemoTranscriptRepository(),
            hiddenBundleMessagesRepository: session.builderBundleHiddenMessagesRepository(),
            conversationId: conversation.id,
            speechPermissionProvider: { transcriptionService.hasSpeechPermission() }
        )
        messagesListRepo.currentOtherMemberCount = conversation.membersWithoutCurrent.count
        messagesListRepo.verifiedAgent = conversation.members.first(where: \.isVerifiedConvosAgent)
        // Hydrate the persisted summary *before* `fetchInitial()` so the first
        // emission already includes the `.agentBuilderSummary` card and the
        // cutoff-filtered messages. The publisher subscription below picks up
        // any subsequent writes.
        let initialSummary: AgentBuilderSummary? = session.agentBuilderSummaryRepository().summarySync(for: conversation.id)
        messagesListRepo.agentBuilderSummary = initialSummary
        self.messagesListRepository = messagesListRepo
        self.agentBuilderSummary = initialSummary
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

        presentingConversationForked = shouldPresentConversationForked

        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        let individualMessageCount = messages.reduce(0) { count, item in
            if case .messages(let group) = item { return count + group.messages.count }
            return count
        }
        Log.info("[PERF] ConversationViewModel.init: \(perfElapsed)ms, \(individualMessageCount) messages loaded (\(messages.count) list items)")
        Log.info("Created for conversation: \(conversation.id)")

        applyGlobalDefaultsForDraftConversationIfNeeded()
        observe()
        observeAgentBuilderSummary()
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
        applyGlobalDefaultsForNewConversation: Bool = false,
        coreActions: any CoreActions = NoOpCoreActions()
    ) {
        self.conversation = conversation
        self.session = session
        self.messagingService = messagingService
        self.coreActions = coreActions
        self.backgroundUploadManager = backgroundUploadManager
        self.applyGlobalDefaultsForNewConversation = applyGlobalDefaultsForNewConversation

        self.conversationStateManager = conversationStateManager
        self.conversationRepository = conversationStateManager.draftConversationRepository
        let messagesRepository = conversationStateManager.draftConversationRepository.messagesRepository
        let transcriptionService = session.voiceMemoTranscriptionService()
        let messagesListRepo2 = MessagesListRepository(
            messagesRepository: messagesRepository,
            transcriptRepository: session.voiceMemoTranscriptRepository(),
            hiddenBundleMessagesRepository: session.builderBundleHiddenMessagesRepository(),
            conversationId: conversation.id,
            speechPermissionProvider: { transcriptionService.hasSpeechPermission() }
        )
        messagesListRepo2.currentOtherMemberCount = conversation.membersWithoutCurrent.count
        messagesListRepo2.verifiedAgent = conversation.members.first(where: \.isVerifiedConvosAgent)
        let initialSummary2: AgentBuilderSummary? = session.agentBuilderSummaryRepository().summarySync(for: conversation.id)
        messagesListRepo2.agentBuilderSummary = initialSummary2
        self.messagesListRepository = messagesListRepo2
        self.agentBuilderSummary = initialSummary2
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
        observeAgentBuilderSummary()
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
                setAutoRevealPhotosLocally(prefs?.autoReveal ?? GlobalConvoDefaults.shared.autoRevealPhotos)
                let readReceiptsPref = prefs?.sendReadReceipts ?? GlobalConvoDefaults.shared.sendReadReceipts
                sendReadReceipts = readReceiptsPref
                messagesListRepository.sendReadReceipts = readReceiptsPref
            } catch {
                Log.error("Error loading photo preferences: \(error)")
            }
        }
    }

    /// Subscribe to the AgentBuilderSummary row for this conversation —
    /// emits the persisted summary (if any) on first delivery and any future
    /// inserts/updates from the writer. Without this, returning to the
    /// conversation later would show the raw pre-Make message history
    /// instead of the polished summary card.
    private func observeAgentBuilderSummary() {
        observeAgentBuilderSummary(for: conversation.id)
    }

    private func observeAgentBuilderSummary(for conversationId: String) {
        guard conversationId != observedAgentBuilderSummaryConversationId else { return }
        observedAgentBuilderSummaryConversationId = conversationId
        agentBuilderSummaryCancellable?.cancel()
        agentBuilderSummaryCancellable = session.agentBuilderSummaryRepository()
            .summaryPublisher(for: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                self?.agentBuilderSummary = summary
            }
        // The summary set during `init` doesn't fire `agentBuilderSummary`'s
        // `didSet`, so arm the placeholder time-box explicitly here (this runs
        // from both init paths). Without it, a cold launch of an already-expired
        // builder convo would briefly render the verified placeholder until the
        // publisher's first emission rescheduled it.
        scheduleAgentBuilderPlaceholderExpiry()
    }

    /// Subscribe to the GRDB-backed thinking session feed for this
    /// conversation. The publisher fires whenever the writer inserts or
    /// closes a row, which propagates into `messagesWithThinkingIndicators`
    /// via the `thinkingSessions` property the extension reads.
    func observeThinkingSessions() {
        observeThinkingSessions(for: conversation.id)
    }

    private func observeThinkingSessions(for conversationId: String) {
        guard conversationId != observedThinkingSessionsConversationId else { return }
        observedThinkingSessionsConversationId = conversationId
        thinkingSessions = []
        thinkingSessionsCancellable?.cancel()
        thinkingSessionsCancellable = session.thinkingSessionRepository()
            .activeSessionsPublisher(for: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.thinkingSessions = sessions
            }
    }

    private func observe() {
        messagesListRepository.startObserving()
        setupTypingIndicatorHandler()
        observeThinkingSessions()
        setupVoiceMemoPlaybackObserver()
        observeCapabilityRequests()
        CreditsServices.shared.balancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] balance in
                self?.creditsDepleted = balance?.isDepleted ?? false
            }
            .store(in: &cancellables)
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
                // During the contacts-picker create flow the VM is seeded
                // with a synthetic draft Conversation that already carries
                // the picked members (built from the contact list, so the
                // chat header renders the contact's name + avatar from the
                // moment the sheet opens). The DB-backed publisher may
                // emit an emptier draft row first - the row exists from
                // `UnusedConversationCache` but the state machine has not
                // yet folded in the picked members. Ignore those emissions
                // so we don't flicker back to "New Convo" before the real
                // members land.
                // When this VM was seeded via the contacts picker
                // (armed through `markSeeded(expectingMemberCount:)`),
                // the DB-backed publisher can emit a Conversation that
                // hasn't yet folded in the picked members - first as an
                // `isDraft = true` cache row with no members, then
                // briefly as `isDraft = false` with no members before
                // the state machine's addMembers hook lands. Either
                // case would flip the chat indicator back to the empty
                // placeholder for a frame. Skip incoming emissions with
                // fewer non-self members than the seed until we've seen
                // one that meets or exceeds it - after that, the gate
                // stays open so later member additions / removals
                // propagate normally. Non-seeded VMs default to "gate
                // open", so this is a no-op for them.
                if !hasMetSeededExpectation {
                    if conversation.membersWithoutCurrent.count < expectedSeededMemberCount {
                        return
                    }
                    hasMetSeededExpectation = true
                }
                let previousId = self.conversation.id
                let wasViewingConversation = self.isViewingConversation
                self.conversation = conversation
                self.loadConversationImage(for: conversation)
                if conversation.id != previousId {
                    self.observePhotoPreferences(for: conversation.id)
                    self.loadPhotoPreferences()
                    self.observeCapabilityRequests(for: conversation.id)
                    self.observeThinkingSessions(for: conversation.id)
                    self.observeAgentBuilderSummary(for: conversation.id)
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
                setAutoRevealPhotosLocally(prefs?.autoReveal ?? GlobalConvoDefaults.shared.autoRevealPhotos)
                let readReceiptsPref = prefs?.sendReadReceipts ?? GlobalConvoDefaults.shared.sendReadReceipts
                sendReadReceipts = readReceiptsPref
                messagesListRepository.sendReadReceipts = readReceiptsPref
            }
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

    /// Arms the publisher-emission gate so the chat indicator doesn't
    /// flip back to the empty-conversation placeholder while the DB
    /// row catches up to the synthetic seed. Called by
    /// `NewConversationViewModel` after constructing this VM with a
    /// `Conversation.draft(id:seededMembers:)` whose member list
    /// already reflects the picked contacts. Other code paths must
    /// not call this - the default state is "gate open" so DB
    /// emissions flow through normally.
    func markSeeded(expectingMemberCount count: Int) {
        guard count > 0 else { return }
        expectedSeededMemberCount = count
        hasMetSeededExpectation = false
    }

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
               let source = await deviceActionSchemas(for: kind) {
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

    private func deviceActionSchemas(for kind: ConnectionKind) async -> [ActionSchema]? {
        // Looks up the sink the host registered via `PlatformProviders.deviceConnections`.
        // Hosts that don't link a per-kind ConvosConnections product return `nil` for
        // every device kind, which matches the v1 cloud-only configuration. The
        // `supportedDeviceKinds` filter further upstream already prevents device kinds
        // from being surfaced in the picker; this code path is a defensive no-op for
        // those builds.
        guard let sink = session.deviceDataSink(for: kind) else { return nil }
        return await sink.actionSchemas()
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
                    // User backed out of the OAuth sheet — leave the picker open so they
                    // can pick a different provider.
                } else {
                    Log.error("OAuth failed for \(serviceId): \(oauthError.localizedDescription)")
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.recomputeCapabilityPickerLayout(for: request, conversationId: conversationId)
                }
            } catch {
                Log.error("Cloud connect failed for \(serviceId): \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.recomputeCapabilityPickerLayout(for: request, conversationId: conversationId)
                }
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pendingMediaAttachments.append(.file(attachment))
        }
    }

    func addVideoAttachment(url: URL) {
        guard canStageMoreMedia else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let attachment = PendingVideoAttachment(url: url)
        let attachmentId = attachment.id
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pendingMediaAttachments.append(.video(attachment))
        }

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
        eagerUploadStartTasks[attachmentId] = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.eagerUploadStartTasks.removeValue(forKey: attachmentId)
                }
            }
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pendingMediaAttachments.append(.photo(attachment))
        }

        let messageWriter = cachedMessageWriter
        eagerUploadStartTasks[attachmentId] = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.eagerUploadStartTasks.removeValue(forKey: attachmentId)
                }
            }
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

    /// Iterates every pending attachment and runs the same cleanup as the
    /// per-attachment X-button path: cancels in-flight uploads, removes temp
    /// files left in `FileManager.default.temporaryDirectory`. Used by the
    /// Agent Builder's discard flow so file picks (which copy into temp
    /// at stage-time) don't accumulate after the user cancels the draft.
    func cleanupPendingMediaAttachments() {
        let attachments: [PendingMediaAttachment] = pendingMediaAttachments
        pendingMediaAttachments.removeAll()
        for attachment in attachments {
            cleanupAttachment(attachment)
        }
    }

    private func cleanupAttachment(_ attachment: PendingMediaAttachment) {
        switch attachment {
        case .photo(let photo):
            eagerUploadStartTasks[photo.id]?.cancel()
            eagerUploadStartTasks.removeValue(forKey: photo.id)
            if let trackingKey = photo.eagerUploadKey {
                let messageWriter = cachedMessageWriter
                Task { await messageWriter.cancelEagerUpload(trackingKey: trackingKey) }
            }
        case .video(let video):
            videoThumbnailTasks[video.id]?.cancel()
            videoThumbnailTasks.removeValue(forKey: video.id)
            eagerUploadStartTasks[video.id]?.cancel()
            eagerUploadStartTasks.removeValue(forKey: video.id)
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

    /// Wait for every currently-pending eager photo / video upload on this
    /// conversation to finish before returning. Photo and video attachments
    /// start uploading the moment the user picks them in the composer, so
    /// `pendingMediaAttachments[*].eagerUploadKey` is populated long before
    /// Send is tapped. Callers that want to enqueue a batch of related sends
    /// in one tight burst — the agent builder, primarily — use this to
    /// hold off until every payload is on the wire; once `onSendMessage`
    /// runs, the state-machine FIFO queue can flush each message without
    /// stalling on per-message upload waits. Throws if any upload fails or
    /// is cancelled while waiting.
    func awaitPendingMediaUploads() async throws {
        // First, wait for every in-flight `eagerUploadStartTasks` to complete
        // so each pending photo/video has had a chance to write back its
        // `eagerUploadKey`. Skipping this lets a fast tap-to-send race past
        // key assignment, after which the bundle path silently drops the
        // affected attachments (their `eagerUploadKey` is still nil at
        // collect time).
        let startTasks = Array(eagerUploadStartTasks.values)
        for task in startTasks { _ = await task.value }

        let trackingKeys: [String] = pendingMediaAttachments.compactMap { attachment in
            switch attachment {
            case .photo(let photo): return photo.eagerUploadKey
            case .video(let video): return video.eagerUploadKey
            case .file: return nil
            }
        }
        guard !trackingKeys.isEmpty else { return }
        let writer = cachedMessageWriter
        try await withThrowingTaskGroup(of: Void.self) { group in
            for key in trackingKeys {
                group.addTask { try await writer.awaitEagerUpload(trackingKey: key) }
            }
            try await group.waitForAll()
        }
    }

    /// Send the agent builder's commit payload as a synchronized burst:
    /// the prompt text as one XMTP message, every media item — voice memo +
    /// photos + videos + files — bundled into a single `MultiRemoteAttachment`
    /// message. The state-machine FIFO queue preserves ordering, so the
    /// agent receives the text immediately followed by the bundle once
    /// the agent reaches `.ready`. Pending media attachments and the voice
    /// memo recorder are cleared after the bundle is queued. Used only by
    /// the agent builder — the normal conversation send path
    /// (`onSendMessage`) keeps its per-attachment messages so per-item
    /// reactions and replies continue to work.
    func sendBuilderBundle(
        text: String,
        voiceMemo: BuilderVoiceMemoSnapshot?,
        textMessageId: String? = nil,
        bundleMessageId: String? = nil
    ) async {
        defer { isAwaitingBuilderBundleSend = false }
        let writer = cachedMessageWriter

        var bundleItems: [MultiAttachmentBundleItem] = []
        if let voiceMemo {
            bundleItems.append(.voiceMemo(url: voiceMemo.url, duration: voiceMemo.duration, waveformLevels: voiceMemo.levels))
        }
        for attachment in pendingMediaAttachments {
            switch attachment {
            case .photo(let photo):
                if let trackingKey = photo.eagerUploadKey {
                    bundleItems.append(.eagerPhoto(trackingKey: trackingKey))
                }
            case .video(let video):
                if let trackingKey = video.eagerUploadKey {
                    bundleItems.append(.eagerVideo(trackingKey: trackingKey))
                }
            case .file(let file):
                bundleItems.append(.file(url: file.url, filename: file.filename, mimeType: file.mimeType))
            }
        }

        let attachmentsSnapshot: [PendingMediaAttachment] = pendingMediaAttachments
        pendingMediaAttachments = []
        videoThumbnailTasks.values.forEach { $0.cancel() }
        videoThumbnailTasks.removeAll()
        if voiceMemo != nil {
            voiceMemoRecorder.resetState()
        }

        // Send a `BuilderBundleManifest` first, then the media bundle, then the
        // prompt text. The manifest lists the bundle's prepared XMTP ids so
        // every recipient hides the brief before it renders; the agent still
        // sees attachments before the prompt. `sendBuilderBundle` prepares all
        // three up front so the manifest can reference real ids and publish
        // ahead of them. The optimistic ids match the summary's
        // `bundledMessageIds`, keeping the sender's own copy hidden too.
        let resolvedBundleClientMessageId: String = bundleMessageId ?? UUID().uuidString
        let resolvedTextClientMessageId: String = textMessageId ?? UUID().uuidString
        do {
            try await writer.sendBuilderBundle(
                text: text,
                bundleItems: bundleItems,
                textClientMessageId: resolvedTextClientMessageId,
                bundleClientMessageId: resolvedBundleClientMessageId
            )
        } catch {
            Log.error("AgentBuilder bundle: failed to send builder bundle: \(error.localizedDescription)")
            // Restore pending attachments and the voice memo so the user can
            // retry from the chat composer. Both were cleared optimistically
            // above; without restoring the recorder, the recording is lost
            // with no way to retry. The eager-upload state inside the writer
            // may already be partially consumed; in practice this only fires
            // on a network-level failure, and the failed-send UI surfaces
            // individual item retries.
            pendingMediaAttachments = attachmentsSnapshot
            if let voiceMemo {
                voiceMemoRecorder.restoreRecorded(
                    url: voiceMemo.url,
                    duration: voiceMemo.duration,
                    audioLevels: voiceMemo.levels
                )
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
        let hasAgentShare = pendingAgentShare != nil
        let hasLinkPreview = pastedLinkPreview != nil

        guard hasText || hasMedia || hasInvite || hasAgentShare || hasLinkPreview else { return }

        let prevMessageText = messageText
        let replyTarget = replyingToMessage
        let prevMediaAttachments = pendingMediaAttachments
        let prevInviteURL = pendingInvite?.fullURL
        let sideConvoName = pendingInviteConvoName
        let sideConvoLinkedId = pendingInvite?.linkedConversationId
        let sideConvoExplodeDuration = pendingInvite?.explodeDuration
        let sideConvoImage = pendingInviteImage
        let prevAgentShareURL = pendingAgentShare?.share.url
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
        pendingAgentShare = nil
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
                    agentShareURL: prevAgentShareURL,
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
        agentShareURL: String? = nil,
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

        if let agentShareURL {
            // The URL auto-classifies as an agent-share message on save, so
            // this is a plain send -- no dedicated writer entry point needed.
            if replyTarget != nil && !hasAttachment && text == nil && inviteURL == nil, let replyTarget {
                try await messageWriter.sendReply(text: agentShareURL, afterPhoto: photoTrackingKey, toMessageWithClientId: replyTarget.messageId)
            } else {
                try await messageWriter.send(text: agentShareURL, afterPhoto: photoTrackingKey)
            }
        }

        if let linkURL {
            if replyTarget != nil && !hasAttachment && text == nil && inviteURL == nil && agentShareURL == nil, let replyTarget {
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
        // Tapping your own avatar in the messages view routes to "My info"
        // instead of the contact card. Showing the contact card for self
        // exposes Send-a-message and Block affordances against yourself,
        // which is meaningless and would leak self into the contact list.
        if member.isCurrentUser {
            presentingProfileSettings = true
            return
        }
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
            mode: .joinInvite(code: invite.inviteSlug),
            coreActions: coreActions
        )
    }

    /// Resolves a shared agent's link to its public profile for the message
    /// card. Vended by the session so the real API-backed resolver swaps in
    /// transparently once it lands.
    var agentShareResolver: any AgentShareResolving {
        session.agentShareResolver()
    }

    /// Resolves whether the current user already joined the conversation an
    /// invite card points to, so the card shows the member count instead of
    /// "Tap to join". Vended by the session so the GRDB-backed resolver swaps in
    /// transparently.
    var inviteMembershipResolver: any InviteMembershipResolving {
        session.inviteMembershipResolver()
    }

    /// Tapping a shared agent's message card opens that agent's contact
    /// detail. When an agent running the same template is already a member of
    /// this conversation, the member's card opens directly; otherwise a
    /// placeholder card is built from the share link's resolved profile, and
    /// its "New chat" action spawns a fresh instance of the template. The
    /// custom-scheme form carries the template id directly; a web-slug share
    /// is resolved to its id via the API resolver first.
    func onTapAgentShare(_ agentShare: MessageAgentShare) {
        if isValidTemplateId(agentShare.identifier),
           presentAgentMemberIfInConversation(templateId: agentShare.identifier) {
            return
        }
        let resolver = agentShareResolver
        let identifier = agentShare.identifier
        Task { [weak self] in
            let info = await resolver.resolve(identifier: identifier)
            await MainActor.run {
                guard let self else { return }
                self.presentAgentShareContactCard(for: agentShare, resolved: info)
            }
        }
    }

    /// Opens the in-conversation member's contact detail for `templateId`,
    /// returning false when no agent running that template is a member. The
    /// post-builder contact card reaches the same member detail directly via
    /// `onTapAvatar` (it already has the member).
    private func presentAgentMemberIfInConversation(templateId: String) -> Bool {
        let member: ConversationMember? = conversation.members.first { member in
            member.isAgent && member.profile.agentTemplateId == templateId
        }
        guard let member else { return false }
        presentingProfileForMember = member
        return true
    }

    /// Presents the shared agent's contact detail from a placeholder contact
    /// built from the resolved profile. When the resolve failed but the link
    /// carried the template id itself, a neutral identity stands in so the
    /// card (and its "New chat" action) still works without the profile.
    private func presentAgentShareContactCard(for agentShare: MessageAgentShare, resolved info: AgentShareInfo?) {
        let fallbackTemplateId: String? = isValidTemplateId(agentShare.identifier) ? agentShare.identifier : nil
        guard let templateId = info?.templateId ?? fallbackTemplateId else { return }
        if presentAgentMemberIfInConversation(templateId: templateId) { return }
        presentingContactForAgentShare = .agentSharePlaceholder(
            templateId: templateId,
            shareURL: agentShare.url,
            info: info
        )
    }

    private func isValidTemplateId(_ value: String) -> Bool {
        guard let pattern = ConversationViewModel.uuidPattern else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, options: [], range: range) != nil
    }

    private static let uuidPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.caseInsensitive]
        )
    }()

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

    /// Adds the given inboxIds as members of this conversation via the
    /// existing `addMembers` flow. Used by the "Add from Contacts" entry on
    /// the chat plus-menu.
    func addMembersFromContacts(_ inboxIds: [String]) async throws {
        guard !inboxIds.isEmpty else { return }
        try await metadataWriter.addMembers(inboxIds, to: conversation.id)
    }

    /// Requests an agent join into this conversation. `templateId == nil`
    /// is a bare join (the backend provisions its default agent); a
    /// non-nil id provisions a fresh instance of that template. The
    /// caller-facing `agents/join` body no longer accepts `instructions`.
    ///
    /// Single-flight: a new call cancels any prior in-flight join request
    /// (retry-from-error semantics for the chat-header "+" menu). For
    /// multi-template fan-out (picker confirms N templates at once) use
    /// `requestAgentJoins(templateIds:)` instead -- it runs the calls
    /// sequentially without cancelling each other.
    func requestAgentJoin(templateId: String?) {
        let slug = invite.urlSlug
        guard !slug.isEmpty else { return }

        agentJoinTask?.cancel()

        let forceErrorCode = agentJoinForceErrorCode
        let conversationId = conversation.id
        let requestId = UUID().uuidString
        let taskId = requestId
        let session = self.session
        let actions: any CoreActions = coreActions
        agentJoinTask = Task { [weak self] in
            let outcome = await Self.performAgentJoinCall(
                templateId: templateId,
                slug: slug,
                conversationId: conversationId,
                requestId: requestId,
                forceErrorCode: forceErrorCode,
                session: session
            )
            let memberCount: Int = await MainActor.run { self?.conversation.members.count ?? 0 }
            await MainActor.run {
                guard let self else { return }
                if outcome == .failed { self.onAgentJoinError() }
                self.clearAgentJoinTask(id: taskId)
            }
            if outcome == .succeeded {
                await actions.addedAssistant(memberCount: memberCount)
            }
        }
        agentJoinTaskId = taskId
    }

    /// Bare-join convenience for the in-conversation "add an agent"
    /// affordances. Kept so their call sites don't change.
    func requestAgentJoin() {
        requestAgentJoin(templateId: nil)
    }

    /// Sequential batched variant of `requestAgentJoin(templateId:)`. Used
    /// when the picker confirmed multiple agent templates at once. Awaits
    /// each call to completion before firing the next, with a short
    /// inter-call delay so the previous broadcast's libxmtp activity fully
    /// settles before the next API call starts. Does not touch
    /// `agentJoinTask` / `agentJoinTaskId` (those remain dedicated to the
    /// single-flight retry path).
    ///
    /// Band-aid for an unresolved issue where parallel `agents/join`
    /// dispatch results in 2 of 3 URLSession data tasks being cancelled
    /// (`URLError.cancelled`) -- see "concurrent agents/join cancellation"
    /// investigation notes. Manual one-at-a-time clicks work fine, so
    /// serialization mirrors what the user can do by hand. Slow but
    /// reliable: ~10 seconds per agent. Remove and restore TaskGroup
    /// fan-out once the underlying cancellation is root-caused (likely
    /// libxmtp + URLSession shared-connection-pool interaction or a
    /// transient `SessionStateError.clientIdInboxInconsistency` in the
    /// session state machine under concurrent waiters).
    func requestAgentJoins(templateIds: [String]) {
        guard !templateIds.isEmpty else { return }
        let slug = invite.urlSlug
        guard !slug.isEmpty else { return }
        Log.info("requestAgentJoins called with \(templateIds.count) templates (sequential): \(templateIds)")

        let forceErrorCode = agentJoinForceErrorCode
        let conversationId = conversation.id
        let session = self.session
        Task { [weak self] in
            var anyFailed = false
            for (index, templateId) in templateIds.enumerated() {
                if index > 0 {
                    // Brief gap between calls so the previous broadcast's
                    // libxmtp message-send fully settles before the next
                    // call's broadcast / API races against it.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let requestId = UUID().uuidString
                let outcome = await Self.performAgentJoinCall(
                    templateId: templateId,
                    slug: slug,
                    conversationId: conversationId,
                    requestId: requestId,
                    forceErrorCode: forceErrorCode,
                    session: session
                )
                if outcome == .failed { anyFailed = true }
            }
            if anyFailed {
                await MainActor.run { self?.onAgentJoinError() }
            }
        }
    }

    /// Discriminates the three outcomes of an `agents/join` call so callers
    /// can react differently — `.failed` drives the error UI, `.succeeded`
    /// drives the analytics metric, `.cancelled` (rapid re-tap or
    /// URLSession cancel) is a no-op on both axes.
    private enum AgentJoinOutcome {
        case succeeded
        case cancelled
        case failed
    }

    /// Performs a single `agents/join` call: broadcasts `.pending` before,
    /// broadcasts the appropriate failure status (`.failed` or
    /// `.noAgentsAvailable`) on error. Static + parameterized so both the
    /// single-flight and batched callers can share the same body without
    /// holding `self`.
    private static func performAgentJoinCall(
        templateId: String?,
        slug: String,
        conversationId: String,
        requestId: String,
        forceErrorCode: Int?,
        session: any SessionManagerProtocol
    ) async -> AgentJoinOutcome {
        Log.info("performAgentJoinCall starting templateId=\(templateId ?? "nil") requestId=\(requestId)")
        await Self.broadcastAgentJoinRequest(
            status: .pending, requestId: requestId,
            conversationId: conversationId, session: session
        )
        Log.info("performAgentJoinCall about to POST agents/join templateId=\(templateId ?? "nil") requestId=\(requestId)")
        do {
            _ = try await session.requestAgentJoin(
                slug: slug,
                templateId: templateId,
                options: nil,
                forceErrorCode: forceErrorCode
            )
            Log.info("performAgentJoinCall succeeded templateId=\(templateId ?? "nil") requestId=\(requestId)")
            return .succeeded
        } catch is CancellationError {
            Log.warning("performAgentJoinCall cancelled (CancellationError) templateId=\(templateId ?? "nil") requestId=\(requestId)")
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            Log.warning("performAgentJoinCall cancelled (URLError.cancelled) templateId=\(templateId ?? "nil") requestId=\(requestId)")
            return .cancelled
        } catch let error as APIError {
            Log.error("requestAgentJoin: agents/join APIError: \(error) - \(error.localizedDescription)")
            let status: AgentJoinStatus
            if case .noAgentsAvailable = error { status = .noAgentsAvailable } else { status = .failed }
            await Self.broadcastAgentJoinRequest(
                status: status, requestId: requestId,
                conversationId: conversationId, session: session
            )
            return .failed
        } catch {
            Log.error("requestAgentJoin: agents/join unknown error: \(error.localizedDescription)")
            await Self.broadcastAgentJoinRequest(
                status: .failed, requestId: requestId,
                conversationId: conversationId, session: session
            )
            return .failed
        }
    }

    private static func broadcastAgentJoinRequest(
        status: AgentJoinStatus,
        requestId: String,
        conversationId: String,
        session: any SessionManagerProtocol
    ) async {
        do {
            let messagingService = session.messagingService()
            let inboxResult = try await messagingService.sessionStateManager.waitForInboxReadyResult()
            guard let xmtpConversation = try await inboxResult.client.conversation(with: conversationId) else {
                Log.warning("Could not find XMTP conversation to broadcast agent join request")
                return
            }
            // Derive requestedBy from the ready inbox rather than accepting it
            // as a parameter. An earlier draft fell back to "" when the session
            // wasn't ready yet; that empty string would land in the XMTP
            // message payload as `requestedByInboxId`.
            let request = AgentJoinRequest(
                status: status,
                requestedByInboxId: inboxResult.client.inboxId,
                requestId: requestId
            )
            try await xmtpConversation.sendAgentJoinRequest(request)
        } catch {
            Log.warning("Failed to broadcast agent join request: \(error.localizedDescription)")
        }
    }

    private func clearAgentJoinTask(id: String) {
        guard agentJoinTaskId == id else { return }
        agentJoinTask = nil
        agentJoinTaskId = nil
    }

    private func onAgentJoinError() {
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

    /// Blocks the given inbox at the contact level, then leaves this
    /// conversation. The block is written *first* so the contact-list-aware
    /// inbound filter (`InboundConversationFilter`) honors the block on any
    /// future welcome from this inbox even if the leave call somehow fails
    /// or races with concurrent stream events. Callers pass the member's
    /// inboxId; the contact row is upserted if not already present so the
    /// `blockedAt` write has somewhere to land.
    func blockAndLeaveConvo(inboxId: String) {
        let contactsWriter = messagingService.contactsWriter()
        let consentWriter = consentWriter
        let conversation = conversation
        Task { [weak self] in
            guard let self else { return }
            do {
                // Ensure a contact row exists so block() has something to
                // flag. Idempotent — preserves identity columns on re-upsert.
                try await contactsWriter.upsertContact(
                    inboxId: inboxId,
                    addedViaConversationId: conversation.id,
                    profile: ContactProfileSnapshot()
                )
                try await contactsWriter.block(inboxId: inboxId)
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

    /// Resolved display name for the agent that emitted `request`, or nil if the agent
    /// is not (or no longer) in the conversation. Used by the capability picker card to
    /// label the asker. Connection-event summaries do their own name resolution at
    /// processor time via `MemberProfileInfo`.
    func askerDisplayName(for request: CapabilityRequest) -> String? {
        conversation.members
            .first(where: { $0.profile.inboxId == request.askerInboxId })?
            .displayName
    }

    func makeAgentFilesLinksRepository() -> AgentFilesLinksRepository {
        session.agentFilesLinksRepository(for: conversation.id)
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
        let agentDebugInfo = agentDebugInfoText()

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
                conversationDebugInfo: debugInfoURL,
                additionalInfo: agentDebugInfo
            )
        }.value
    }

    /// Summary of the convo's agents, staged into the exported bundle's
    /// convos-info.txt so log bundles carry agent verification and
    /// provenance details.
    private func agentDebugInfoText() -> String? {
        let agents = conversation.members.filter(\.isAgent)
        guard !agents.isEmpty else { return nil }
        var lines: [String] = ["Agents in convo (\(agents.count)):"]
        for agent in agents {
            let profile = agent.profile
            let issuer = agent.agentVerification.issuer?.rawValue ?? "none"
            let templateId = profile.agentTemplateId ?? "none"
            let instanceId = profile.agentInstanceId ?? "none"
            let publishedURL = profile.agentTemplatePublishedURL ?? "none"
            let summary = "verified=\(agent.isVerifiedAgent), issuer=\(issuer), templateId=\(templateId), instanceId=\(instanceId), publishedUrl=\(publishedURL)"
            lines.append("agent \(profile.inboxId): \(summary)")
        }
        return lines.joined(separator: "\n")
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
        let mockConversation: Conversation = .mock()
        let mockSession: any SessionManagerProtocol = MockInboxesService()
        let mockMessaging: any MessagingServiceProtocol = MockMessagingService()
        return ConversationViewModel(
            conversation: mockConversation,
            session: mockSession,
            messagingService: mockMessaging
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

    func onTapReadReceipts(_ group: MessagesGroup) {
        presentingReadByForGroup = group
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

    /// Detects a pasted agent-share link, lifts it out of the text into a
    /// composer chip, and kicks off an async resolve to populate the chip's
    /// name / emoji. Mirrors `checkForInviteURL`; runs from the same
    /// `messageText` onChange.
    func checkForAgentShareURL() {
        guard pendingAgentShare == nil,
              let share = MessageAgentShare.from(text: messageText) else {
            return
        }
        convosButtonTask?.cancel()
        convosButtonCancellable?.cancel()
        pendingAgentShare = PendingAgentShare(share: share, resolved: nil)
        messageText = ""
        let resolver = agentShareResolver
        Task { [weak self] in
            let info = await resolver.resolve(identifier: share.identifier)
            await MainActor.run {
                guard let self, self.pendingAgentShare?.share == share else { return }
                self.pendingAgentShare?.resolved = info
            }
        }
    }

    func clearPendingAgentShare() {
        pendingAgentShare = nil
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
                // The Convos-button conversation goes straight into invite
                // generation — there's no compose-then-commit cycle, so the
                // claimed row should be visible immediately.
                await session.commitClaimedConversation(id: existingConversationId)
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
