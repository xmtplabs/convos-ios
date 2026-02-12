import Foundation
import GRDB
@preconcurrency import XMTPiOS

// MARK: - UnusedConversationCacheProtocol

/// Protocol for managing pre-created unused conversations for faster user onboarding
public protocol UnusedConversationCacheProtocol: Actor {
    /// Prepares an unused conversation (inbox + conversation + invite) if needed
    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async

    /// Consumes the unused conversation if available, returns ready-to-use service + conversation ID
    /// - Returns: A tuple containing the messaging service and optional conversation ID.
    ///            The conversation ID is non-nil when an unused conversation was consumed,
    ///            nil when created fresh (requiring conversation creation on demand).
    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?)

    /// Consumes only the inbox (messaging service) from the cache, discarding any pre-created conversation.
    /// Used for join flows where we want a fast inbox but will use a different conversation.
    /// - Returns: A messaging service (from cache or freshly created). conversationId is always nil.
    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol

    /// Checks if the given conversation ID is the unused conversation
    func isUnusedConversation(_ conversationId: String) -> Bool

    /// Checks if the given inbox ID is the unused inbox
    func isUnusedInbox(_ inboxId: String) -> Bool

    /// Clears unused inbox and conversation from keychain
    func clearUnusedFromKeychain()

    /// Checks if there is an unused conversation available
    func hasUnusedConversation() -> Bool
}

// MARK: - UnusedConversationCacheError

enum UnusedConversationCacheError: Error {
    case invalidConversationType
}

// MARK: - UnusedConversationCache

