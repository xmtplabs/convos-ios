import Combine
import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// Service for managing XMTP messaging for a single inbox
///
/// MessagingService coordinates all messaging operations for one inbox identity,
/// including message sending/receiving, conversation management, and member operations.
/// Each service instance manages one XMTP client through the InboxStateManager and
/// provides factory methods for creating writers and repositories scoped to this inbox.
/// The service handles authorization, streaming, and push notification registration.
///
/// @unchecked Sendable: All stored properties are immutable references (`let`) to
/// Sendable protocol types, except `cancellables` (only modified during init and
/// deinit). Methods create new instances rather than sharing mutable state.
final class MessagingService: MessagingServiceProtocol, @unchecked Sendable {
    private let authorizationOperation: any AuthorizeInboxOperationProtocol
    let sessionStateManager: any SessionStateManagerProtocol
    /// Captured at construction for the topic-subscription APIs that
    /// require the backend clientId; empty string on the failed-keychain
    /// path, which is structurally unreachable (every caller goes through
    /// `waitForInboxReadyResult()` first, which throws the keychain error).
    private let clientId: String
    internal let identityStore: any KeychainIdentityStoreProtocol
    internal let databaseReader: any DatabaseReader
    internal let databaseWriter: any DatabaseWriter
    internal let deviceInfoProvider: any DeviceInfoProviding
    private let environment: AppEnvironment
    private let backgroundUploadManager: any BackgroundUploadManagerProtocol
    private var cancellables: Set<AnyCancellable> = []

    // swiftlint:disable:next function_parameter_count
    static func authorizedMessagingService(
        for inboxId: String,
        clientId: String,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        startsStreamingServices: Bool,
        overrideJWTToken: String? = nil,
        platformProviders: PlatformProviders,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        apiClient: (any ConvosAPIClientProtocol)? = nil
    ) -> MessagingService {
        let authorizationOperation = AuthorizeInboxOperation.authorize(
            inboxId: inboxId,
            clientId: clientId,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            startsStreamingServices: startsStreamingServices,
            overrideJWTToken: overrideJWTToken,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient
        )
        return MessagingService(
            authorizationOperation: authorizationOperation,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment,
            deviceInfoProvider: platformProviders.deviceInfo,
            backgroundUploadManager: platformProviders.backgroundUploadManager
        )
    }

    internal init(authorizationOperation: AuthorizeInboxOperation,
                  databaseWriter: any DatabaseWriter,
                  databaseReader: any DatabaseReader,
                  identityStore: any KeychainIdentityStoreProtocol,
                  environment: AppEnvironment,
                  deviceInfoProvider: any DeviceInfoProviding,
                  backgroundUploadManager: any BackgroundUploadManagerProtocol) {
        self.identityStore = identityStore
        self.authorizationOperation = authorizationOperation
        self.sessionStateManager = authorizationOperation.stateMachine
        self.clientId = authorizationOperation.stateMachine.initialClientId
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.deviceInfoProvider = deviceInfoProvider
        self.environment = environment
        self.backgroundUploadManager = backgroundUploadManager
        self.scheduleContactsBackfill()
    }

    /// Triggers the one-time contacts-list backfill the first time the
    /// session reaches a usable state. Spawned as a detached background
    /// Task that awaits `waitForInboxReadyResult` (resolves once per
    /// service lifetime) and then runs the backfill. No observer pattern,
    /// no fire-once flag, no synchronous-fire-at-registration trap — the
    /// `await` only resumes once on the first ready, so re-emissions
    /// (foreground transitions, etc.) cannot retrigger this flow.
    ///
    /// Idempotent across launches via the `conversation_contacts_sync`
    /// marker. No-ops when the inbox singleton has not yet been written.
    ///
    /// MIGRATION CODE — TARGETED FOR REMOVAL.
    /// The contacts list shipped with this version. For installs that
    /// upgraded from a prior version, this backfill seeds `contact` from
    /// each conversation the local user has already acted in. Once every
    /// active install has run this once, the steady-state triggers
    /// (first-message hook in `OutgoingMessageWriter`, member-added hooks
    /// in `ConversationMetadataWriter`/`ConversationWriter`, profile-sync
    /// hooks in `StreamProcessor`/etc.) keep `contact` correct without
    /// any backfill. After ~90 days of broad adoption (or whenever
    /// telemetry shows >99% of active installs already have contacts
    /// populated), this method, `ContactsBackfillService`, the matching
    /// factory on `MessagingServiceProtocol`, and the related tests can
    /// all be deleted.
    private func scheduleContactsBackfill() {
        let backfill = contactsBackfillService()
        let stateManager = sessionStateManager
        Task.detached(priority: .background) {
            do {
                _ = try await stateManager.waitForInboxReadyResult()
                try await backfill.backfillIfNeeded()
            } catch {
                // `waitForInboxReadyResult` throws on `.error` rather than
                // continuing to wait for an eventual `.ready`, so a transient
                // session error during launch will skip backfill for this
                // service lifetime. The marker query (`s.conversationId IS
                // NULL`) ensures the next launch picks up any candidates
                // that were missed; worst case the user sees a
                // launch-late contacts list. Acceptable for a one-time
                // migration.
                Log.warning("ContactsBackfillService skipped this launch: \(error). Will retry on next launch.")
            }
        }
    }

