import Foundation
import GRDB

// MARK: - UnusedInboxCacheProtocol

/// Protocol for managing pre-created unused inboxes for faster user onboarding
public protocol UnusedInboxCacheProtocol: Actor {
    /// Checks if an unused inbox is available and prepares one if needed
    func prepareUnusedInboxIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async

    /// Consumes the unused inbox if available, or creates a new one
    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol

    /// Clears the unused inbox from keychain
    func clearUnusedInboxFromKeychain()

    /// Checks if the given inbox ID is the unused inbox
    func isUnusedInbox(_ inboxId: String) -> Bool

    /// Checks if there is an unused inbox available
    func hasUnusedInbox() -> Bool
}

// MARK: - UnusedInboxCache

/// Manages pre-created unused inboxes for faster user onboarding
///
/// UnusedInboxCache implements an optimization pattern where XMTP inboxes are
/// pre-created and cached before users need them, reducing perceived latency
/// when creating or joining conversations. The cache:
/// - Pre-creates a single "unused" inbox in the background
/// - Stores only the inbox ID in keychain (not in database until consumed)
/// - Immediately provides the pre-created inbox when needed
/// - Automatically creates a new unused inbox after consumption
///
/// This allows the app to skip the XMTP client creation step when users
/// create/join their first conversation, making the UX feel instant.
public actor UnusedInboxCache: UnusedInboxCacheProtocol {
    // MARK: - Properties

    private let keychainService: any KeychainServiceProtocol
    private let identityStore: any KeychainIdentityStoreProtocol
    private let platformProviders: PlatformProviders
    private var unusedMessagingService: MessagingService?
    private var isCreatingUnusedInbox: Bool = false

    // MARK: - Initialization

    public init(
        keychainService: any KeychainServiceProtocol = KeychainService(),
        identityStore: any KeychainIdentityStoreProtocol,
        platformProviders: PlatformProviders
    ) {
        self.keychainService = keychainService
        self.identityStore = identityStore
        self.platformProviders = platformProviders
    }

    // MARK: - Public Methods

    /// Checks if an unused inbox is available and prepares one if needed
    public func prepareUnusedInboxIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        // Check if we already have an unused messaging service ready
        guard unusedMessagingService == nil else {
            Log.debug("Unused messaging service already exists")
            return
        }

        // Check if we have an unused inbox ID in keychain
        if let unusedInboxId = getUnusedInboxFromKeychain() {
            Log.info("Found unused inbox ID in keychain: \(unusedInboxId)")
            do {
                try await authorizeUnusedInbox(
                    inboxId: unusedInboxId,
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )
            } catch {
                Log.error("Failed authorizing unused inbox: \(error.localizedDescription)")
                await createNewUnusedInbox(
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )
            }
        } else {
            // No unused inbox exists, create a new one
            Log.info("No unused inbox found, creating new one")
            await createNewUnusedInbox(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        }
    }

    /// Consumes the unused inbox if available, or creates a new one
    public func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        // Check if we have a pre-created unused messaging service
        if let unusedService = unusedMessagingService {
            Log.info("Using pre-created unused messaging service")

            // Clear ALL references IMMEDIATELY (both service and keychain)
            // This must happen before any await points to prevent concurrent access
            unusedMessagingService = nil
            clearUnusedInboxFromKeychain()

            // Make sure the inbox is saved to the database
            do {
                let result = try await unusedService.inboxStateManager.waitForInboxReadyResult()
                let inboxId = result.client.inboxId
                let identity = try await identityStore.identity(for: inboxId)
                let inboxWriter = InboxWriter(dbWriter: databaseWriter)
                try await inboxWriter.save(inboxId: inboxId, clientId: identity.clientId)
                Log.info("Saved consumed unused inbox to database: \(inboxId)")
            } catch {
                Log.error("Failed to save consumed inbox to database: \(error)")
            }

            // Schedule creation of a new unused inbox for next time (after consumption completes)
            Task(priority: .background) { [weak self] in
                guard let self else { return }
                await createNewUnusedInbox(
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    environment: environment
                )
            }

            return unusedService
        }

        // Check for an unused inbox ID in keychain (fallback)
        if let unusedInboxId = getUnusedInboxFromKeychain() {
            Log.info("Using unused inbox ID from keychain: \(unusedInboxId)")

            // Clear keychain
            clearUnusedInboxFromKeychain()

            // Use the existing inbox with authorize
            // Note: The authorize flow in InboxStateMachine.handleAuthorize() will
            // automatically save this inbox to the database

            // Look up clientId from keychain
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
                    platformProviders: platformProviders
                )

                // Schedule creation of a new unused inbox for next time
                Task(priority: .background) { [weak self] in
                    guard let self else { return }
                    await createNewUnusedInbox(
                        databaseWriter: databaseWriter,
                        databaseReader: databaseReader,
                        environment: environment
                    )
                }

                return MessagingService(
                    authorizationOperation: authorizationOperation,
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    identityStore: identityStore,
                    environment: environment
                )
            } catch {
                Log.error("Failed to look up identity for unused inbox: \(error)")
                // Fall through to create new one
            }
        }

        // No unused inbox available, create a new one
        Log.info("No unused inbox available, creating new one")
        return await createFreshMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
    }

    public func clearUnusedInboxFromKeychain() {
        do {
            try keychainService.delete(account: KeychainAccount.unusedInbox)
            Log.debug("Cleared unused inbox from keychain")
        } catch {
            Log.debug("Failed to clear unused inbox from keychain: \(error)")
        }
    }

    /// Checks if the given inbox ID is the unused inbox
    public func isUnusedInbox(_ inboxId: String) -> Bool {
        return getUnusedInboxFromKeychain() == inboxId
    }

    /// Checks if there is an unused inbox available (for testing purposes)
    public func hasUnusedInbox() -> Bool {
        return unusedMessagingService != nil || getUnusedInboxFromKeychain() != nil
    }

    // MARK: - Private Methods

    /// Creates a fresh messaging service without using cached inboxes
    private func createFreshMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> MessagingService {
        // Schedule creation of an unused inbox for next time
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            await createNewUnusedInbox(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        }

        // Create and return a new messaging service
        let authorizationOperation = AuthorizeInboxOperation.register(
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            platformProviders: platformProviders
        )

        return MessagingService(
            authorizationOperation: authorizationOperation,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment
        )
    }

    private func authorizeUnusedInbox(
        inboxId: String,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async throws {
        // Look up clientId from keychain
        var identity: KeychainIdentity
        do {
            identity = try await identityStore.identity(for: inboxId)
        } catch {
            clearUnusedInboxFromKeychain()
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
            platformProviders: platformProviders
        )

        let messagingService = MessagingService(
            authorizationOperation: authorizationOperation,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment
        )

        do {
            // Wait for it to be ready
            _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()

            // Store it as the unused messaging service
            unusedMessagingService = messagingService

            Log.info("Successfully authorized unused inbox: \(inboxId)")
        } catch {
            Log.error("Failed to authorize unused inbox: \(error)")
            // Clear the invalid inbox ID from keychain
            clearUnusedInboxFromKeychain()
            // Clean up the messaging service
            await messagingService.stopAndDelete()

            throw error
        }
    }

    private func createNewUnusedInbox(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        guard !isCreatingUnusedInbox else {
            Log.debug("Already creating an unused inbox, skipping...")
            return
        }

        guard unusedMessagingService == nil else {
            Log.debug("Unused messaging service exists, skipping creating new unused inbox...")
            return
        }

        guard getUnusedInboxFromKeychain() == nil else {
            Log.debug("Unused inbox exists, skipping create...")
            return
        }

        isCreatingUnusedInbox = true
        defer { isCreatingUnusedInbox = false }

        Log.info("Creating new unused inbox in background")

        let authorizationOperation = AuthorizeInboxOperation.register(
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            platformProviders: platformProviders
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

            // Save the inbox ID to keychain
            saveUnusedInboxToKeychain(inboxId)

            // Store the messaging service instance
            unusedMessagingService = tempMessagingService

            Log.info("Successfully created unused inbox: \(inboxId)")
        } catch {
            Log.error("Failed to create unused inbox: \(error)")
            // Clean up on error
            await tempMessagingService.stopAndDelete()
        }
    }

    // MARK: - Keychain Helpers

    private func getUnusedInboxFromKeychain() -> String? {
        do {
            return try keychainService.retrieveString(account: KeychainAccount.unusedInbox)
        } catch {
            Log.debug("No unused inbox found in keychain: \(error)")
            return nil
        }
    }

    private func saveUnusedInboxToKeychain(_ inboxId: String) {
        do {
            try keychainService.saveString(
                inboxId,
                account: KeychainAccount.unusedInbox
            )
            Log.info("Saved unused inbox to keychain: \(inboxId)")
        } catch {
            Log.error("Failed to save unused inbox to keychain: \(error)")
        }
    }
}