/// Manages pre-created unused conversations for faster user onboarding
///
/// UnusedConversationCache implements an optimization pattern where XMTP inboxes,
/// conversations, and invites are pre-created and cached before users need them,
/// reducing perceived latency when creating new conversations. The cache:
/// - Pre-creates a single "unused" inbox in the background
/// - Creates an XMTP conversation published to the network
/// - Generates an invite with signed slug
/// - Stores inbox ID and conversation ID in keychain
/// - Marks the conversation with isUnused = true in the database
/// - Automatically creates a new unused conversation after consumption
///
/// This allows the app to skip expensive XMTP client creation and conversation
/// publishing when users create their first conversation, making the UX feel instant.
///
/// Graceful degradation: If conversation or invite creation fails after inbox creation,
/// the inbox is kept. On consumption, the app uses what succeeded and creates the
/// rest on-demand.
public actor UnusedConversationCache: UnusedConversationCacheProtocol {
    // MARK: - Properties

    private let keychainService: any KeychainServiceProtocol
    private let identityStore: any KeychainIdentityStoreProtocol
    private let platformProviders: PlatformProviders
    private let deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)?
    private let apiClient: (any ConvosAPIClientProtocol)?
    private var unusedMessagingService: MessagingService?
    private var isCreatingUnused: Bool = false
    private var backgroundCreationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        keychainService: any KeychainServiceProtocol = KeychainService(),
        identityStore: any KeychainIdentityStoreProtocol,
        platformProviders: PlatformProviders,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        apiClient: (any ConvosAPIClientProtocol)? = nil
    ) {
        self.keychainService = keychainService
        self.identityStore = identityStore
        self.platformProviders = platformProviders
        self.deviceRegistrationManager = deviceRegistrationManager
        self.apiClient = apiClient
    }

    // MARK: - Public Methods

    /// Checks if an unused conversation is available and prepares one if needed
    public func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        guard unusedMessagingService == nil else {
            Log.debug("Unused messaging service already exists")
            return
        }

        if let unusedConversationId = getUnusedConversationFromKeychain() {
            Log.info("Found unused conversation ID in keychain: \(unusedConversationId)")
            let conversationExists = await validateUnusedConversationExists(
                conversationId: unusedConversationId,
                databaseReader: databaseReader
            )
            if !conversationExists {
                Log.warning("Unused conversation not found in database, clearing and recreating")
                clearUnusedFromKeychain()
            } else if let unusedInboxId = getUnusedInboxFromKeychain() {
                do {
                    try await authorizeUnusedInbox(
                        inboxId: unusedInboxId,
                        databaseWriter: databaseWriter,
                        databaseReader: databaseReader,
                        environment: environment
                    )
                    return
                } catch {
                    Log.error("Failed authorizing unused inbox: \(error.localizedDescription)")
                    clearUnusedFromKeychain()
                }
            } else {
                Log.warning("Unused conversation exists but inbox ID missing, cleaning up orphan")
                await cleanupOrphanedConversation(
                    conversationId: unusedConversationId,
                    databaseWriter: databaseWriter
                )
                clearUnusedFromKeychain()
            }
        } else if let unusedInboxId = getUnusedInboxFromKeychain() {
            Log.info("Found unused inbox ID in keychain (no conversation): \(unusedInboxId)")
            do {
                try await authorizeUnusedInbox(
                    inboxId: unusedInboxId,
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )
                await createConversationForExistingInbox(
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )
                return
            } catch {
                Log.error("Failed authorizing unused inbox: \(error.localizedDescription)")
                clearUnusedFromKeychain()
            }
        }

        Log.info("No unused conversation found, creating new one")
        await createNewUnusedConversation(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
    }

    /// Consumes the unused conversation if available, or creates a new messaging service
    public func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        if isCreatingUnused {
            if let task = backgroundCreationTask {
                Log.info("Waiting for in-flight unused conversation creation to complete...")
                await task.value
            } else {
                Log.info("Unused conversation creation in progress without waitable task, creating fresh")
                let service = await createFreshMessagingService(
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )
                return (service: service, conversationId: nil)
            }
        }

        if let unusedService = unusedMessagingService,
           let unusedConversationId = getUnusedConversationFromKeychain() {
            if let result = await handleStaleUnusedConversation(
                conversationId: unusedConversationId,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            ) {
                return result
            }
            return await consumeFullUnusedConversation(
                service: unusedService,
                conversationId: unusedConversationId,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        }

        if let unusedService = unusedMessagingService {
            return await consumeInboxOnlyService(
                service: unusedService,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        }

        if let unusedInboxId = getUnusedInboxFromKeychain() {
            return await consumeKeychainInbox(
                inboxId: unusedInboxId,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        }

        Log.info("No unused inbox available, creating new one")
        let service = await createFreshMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
        return (service: service, conversationId: nil)
    }

    public func clearUnusedFromKeychain() {
        backgroundCreationTask?.cancel()
        backgroundCreationTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil

        if let service = unusedMessagingService {
            unusedMessagingService = nil
            cleanupTask = Task {
                await service.stopAndDelete()
            }
            Log.debug("Scheduled cleanup of in-memory unused messaging service")
        }

        do {
            try keychainService.delete(account: KeychainAccount.unusedConversation)
            Log.debug("Cleared unused conversation from keychain")
        } catch {
            Log.debug("Failed to clear unused conversation from keychain: \(error)")
        }

        do {
            try keychainService.delete(account: KeychainAccount.unusedInbox)
            Log.debug("Cleared unused inbox from keychain")
        } catch {
            Log.debug("Failed to clear unused inbox from keychain: \(error)")
        }
    }

    public func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        if isCreatingUnused {
            if let task = backgroundCreationTask {
                Log.info("Waiting for in-flight unused conversation creation to complete (inbox-only)...")
                await task.value
            } else {
                Log.info("Unused conversation creation in progress without waitable task, creating fresh (inbox-only)")
                return await createFreshMessagingService(
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )
            }
        }

        if let unusedService = unusedMessagingService {
            Log.info("Consuming cached inbox only, discarding pre-created conversation")
            unusedMessagingService = nil

            if let unusedConversationId = getUnusedConversationFromKeychain() {
                await cleanupOrphanedConversation(
                    conversationId: unusedConversationId,
                    databaseWriter: databaseWriter
                )
            }

            clearUnusedFromKeychain()

            do {
                let result = try await unusedService.inboxStateManager.waitForInboxReadyResult()
                let inboxId = result.client.inboxId
                let identity = try await identityStore.identity(for: inboxId)
                let inboxWriter = InboxWriter(dbWriter: databaseWriter)
                try await inboxWriter.save(inboxId: inboxId, clientId: identity.clientId)
                Log.info("Saved consumed inbox-only: \(inboxId)")
            } catch {
                Log.error("Failed to save consumed inbox-only: \(error)")
            }

            scheduleBackgroundCreation(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )

            return unusedService
        }

        if let unusedInboxId = getUnusedInboxFromKeychain() {
            Log.info("Consuming keychain inbox only: \(unusedInboxId)")

            if let unusedConversationId = getUnusedConversationFromKeychain() {
                await cleanupOrphanedConversation(
                    conversationId: unusedConversationId,
                    databaseWriter: databaseWriter
                )
            }

            clearUnusedFromKeychain()

            do {
                let identity = try await identityStore.identity(for: unusedInboxId)
                let authorizationOperation = AuthorizeInboxOperation.authorize(
                    inboxId: unusedInboxId,
                    clientId: identity.clientId,
                    identityStore: identityStore,
                    databaseReader: databaseReader,
                    databaseWriter: databaseWriter,
                    environment: environment,
                    startsStreamingServices: true,
                    platformProviders: platformProviders,
                    deviceRegistrationManager: deviceRegistrationManager,
                    apiClient: apiClient
                )

                let messagingService = MessagingService(
                    authorizationOperation: authorizationOperation,
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    identityStore: identityStore,
                    environment: environment
                )

                _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()
                let inboxWriter = InboxWriter(dbWriter: databaseWriter)
                try await inboxWriter.save(inboxId: unusedInboxId, clientId: identity.clientId)
                Log.info("Saved consumed keychain inbox-only: \(unusedInboxId)")

                scheduleBackgroundCreation(
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )

                return messagingService
            } catch {
                Log.error("Failed to authorize keychain inbox-only: \(error)")
            }
        }

        Log.info("No cached inbox available, creating fresh (inbox-only)")
        return await createFreshMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
    }

    public func isUnusedConversation(_ conversationId: String) -> Bool {
        return getUnusedConversationFromKeychain() == conversationId
    }

    public func isUnusedInbox(_ inboxId: String) -> Bool {
        return getUnusedInboxFromKeychain() == inboxId
    }

    public func hasUnusedConversation() -> Bool {
        return unusedMessagingService != nil || getUnusedConversationFromKeychain() != nil
    }
}