    /// Constructs a MessagingService that represents the failed-keychain-read
    /// branch of `SessionManager.loadOrCreateService`. No authorization is
    /// attempted; `sessionStateManager.currentState` returns `.error` with
    /// the real keychain error. Used so downstream code can surface a
    /// "keychain unreadable — retry" affordance without the cost of spinning
    /// up a real state machine + authorization task for every retry.
    internal init(identityReadFailure error: any Error,
                  databaseWriter: any DatabaseWriter,
                  databaseReader: any DatabaseReader,
                  identityStore: any KeychainIdentityStoreProtocol,
                  environment: AppEnvironment,
                  deviceInfoProvider: any DeviceInfoProviding,
                  backgroundUploadManager: any BackgroundUploadManagerProtocol) {
        let operation = FailedIdentityLoadOperation(error: error)
        self.identityStore = identityStore
        self.authorizationOperation = operation
        self.sessionStateManager = operation.stateMachine
        self.clientId = ""
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.deviceInfoProvider = deviceInfoProvider
        self.environment = environment
        self.backgroundUploadManager = backgroundUploadManager
    }

    deinit {
        cancellables.removeAll()
    }

    // MARK: State

    func stop() {
        authorizationOperation.stop()
    }

    func stop() async {
        await authorizationOperation.stop()
    }

    func stopAndDelete() {
        authorizationOperation.stopAndDelete()
    }

    func stopAndDelete() async {
        await authorizationOperation.stopAndDelete()
    }

    func waitForDeletionComplete() async {
        await sessionStateManager.waitForDeletionComplete()
    }

    // MARK: My Profile

    func myProfileWriter() -> any MyProfileWriterProtocol {
        MyProfileWriter(sessionStateManager: sessionStateManager, databaseWriter: databaseWriter)
    }

    func myGlobalProfileWriter() -> any MyGlobalProfileWriterProtocol {
        MyGlobalProfileWriter(sessionStateManager: sessionStateManager, databaseWriter: databaseWriter)
    }

    func myGlobalProfileRepository() -> any MyGlobalProfileRepositoryProtocol {
        MyGlobalProfileRepository(sessionStateManager: sessionStateManager, databaseReader: databaseReader)
    }

    // MARK: New Conversation

    func conversationStateManager() -> any ConversationStateManagerProtocol {
        return ConversationStateManager(
            sessionStateManager: sessionStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            backgroundUploadManager: backgroundUploadManager
        )
    }

    // MARK: Existing Conversation

    func conversationStateManager(for conversationId: String) -> any ConversationStateManagerProtocol {
        return ConversationStateManager(
            sessionStateManager: sessionStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            conversationId: conversationId,
            backgroundUploadManager: backgroundUploadManager
        )
    }

    // MARK: Conversations

    func conversationConsentWriter() -> any ConversationConsentWriterProtocol {
        ConversationConsentWriter(
            sessionStateManager: sessionStateManager,
            databaseWriter: databaseWriter
        )
    }

    func conversationLocalStateWriter() -> any ConversationLocalStateWriterProtocol {
        ConversationLocalStateWriter(databaseWriter: databaseWriter)
    }

    // MARK: Getting/Sending Messages

