import Combine
import ConvosConnections
import Foundation

/// Progress events for inbox deletion
public enum InboxDeletionProgress: Sendable, Equatable {
    case clearingDeviceRegistration
    case stoppingServices(completed: Int, total: Int)
    case deletingFromDatabase
    case completed
}

public protocol SessionManagerProtocol: AnyObject, Sendable {
    // MARK: Pairing

    /// Constructs a joiner-side pairing service backed by an ephemeral
    /// XMTP client. The host app calls this when the joiner deep link
    /// arrives (`/pair/<slug>`) to present `JoinerPairingSheetView` on a
    /// fresh install. The ephemeral client lives only inside the returned
    /// service; on `stop()` (or successful pairing) the underlying libxmtp
    /// db directory is wiped.
    func joinerPairingService() -> any PairingServiceProtocol

    /// Called after a successful pairing on the joiner side. Drops any
    /// cached `MessagingService` so the next access reads the (now-paired)
    /// keychain entry. If silent identity creation had already produced a
    /// placeholder inbox before the pairing deep link landed, this also
    /// stops that placeholder service.
    func refreshAfterPairingCompleted() async

    /// Returns true if the local database holds at least one conversation
    /// that the user has actually engaged with (`isUnused == false`). The
    /// pairing flow uses this — not "is there *any* keychain identity?" —
    /// to decide whether the joiner has real data that would be lost on
    /// pair. Silent identity creation + the pre-warmed unused-conversation
    /// cache means every fresh install has an identity and one unused
    /// conversation; that combination should still let the user pair
    /// without a destructive warning.
    func hasAnyUsedConversations() async -> Bool

    /// Identities found in the iCloud-synced keychain backup slot that
    /// don't match this install's identity - other devices on the same
    /// iCloud account the user could pair with. Newest backup first.
    /// Drives the first-install "Pair <device>?" prompt; returns an empty
    /// array when there is nothing to offer.
    func pairableDeviceBackups() async -> [PairableDeviceBackup]

    /// Mints a signed pairing-invite slug on behalf of the backed-up
    /// device (its synced private key signs the invite, exactly like the
    /// QR flow does on the initiator), so the joiner flow can target that
    /// device without scanning anything.
    func pairingInviteSlug(forBackupInboxId inboxId: String, expiresAt: Date) async throws -> String

    // MARK: Inbox Management

    /// Returns the shared messaging service and an optional conversation id
    /// for a group pre-prepared by `UnusedConversationCache`. A background
    /// prewarm is kicked off for the next caller. `conversationId` is nil
    /// if no prepared group was available and the caller should create one
    /// on demand.
    ///
    /// **Visibility contract:** when `conversationId` is non-nil, the row
    /// stays `isUnused = true` (hidden from the chats list) until the
    /// caller calls `commitClaimedConversation(id:)`. If the caller will
    /// instead abandon the row, it should call `discardClaimedConversation`
    /// (which deletes the row) or, if the row should be kept on disk but
    /// the cache claim dropped, `releaseClaimedConversation`.
    func prepareNewConversation() async -> (service: AnyMessagingService, conversationId: String?)

    /// Promotes a row previously claimed via `prepareNewConversation()`
    /// into a real visible conversation: flips `isUnused = false` and
    /// refreshes its `createdAt` so it sorts at the top of the chats
    /// list. Call this exactly once, when the user has confirmed intent
    /// (sent the builder bundle, generated an invite, sent the first
    /// message, etc.).
    func commitClaimedConversation(id conversationId: String) async

    /// Drops the in-memory cache claim without touching the DB row. The
    /// row stays `isUnused = true` and remains hidden. Use this when the
    /// caller is bailing out without committing or discarding — e.g. the
    /// flow re-enters and wants to re-claim from a fresh prewarm.
    func releaseClaimedConversation(id conversationId: String) async

    /// Registers a conversation created outside the cache (e.g. the agent
    /// builder's auto-created hidden draft, `createConversation(startsUnused:)`)
    /// as claimed, so `prepareNewConversation()` can't hand the same row to
    /// another caller while it's actively in use. In-memory only: an app
    /// restart clears the claim, making an abandoned hidden row consumable
    /// by the cache again.
    func registerClaimedConversation(id conversationId: String) async

    /// Drops a conversation that was claimed via `prepareNewConversation()`,
    /// unconditionally — the entry point for the explicit user Delete action
    /// and the Agent Builder's deliberate cancel. Implicit dismiss-cleanup
    /// should call `discardClaimedConversationIfUnengaged` instead so an
    /// engaged conversation is kept. Deletes the local `DBConversation` row
    /// and its dependent rows (members, profiles, local state) so the
    /// conversation disappears from the conversations list, and releases the
    /// in-memory cache claim so the next prewarm runs. The single-inbox
    /// refactor turned the older `session.deleteInbox` cleanup into a no-op
    /// (it would destroy the user's account); this is the replacement scoped
    /// to a single conversation. Draft ids are a no-op — drafts don't have
    /// on-disk rows the user can see.
    func discardClaimedConversation(id conversationId: String) async