// MARK: - Consumption Helpers

extension UnusedConversationCache {
    func handleStaleUnusedConversation(
        conversationId: String,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?)? {
        let isActuallyUnused = await validateConversationIsUnused(
            conversationId: conversationId,
            databaseReader: databaseReader
        )
        guard !isActuallyUnused else {
            return nil
        }

        Log.warning("Conversation \(conversationId) in keychain is not marked as unused in DB, clearing and creating fresh")
        clearUnusedFromKeychain()
        let service = await createFreshMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
        return (service: service, conversationId: nil)
    }

    func consumeFullUnusedConversation(
        service: MessagingService,
        conversationId: String,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        Log.info("Using pre-created unused conversation: \(conversationId)")

        unusedMessagingService = nil

        do {
            let result = try await service.inboxStateManager.waitForInboxReadyResult()
            let inboxId = result.client.inboxId
            let identity = try await identityStore.identity(for: inboxId)
            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: inboxId, clientId: identity.clientId)

            try await markConversationAsUsed(
                conversationId: conversationId,
                databaseWriter: databaseWriter
            )

            clearUnusedFromKeychain()
            Log.info("Consumed unused conversation: \(conversationId)")
        } catch {
            Log.error("Failed to finalize consumed conversation, keeping keychain state for retry: \(error)")
        }

        scheduleBackgroundCreation(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )

        return (service: service, conversationId: conversationId)
    }

    func consumeInboxOnlyService(
        service: MessagingService,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        Log.info("Using pre-created unused inbox (no conversation)")

        unusedMessagingService = nil
        clearUnusedFromKeychain()

        do {
            let result = try await service.inboxStateManager.waitForInboxReadyResult()
            let inboxId = result.client.inboxId
            let identity = try await identityStore.identity(for: inboxId)
            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: inboxId, clientId: identity.clientId)
            Log.info("Saved consumed unused inbox: \(inboxId)")
        } catch {
            Log.error("Failed to save consumed inbox: \(error)")
        }

        scheduleBackgroundCreation(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )

        return (service: service, conversationId: nil)
    }

    func consumeKeychainInbox(
        inboxId: String,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        let unusedConversationId = getUnusedConversationFromKeychain()
        Log.info("Using unused inbox from keychain: \(inboxId), conversation: \(unusedConversationId ?? "none")")

        if let conversationId = unusedConversationId {
            if let result = await handleStaleUnusedConversation(
                conversationId: conversationId,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            ) {
                return result
            }
        }

        clearUnusedFromKeychain()

        do {
            let identity = try await identityStore.identity(for: inboxId)
            let authorizationOperation = AuthorizeInboxOperation.authorize(
                inboxId: inboxId,
                clientId: identity.clientId,
                identityStore: identityStore,
                databaseReader: databaseReader,
                databaseWriter: databaseWriter,
                environment: environment,
                startsStreamingServices: true,
                platformProviders: platformProviders,
                deviceRegistrationManager: deviceRegistrationManager,
                apiClient: apiClient
            )

            let messagingService = MessagingService(
                authorizationOperation: authorizationOperation,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                identityStore: identityStore,
                environment: environment
            )

            _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()
            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: inboxId, clientId: identity.clientId)
            Log.info("Saved consumed keychain inbox: \(inboxId)")

            if let conversationId = unusedConversationId {
                try await markConversationAsUsed(
                    conversationId: conversationId,
                    databaseWriter: databaseWriter
                )
            }

            scheduleBackgroundCreation(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )

            return (service: messagingService, conversationId: unusedConversationId)
        } catch {
            Log.error("Failed to look up identity for unused inbox: \(error)")
        }

        let service = await createFreshMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
        return (service: service, conversationId: nil)
    }
}

