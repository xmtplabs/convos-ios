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
    let environment: AppEnvironment
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
        apiClient: (any ConvosAPIClientProtocol)? = nil,
        xmtpClientFactory: XMTPClientFactory = .onDisk
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
            apiClient: apiClient,
            xmtpClientFactory: xmtpClientFactory
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
        conversationStateManager(initialMemberInboxIds: [])
    }

    func conversationStateManager(
        initialMemberInboxIds: [String]
    ) -> any ConversationStateManagerProtocol {
        ConversationStateManager(
            sessionStateManager: sessionStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            initialMemberInboxIds: initialMemberInboxIds,
            backgroundUploadManager: backgroundUploadManager
        )
    }

    // MARK: Existing Conversation

    func conversationStateManager(for conversationId: String) -> any ConversationStateManagerProtocol {
        conversationStateManager(for: conversationId, initialMemberInboxIds: [])
    }

    func conversationStateManager(
        for conversationId: String,
        initialMemberInboxIds: [String]
    ) -> any ConversationStateManagerProtocol {
        ConversationStateManager(
            sessionStateManager: sessionStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            conversationId: conversationId,
            initialMemberInboxIds: initialMemberInboxIds,
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

    func agentTemplateContactsRepository() -> any AgentTemplateContactsRepositoryProtocol {
        AgentTemplateContactsRepository(databaseReader: databaseReader)
    }

    func agentTemplateContactsWriter() -> any AgentTemplateContactsWriterProtocol {
        AgentTemplateContactsWriter(databaseWriter: databaseWriter)
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

    func connectionGrantWriter() -> any CloudConnectionGrantWriterProtocol {
        CloudConnectionGrantWriter(
            sessionStateManager: sessionStateManager,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            myProfileWriter: myProfileWriter()
        )
    }

    func connectionEventWriter() -> any ConnectionEventWriterProtocol {
        ConnectionEventWriter(sessionStateManager: sessionStateManager)
    }

    func capabilityRequestResultWriter() -> any CapabilityRequestResultWriterProtocol {
        CapabilityRequestResultWriter(sessionStateManager: sessionStateManager)
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

    func initiatorPairingService() async throws -> any PairingServiceProtocol {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        let inboxId = result.client.inboxId
        let myProfile = try? await databaseReader.read { db in
            try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        return LivePairingService(
            role: .initiator(
                client: result.client,
                identityStore: identityStore,
                environment: environment,
                initiatorProfile: myProfile.map { profile in
                    LivePairingService.InitiatorProfile(
                        displayName: profile.name,
                        imageAssetIdentifier: profile.imageAssetIdentifier
                    )
                }
            )
        )
    }

    /// Sends a fresh `ProfileSnapshot` (containing the current profile
    /// metadata for every member) to every group the local user is in.
    /// Used by the post-pair broadcaster so a newly-paired installation
    /// has each conversation's member profiles populated locally without
    /// having to rely on history sync — every group gets one snapshot
    /// from the initiator immediately after the joiner's installation
    /// becomes active.
    ///
    /// Best-effort per group: a single group's failure is logged and
    /// skipped so a transient send error doesn't abort the fan-out.
    /// Returns the count of groups a snapshot was successfully sent to
    /// (0 when the inbox wasn't ready or the conversation list failed),
    /// so callers can tell whether the fan-out actually happened.
    @discardableResult
    func broadcastProfileSnapshotsToAllGroups() async -> Int {
        let result: InboxReadyResult
        do {
            result = try await sessionStateManager.waitForInboxReadyResult()
        } catch {
            Log.warning("MessagingService: broadcastProfileSnapshotsToAllGroups skipped, inbox not ready: \(error)")
            return 0
        }
        let conversations: [XMTPiOS.Conversation]
        do {
            conversations = try await result.client.conversationsProvider.list(
                createdAfterNs: nil,
                createdBeforeNs: nil,
                lastActivityBeforeNs: nil,
                lastActivityAfterNs: nil,
                limit: nil,
                consentStates: [.allowed],
                orderBy: .createdAt
            )
        } catch {
            Log.warning("MessagingService: broadcastProfileSnapshotsToAllGroups list failed: \(error)")
            return 0
        }
        // Sent sequentially rather than via a task group: `XMTPiOS.Group`
        // is not `Sendable`, so fanning these into concurrent tasks would
        // trip strict-concurrency errors. Post-pair is a one-time event,
        // so the sequential cost is acceptable.
        var sent: Int = 0
        for conversation in conversations {
            guard case let .group(group) = conversation else { continue }
            do {
                let memberInboxIds = try await group.members.map(\.inboxId)
                try await ProfileSnapshotBuilder.sendSnapshot(
                    group: group,
                    memberInboxIds: memberInboxIds
                )
                sent += 1
            } catch {
                Log.warning("MessagingService: ProfileSnapshot send failed for group \(group.id): \(error.localizedDescription)")
            }
        }
        Log.info("MessagingService: broadcasted ProfileSnapshot to \(sent) group(s) after pairing")
        return sent
    }

    func installationsSnapshot(refreshFromNetwork: Bool) async throws -> InstallationsSnapshot {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        let installations = try await result.client.listInstallations(refreshFromNetwork: refreshFromNetwork)
        return InstallationsSnapshot(
            inboxId: result.client.inboxId,
            currentInstallationId: result.client.installationId,
            installations: installations.sorted { lhs, rhs in
                switch (lhs.createdAt, rhs.createdAt) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.id < rhs.id
                }
            }
        )
    }

    func revokeOtherInstallations() async throws -> [String] {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        guard let identity = try await identityStore.load() else {
            throw MessagingServiceError.noIdentity
        }
        let installations = try await result.client.listInstallations(refreshFromNetwork: true)
        let currentId = result.client.installationId
        let others = installations.map(\.id).filter { $0 != currentId }
        guard !others.isEmpty else { return [] }
        try await result.client.revokeInstallations(
            signingKey: identity.keys.signingKey,
            installationIds: others
        )
        return others
    }

    func revokeInstallation(installationId: String) async throws {
        let result = try await sessionStateManager.waitForInboxReadyResult()
        guard installationId != result.client.installationId else {
            throw MessagingServiceError.cannotRevokeCurrentDevice
        }
        guard let identity = try await identityStore.load() else {
            throw MessagingServiceError.noIdentity
        }

        // Best-effort: notify the target installation BEFORE the revoke API
        // call so it can transition to `.error(DeviceReplacedError)` and
        // surface the `StaleDeviceBanner` in real time. libxmtp refuses
        // `findOrCreateDm(with: ownInboxId)` (GroupError.memberCannotBeSelf),
        // so instead we send the `DeviceRemovedContent` into the most
        // recent existing conversation the inbox is in — both
        // installations under the inbox are members of every such
        // conversation, so the target receives the message via its
        // shared message stream. Other inboxes in the conversation
        // ignore the codec (it's a no-op for them).
        //
        // Falls through silently if the inbox has no conversations yet
        // (rare edge case); the receiver still picks up the change on
        // next session bootstrap or foreground entry.
        await sendDeviceRemovedSignal(installationId: installationId, client: result.client)

        try await result.client.revokeInstallations(
            signingKey: identity.keys.signingKey,
            installationIds: [installationId]
        )
    }
}

enum MessagingServiceError: Error {
    case noIdentity
    case cannotRevokeCurrentDevice
}

private extension MessagingService {
    /// Sends a `DeviceRemovedContent` so the target installation sees
    /// `StaleDeviceBanner` in real time. Best-effort — any failure is
    /// logged and swallowed so the caller's revoke flow still proceeds.
    ///
    /// Channel-selection strategy (in priority order):
    ///   1. The user's pre-warmed unused conversation (`DBConversation`
    ///      with `isUnused == true`). It exists from silent identity
    ///      creation, has only the user's own inbox as a member, and is
    ///      hidden from the UI — so other users never see the codec and
    ///      no peer logs a decode failure. This is the right channel
    ///      99% of the time.
    ///   2. Fallback: any real, allowed, non-unused conversation. We pay
    ///      the price of a stray codec arriving at peers (they log a
    ///      decode warning) only when no unused conversation exists.
    ///   3. If neither exists, log + return; the revoked installation
    ///      catches up via `assertInstallationActive` on its next
    ///      foreground entry or auth bootstrap.
    func sendDeviceRemovedSignal(installationId: String, client: any XMTPClientProvider) async {
        if let conversationId = try? await findUnusedConversationId(),
           let conversation = try? await client.conversationsProvider.findConversation(
               conversationId: conversationId
           ) {
            do {
                try await conversation.send(
                    content: DeviceRemovedContent(revokedInstallationId: installationId),
                    options: SendOptions(contentType: ContentTypeDeviceRemoved)
                )
                Log.info("MessagingService: sent DeviceRemoved for \(installationId) into hidden unused conversation \(conversationId)")
                return
            } catch {
                Log.warning("MessagingService: send into unused conversation failed (\(error)), falling back to allowed conversation")
            }
        }

        do {
            let conversations = try await client.conversationsProvider.list(
                createdAfterNs: nil,
                createdBeforeNs: nil,
                lastActivityBeforeNs: nil,
                lastActivityAfterNs: nil,
                limit: 5,
                consentStates: [.allowed],
                orderBy: .createdAt
            )
            // Filter out unused conversations (they'd have been caught
            // above; this is defensive in case the DB-level lookup
            // returned nil but libxmtp still has the row).
            let unusedIds = (try? await findAllUnusedConversationIds()) ?? []
            guard let target = conversations.first(where: { !unusedIds.contains($0.id) }) else {
                Log.warning("MessagingService: no usable conversation to send DeviceRemoved into — receiver will catch up on next foreground")
                return
            }
            try await target.send(
                content: DeviceRemovedContent(revokedInstallationId: installationId),
                options: SendOptions(contentType: ContentTypeDeviceRemoved)
            )
            Log.info("MessagingService: sent DeviceRemoved for \(installationId) into fallback conversation \(target.id)")
        } catch {
            Log.warning("MessagingService: failed to send DeviceRemoved signal (proceeding with revoke): \(error)")
        }
    }

    func findUnusedConversationId() async throws -> String? {
        try await databaseReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == true)
                .order(DBConversation.Columns.createdAt.desc)
                .fetchOne(db)?
                .id
        }
    }

    func findAllUnusedConversationIds() async throws -> Set<String> {
        try await databaseReader.read { db in
            Set(
                try DBConversation
                    .filter(DBConversation.Columns.isUnused == true)
                    .fetchAll(db)
                    .map(\.id)
            )
        }
    }
}