    func messageWriter(
        for conversationId: String,
        backgroundUploadManager: any BackgroundUploadManagerProtocol
    ) -> any OutgoingMessageWriterProtocol {
        OutgoingMessageWriter(
            sessionStateManager: sessionStateManager,
            databaseWriter: databaseWriter,
            conversationId: conversationId,
            photoService: PhotoAttachmentService(),
            pendingUploadWriter: PendingPhotoUploadWriter(databaseWriter: databaseWriter),
            backgroundUploadManager: backgroundUploadManager,
            attachmentLocalStateWriter: AttachmentLocalStateWriter(databaseWriter: databaseWriter),
            contactSyncCoordinator: contactSyncCoordinator()
        )
    }

    // MARK: Contacts

    func contactsRepository() -> any ContactsRepositoryProtocol {
        ContactsRepository(databaseReader: databaseReader)
    }

    func contactsWriter() -> any ContactsWriterProtocol {
        ContactsWriter(databaseWriter: databaseWriter)
    }

    func contactSyncCoordinator() -> any ContactSyncCoordinatorProtocol {
        ContactSyncCoordinator(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader
        )
    }

    func contactsBackfillService() -> any ContactsBackfillServiceProtocol {
        ContactsBackfillService(
            databaseReader: databaseReader,
            coordinator: contactSyncCoordinator()
        )
    }

    func reactionWriter() -> any ReactionWriterProtocol {
        ReactionWriter(sessionStateManager: sessionStateManager,
                       databaseWriter: databaseWriter)
    }

    func readReceiptWriter() -> any ReadReceiptWriterProtocol {
        ReadReceiptWriter(sessionStateManager: sessionStateManager,
                          databaseWriter: databaseWriter)
    }

    func replyWriter() -> any ReplyMessageWriterProtocol {
        ReplyMessageWriter(sessionStateManager: sessionStateManager,
                           databaseWriter: databaseWriter)
    }

    // MARK: - Group Management

    func conversationMetadataWriter() -> any ConversationMetadataWriterProtocol {
        ConversationMetadataWriter(
            sessionStateManager: sessionStateManager,
            inviteWriter: InviteWriter(identityStore: identityStore, databaseWriter: databaseWriter),
            databaseWriter: databaseWriter,
            contactSyncCoordinator: contactSyncCoordinator()
        )
    }

    func conversationExplosionWriter() -> any ConversationExplosionWriterProtocol {
        ConversationExplosionWriter(
            operations: XMTPExplodeGroupOperations(sessionStateManager: sessionStateManager),
            metadataWriter: conversationMetadataWriter()
        )
    }

    func conversationPermissionsRepository() -> any ConversationPermissionsRepositoryProtocol {
        ConversationPermissionsRepository(sessionStateManager: sessionStateManager,
                                          databaseReader: databaseReader)
    }

    func connectionGrantWriter() -> any ConnectionGrantWriterProtocol {
        ConnectionGrantWriter(
            sessionStateManager: sessionStateManager,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            myProfileWriter: myProfileWriter()
        )
    }

    func uploadImage(data: Data, filename: String) async throws -> String {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        return try await result.apiClient.uploadAttachment(
            data: data,
            filename: filename,
            contentType: "image/jpeg",
            acl: "public-read"
        )
    }

    func uploadImageAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        return try await result.apiClient.uploadAttachmentAndExecute(
            data: data,
            filename: filename,
            afterUpload: afterUpload
        )
    }

    func setConversationNotificationsEnabled(_ enabled: Bool, for conversationId: String) async throws {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        let topic = conversationId.xmtpGroupTopicFormat
        let localStateWriter = conversationLocalStateWriter()

        if enabled {
            let deviceId = DeviceInfo.deviceIdentifier
            try await result.apiClient.subscribeToTopics(
                deviceId: deviceId,
                clientId: clientId,
                topics: [topic]
            )
        } else {
            try await result.apiClient.unsubscribeFromTopics(
                clientId: clientId,
                topics: [topic]
            )
        }

        try await localStateWriter.setMuted(!enabled, for: conversationId)
    }

    func sendTypingIndicator(isTyping: Bool, for conversationId: String) async throws {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        guard let sender = try await result.client.messageSender(for: conversationId) else {
            return
        }
        try await sender.sendTypingIndicator(isTyping: isTyping)
    }
}