    /// Engagement-gated variant of `discardClaimedConversation` for implicit
    /// cleanup paths (sheet dismiss, flow teardown, superseded claims). Reads
    /// `ConversationEngagement.isEngaged` first: an engaged conversation
    /// (customized metadata, chat messages, another member now or ever, or a
    /// shared invite link) is
    /// committed visible and kept instead of destroyed; an untouched one goes
    /// through the full discard. Explicit user deletes should keep calling
    /// the unconditional `discardClaimedConversation` - a deliberate delete
    /// must never be silently overridden by the gate.
    func discardClaimedConversationIfUnengaged(id conversationId: String) async

    func deleteAllInboxes() async throws
    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error>

    // MARK: Account deletion

    /// Deletes the account for real: durable record, backend deletion
    /// while the identity keys still exist, best-effort installation
    /// revocation, then the manifest-driven local wipe. Distinct from
    /// `deleteAllInboxesWithProgress`, which is a local reset that leaves
    /// the backend account alive.
    func deleteAccountWithProgress() -> AsyncThrowingStream<AccountDeletionProgress, Error>

    /// Current durable deletion state (pending-retry UI, provisioning
    /// gate diagnostics).
    func accountDeletionStatus() -> AccountDeletionLoadResult

    /// Registers the app-layer wipe steps (StoreKit defaults, analytics
    /// identity, UI defaults). Call once at app startup.
    func setAccountDeletionAppHooks(_ hooks: AccountDeletionAppHooks)

    // MARK: Messaging Services

    func messagingService() -> AnyMessagingService
    func messagingServiceSync() -> AnyMessagingService

    // MARK: Factory methods for repositories

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol

    /// Direct-add agent join: provisions the agent via the backend (declaring
    /// the target conversation) and adds its XMTP inbox with addMembers. The
    /// runtime observes the resulting group welcome and attaches — once the
    /// add lands, the agent boots with no further calls. No invite slug
    /// involved.
    func addAgentToConversation(
        conversationId: String,
        templateId: String?,
        options: ConvosAPI.AgentJoinOptions?,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse

    /// Opportunistic foreground republish of the user's timezone across every
    /// agent conversation (agent-timezone Channel B refresh). Throttled so a
    /// conversation is only republished when the device timezone changed since
    /// the last published value. Call only from the foregrounded main app.
    func republishAgentTimezones() async

    func conversationRepository(for conversationId: String) -> any ConversationRepositoryProtocol

    /// Owns the direct agent-builder generation lifecycle (submit -> poll ->
    /// invite). Session-scoped so the poll loop survives the builder sheet.
    func agentTemplateRepository() -> any AgentTemplateRepositoryProtocol

    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol

    func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol
    func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol
    func voiceMemoTranscriptRepository() -> any VoiceMemoTranscriptRepositoryProtocol
    func voiceMemoTranscriptWriter() -> any VoiceMemoTranscriptWriterProtocol
    func voiceMemoTranscriptionService() -> any VoiceMemoTranscriptionServicing

    func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol
    func agentFilesLinksRepository(for conversationId: String) -> AgentFilesLinksRepository
    func agentBuilderSummaryWriter() -> any AgentBuilderSummaryWriterProtocol
    func agentBuilderSummaryRepository() -> any AgentBuilderSummaryRepositoryProtocol
    func builderBundleHiddenMessagesRepository() -> any BuilderBundleHiddenMessagesRepositoryProtocol
    func thinkingSessionRepository() -> any ThinkingSessionRepositoryProtocol

    /// Resolves a pasted/received agent-share link to the shared template's
    /// public profile (name / emoji / description) for rendering its contact
    /// card. A default returns `MockAgentShareResolver`; the real
    /// `ConvosAPIClient`-backed resolver is wired in `SessionManager` once the
    /// iOS client method for the backend's template-resolve endpoint lands.
    func agentShareResolver() -> any AgentShareResolving

    /// Resolves whether the current user already belongs to the conversation a
    /// received/sent invite points to (and that conversation's member count) so
    /// the in-chat invite card can show "N members" instead of "Tap to join". A
    /// default returns `NoopInviteMembershipResolver`; the real GRDB-backed
    /// resolver is wired in `SessionManager`.
    func inviteMembershipResolver() -> any InviteMembershipResolving

    func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol
    func conversationsCountRepo(
        for consent: [Consent],
        kinds: [ConversationKind]
    ) -> any ConversationsCountRepositoryProtocol
    func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol

    // MARK: Notifications

    func notifyChangesInDatabase()
    func shouldDisplayNotification(for conversationId: String) async -> Bool

    /// Tells the session manager whether the conversations list is currently
    /// on-screen. Used to suppress in-app notification banners — the list
    /// already surfaces the new-message indicator, so a banner would be
    /// redundant.
    func setIsOnConversationsList(_ isOn: Bool)

    /// Ensures the messaging service is ready before processing a notification
    /// for the given conversation. Safe to call from the NSE.
    func wakeInboxForNotification(conversationId: String)

    // MARK: Helpers

    func inboxId(for conversationId: String) async -> String?

    // MARK: Debug

    func pendingInviteDetails() throws -> [PendingInviteDetail]
    func deleteExpiredPendingInvites() async throws -> Int
    func isAccountOrphaned() throws -> Bool

    // MARK: Asset Renewal

    func makeAssetRenewalManager() async -> AssetRenewalManager

    // MARK: Connections

    func cloudConnectionManager(callbackURLScheme: String) -> any CloudConnectionManagerProtocol
    func cloudConnectionRepository() -> any CloudConnectionRepositoryProtocol

    // MARK: Capability resolution

    /// Session-scoped registry of `CapabilityProvider`s. Both the device subsystem
    /// (`ConvosConnections`) and the cloud subsystem (`CloudConnectionManager`) register
    /// providers here at session bootstrap and on link/unlink.
    func capabilityProviderRegistry() -> any CapabilityProviderRegistry

    /// Session-scoped capability resolver, GRDB-backed. Routes
    /// `(subject, conversation, capability)` to one or more providers per the
    /// federation rules in `CapabilityResolutionValidator`.
    func capabilityResolver() -> any CapabilityResolver

    /// Per-conversation observer that publishes the latest unresolved
    /// `capability_request`. The picker view model subscribes; recomputes its
    /// layout whenever a fresh request lands or the most recent one gets a
    /// matching result.
    func capabilityRequestRepository(for conversationId: String) -> any CapabilityRequestRepositoryProtocol

    /// Routes per-`ConnectionKind` permission prompts into ConvosConnections data
    /// sources. The picker's Connect path calls this to drive the iOS prompt without
    /// the view model having to know about HealthKit / EventKit / etc.
    func deviceConnectionAuthorizer() -> any DeviceConnectionAuthorizer

    /// `DataSink` the host has linked for `kind`, or `nil` if the host opted out
    /// of that kind via `PlatformProviders.deviceConnections`. Lets the view-model
    /// layer query a sink's `actionSchemas()` without hard-referencing per-kind
    /// classes (which would force the corresponding Apple framework into the
    /// binary even when the host doesn't ship that kind).
    func deviceDataSink(for kind: ConnectionKind) -> (any DataSink)?

    /// Per-conversation observer of every `(subject, capability)` resolution the user
    /// has approved. Conversation Info uses this to render the "Connections" section.
    func capabilityResolutionsRepository(for conversationId: String) -> any CapabilityResolutionsRepositoryProtocol
    func connectionEnablementStore() -> any EnablementStore
}

extension SessionManagerProtocol {
    /// Defaults for conformers that don't participate in account deletion
    /// (previews, test mocks). The real flow lives on `SessionManager`.
    public func deleteAccountWithProgress() -> AsyncThrowingStream<AccountDeletionProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AccountDeletionError.identityUnavailable)
        }
    }

    public func accountDeletionStatus() -> AccountDeletionLoadResult {
        .none
    }

    public func setAccountDeletionAppHooks(_ hooks: AccountDeletionAppHooks) {}

    /// Default for conformers without keychain access (test mocks): no
    /// other devices to pair with. The real lookup lives on `SessionManager`.
    public func pairableDeviceBackups() async -> [PairableDeviceBackup] {
        []
    }

    /// Default for conformers without keychain access (test mocks). The
    /// real signing path lives on `SessionManager`.
    public func pairingInviteSlug(forBackupInboxId inboxId: String, expiresAt: Date) async throws -> String {
        throw KeychainIdentityStoreError.identityNotFound("synced backup for pairing")
    }

    /// Default agent-share resolver. Returns the mock until the API-backed
    /// resolver is wired into `SessionManager`, so every conformer (including
    /// test mocks) gets a working resolver without bespoke wiring.
    public func agentShareResolver() -> any AgentShareResolving {
        MockAgentShareResolver()
    }

    /// Default invite-membership resolver. Returns the no-op resolver so every
    /// conformer (including test mocks) renders the card's default state; the
    /// GRDB-backed resolver is wired in `SessionManager`.
    public func inviteMembershipResolver() -> any InviteMembershipResolving {
        NoopInviteMembershipResolver()
    }

    public func addAgentToConversation(conversationId: String) async throws -> ConvosAPI.AgentJoinResponse {
        try await addAgentToConversation(conversationId: conversationId, templateId: nil, options: nil, forceErrorCode: nil)
    }

    /// Default agent-template repository. Returns the no-op until the real
    /// repository is wired in `SessionManager`, so test mocks conform without
    /// bespoke wiring.
    public func agentTemplateRepository() -> any AgentTemplateRepositoryProtocol {
        NoOpAgentTemplateRepository()
    }

    public func addAgentToConversation(
        conversationId: String,
        options: ConvosAPI.AgentJoinOptions?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        try await addAgentToConversation(conversationId: conversationId, templateId: nil, options: options, forceErrorCode: nil)
    }

    public func addAgentToConversation(
        conversationId: String,
        templateId: String?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        try await addAgentToConversation(conversationId: conversationId, templateId: templateId, options: nil, forceErrorCode: nil)
    }
}