// MARK: - Validation & Lifecycle Helpers

extension UnusedConversationCache {
    func validateUnusedConversationExists(
        conversationId: String,
        databaseReader: any DatabaseReader
    ) async -> Bool {
        do {
            let exists = try await databaseReader.read { db in
                try DBConversation.fetchOne(db, key: conversationId) != nil
            }
            return exists
        } catch {
            Log.error("Failed to validate unused conversation exists: \(error)")
            return false
        }
    }

    func validateConversationIsUnused(
        conversationId: String,
        databaseReader: any DatabaseReader
    ) async -> Bool {
        do {
            let isUnused = try await databaseReader.read { db in
                try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .fetchOne(db)?
                    .isUnused ?? false
            }
            return isUnused
        } catch {
            Log.error("Failed to validate conversation is unused: \(error)")
            return false
        }
    }

    func markConversationAsUsed(
        conversationId: String,
        databaseWriter: any DatabaseWriter
    ) async throws {
        let now = Date()
        let changesCount = try await databaseWriter.write { db -> Int in
            try db.execute(
                sql: "UPDATE conversation SET isUnused = ?, createdAt = ? WHERE id = ?",
                arguments: [false, now, conversationId]
            )
            return db.changesCount
        }
        if changesCount == 0 {
            Log.warning("markConversationAsUsed: no conversation found with id \(conversationId)")
        } else {
            Log.info("Marked conversation as used: \(conversationId)")
        }
    }

    func cleanupOrphanedConversation(
        conversationId: String,
        databaseWriter: any DatabaseWriter
    ) async {
        do {
            try await databaseWriter.write { db in
                try db.execute(
                    sql: "DELETE FROM conversation WHERE id = ? AND isUnused = ?",
                    arguments: [conversationId, true]
                )
            }
            Log.info("Cleaned up orphaned unused conversation: \(conversationId)")
        } catch {
            Log.error("Failed to clean up orphaned conversation: \(error)")
        }
    }

    func createFreshMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> MessagingService {
        scheduleBackgroundCreation(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )

        let authorizationOperation = AuthorizeInboxOperation.register(
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient
        )

        return MessagingService(
            authorizationOperation: authorizationOperation,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment
        )
    }

    func scheduleBackgroundCreation(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) {
        backgroundCreationTask?.cancel()
        backgroundCreationTask = Task(priority: .background) { [weak self, weak databaseWriter, weak databaseReader] in
            guard let self,
                  let databaseWriter,
                  let databaseReader else { return }
            await createNewUnusedConversation(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        }
    }

    func authorizeUnusedInbox(
        inboxId: String,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async throws {
        var identity: KeychainIdentity
        do {
            identity = try await identityStore.identity(for: inboxId)
        } catch {
            clearUnusedFromKeychain()
            throw error
        }

        let authorizationOperation = AuthorizeInboxOperation.authorize(
            inboxId: inboxId,
            clientId: identity.clientId,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            startsStreamingServices: true,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient
        )

        let messagingService = MessagingService(
            authorizationOperation: authorizationOperation,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment
        )

        do {
            _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()
            unusedMessagingService = messagingService
            Log.info("Successfully authorized unused inbox: \(inboxId)")
        } catch {
            Log.error("Failed to authorize unused inbox: \(error)")
            clearUnusedFromKeychain()
            await messagingService.stopAndDelete()
            throw error
        }
    }

    func createNewUnusedConversation(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        guard !isCreatingUnused else {
            Log.debug("Already creating an unused conversation, skipping...")
            return
        }

        guard unusedMessagingService == nil else {
            Log.debug("Unused messaging service exists, skipping...")
            return
        }

        guard getUnusedInboxFromKeychain() == nil else {
            Log.debug("Unused inbox exists in keychain, skipping...")
            return
        }

        isCreatingUnused = true
        defer { isCreatingUnused = false }

        Log.info("Creating new unused conversation in background")

        let authorizationOperation = AuthorizeInboxOperation.register(
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient
        )

        let tempMessagingService = MessagingService(
            authorizationOperation: authorizationOperation,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment
        )

        do {
            let result = try await tempMessagingService.inboxStateManager.waitForInboxReadyResult()
            let inboxId = result.client.inboxId

            saveUnusedInboxToKeychain(inboxId)
            unusedMessagingService = tempMessagingService

            Log.info("Successfully created unused inbox: \(inboxId)")

            await createConversationForExistingInbox(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        } catch {
            Log.error("Failed to create unused inbox: \(error)")
            await tempMessagingService.stopAndDelete()
        }
    }

    func createConversationForExistingInbox(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        guard let messagingService = unusedMessagingService else {
            Log.warning("No messaging service available for conversation creation")
            return
        }

        do {
            let inboxReady = try await messagingService.inboxStateManager.waitForInboxReadyResult()
            let client = inboxReady.client
            let inboxId = client.inboxId

            // nonisolated(unsafe) is used because XMTP types are not Sendable. This is safe
            // here because prepareConversation() is a one-shot operation, not a long-running
            // stream that could overlap with other XMTP operations.
            nonisolated(unsafe) let optimisticConversation = try client.prepareConversation()
            try await optimisticConversation.publish()

            let conversationId = optimisticConversation.id
            Log.info("Created unused conversation: \(conversationId)")

            let identity = try await identityStore.identity(for: inboxId)
            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: inboxId, clientId: identity.clientId)

            guard let group = optimisticConversation as? XMTPiOS.Group else {
                throw UnusedConversationCacheError.invalidConversationType
            }
            try await saveUnusedConversationToDatabase(
                conversation: group,
                inboxId: inboxId,
                clientId: identity.clientId,
                databaseWriter: databaseWriter
            )

            let inviteWriter = InviteWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter
            )
            let dbConversation = try await databaseWriter.read { db in
                try DBConversation.fetchOne(db, key: conversationId)
            }
            if let dbConversation {
                _ = try await inviteWriter.generate(
                    for: dbConversation,
                    expiresAt: nil,
                    expiresAfterUse: false
                )
                Log.info("Generated invite for unused conversation: \(conversationId)")
            }

            saveUnusedConversationToKeychain(conversationId)
            Log.info("Successfully created unused conversation with invite: \(conversationId)")
        } catch {
            Log.error("Failed to create conversation for unused inbox (keeping inbox): \(error)")
        }
    }
}

// MARK: - Database Helpers

extension UnusedConversationCache {
    private func saveUnusedConversationToDatabase(
        conversation: XMTPConversation,
        inboxId: String,
        clientId: String,
        databaseWriter: any DatabaseWriter
    ) async throws {
        let conversationId = conversation.id
        let creatorInboxId = try await conversation.creatorInboxId()
        let inviteTag = try conversation.inviteTag

        try await databaseWriter.write { db in
            let member = DBMember(inboxId: inboxId)
            try member.save(db, onConflict: .ignore)

            let dbConversation = DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: conversationId,
                inviteTag: inviteTag,
                creatorId: creatorInboxId,
                kind: .group,
                consent: .allowed,
                createdAt: conversation.createdAt,
                name: nil,
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                imageLastRenewed: nil,
                isUnused: true
            )
            try dbConversation.save(db)

            let conversationMember = DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date()
            )
            try conversationMember.save(db)

            let memberProfile = DBMemberProfile(
                conversationId: conversationId,
                inboxId: inboxId,
                name: nil,
                avatar: nil
            )
            try memberProfile.save(db, onConflict: .ignore)

            let localState = ConversationLocalState(
                conversationId: conversationId,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date.distantPast,
                isMuted: false,
                pinnedOrder: nil
            )
            try localState.save(db)

            Log.info("Saved unused conversation to database: \(conversationId)")
        }
    }
}

// MARK: - Keychain Helpers

extension UnusedConversationCache {
    private func getUnusedInboxFromKeychain() -> String? {
        try? keychainService.retrieveString(account: KeychainAccount.unusedInbox)
    }

    private func getUnusedConversationFromKeychain() -> String? {
        try? keychainService.retrieveString(account: KeychainAccount.unusedConversation)
    }

    private func saveUnusedInboxToKeychain(_ inboxId: String) {
        do {
            try keychainService.saveString(inboxId, account: KeychainAccount.unusedInbox)
            Log.info("Saved unused inbox to keychain: \(inboxId)")
        } catch { Log.error("Failed to save unused inbox to keychain: \(error)") }
    }

    private func saveUnusedConversationToKeychain(_ conversationId: String) {
        do {
            try keychainService.saveString(conversationId, account: KeychainAccount.unusedConversation)
            Log.info("Saved unused conversation to keychain: \(conversationId)")
        } catch { Log.error("Failed to save unused conversation to keychain: \(error)") }
    }
}

// MARK: - Type Aliases

private typealias XMTPConversation = XMTPiOS.Group
