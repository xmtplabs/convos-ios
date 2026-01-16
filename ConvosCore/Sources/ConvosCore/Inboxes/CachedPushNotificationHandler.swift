import Combine
import Foundation
import GRDB

// MARK: - Errors
public enum NotificationProcessingError: Error {
    case timeout
    case invalidPayload
}

// MARK: - Global Actor
@globalActor
public actor CachedPushNotificationHandler {
    public static var shared: CachedPushNotificationHandler {
        guard _shared != nil else {
            fatalError("CachedPushNotificationHandler.initialize() must be called before accessing shared")
        }
        // swiftlint:disable:next force_unwrapping
        return _shared!
    }
    nonisolated(unsafe) private static var _shared: CachedPushNotificationHandler?

    /// Initialize the shared instance with required dependencies
    /// - Parameters:
    ///   - databaseReader: Database reader instance
    ///   - databaseWriter: Database writer instance
    ///   - environment: App environment
    ///   - identityStore: Identity store instance
    ///   - platformProviders: Platform-specific providers
    public static func initialize(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        platformProviders: PlatformProviders
    ) {
        _shared = CachedPushNotificationHandler(
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders
        )
    }

    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let environment: AppEnvironment
    private let identityStore: any KeychainIdentityStoreProtocol
    private let platformProviders: PlatformProviders

    private var messagingServices: [String: MessagingService] = [:] // Keyed by inboxId

    // Track last access time for cleanup (keyed by inboxId)
    private var lastAccessTime: [String: Date] = [:]

    // Maximum age for cached services (15 minutes)
    private let maxServiceAge: TimeInterval = 900

    private init(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        platformProviders: PlatformProviders
    ) {
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.environment = environment
        self.identityStore = identityStore
        self.platformProviders = platformProviders
    }

    /// Handles a push notification using the structured payload with timeout protection
    /// - Parameters:
    ///   - payload: The push notification payload to process
    ///   - timeout: Maximum time to process (default: 25 seconds for NSE's 30 second limit)
    /// - Returns: Decoded notification content if successful
    public func handlePushNotification(
        payload: PushNotificationPayload,
        timeout: TimeInterval = 25
    ) async throws -> DecodedNotificationContent? {
        Log.info("Processing push notification")

        // Clean up old services before processing
        cleanupStaleServices()

        guard payload.isValid else {
            Log.info("Dropping notification without clientId (v1/legacy)")
            return nil
        }

        guard let clientId = payload.clientId else {
            Log.info("Dropping notification without clientId")
            return nil
        }

        Log.info("Processing v2 notification for clientId: \(clientId)")
        let inboxesRepository = InboxesRepository(databaseReader: databaseReader)
        guard let inbox = try? inboxesRepository.inbox(byClientId: clientId) else {
            Log.warning("No inbox found in database for clientId: \(clientId) - dropping notification")
            return nil
        }
        let inboxId = inbox.inboxId
        Log.info("Matched clientId \(clientId) to inboxId: \(inboxId)")

        Log.info("Processing for inbox: \(inboxId)")

        // Process with timeout
        return try await withTimeout(seconds: timeout, timeoutError: NotificationProcessingError.timeout) {
            let messagingService = await self.getOrCreateMessagingService(for: inboxId, clientId: clientId, overrideJWTToken: payload.apiJWT)
            return try await messagingService.processPushNotification(payload: payload)
        }
    }

    /// Cleans up all resources
    public func cleanup() {
        Log.info("Cleaning up \(messagingServices.count) messaging services")
        messagingServices.values.forEach { $0.stop() }
        messagingServices.removeAll()
        lastAccessTime.removeAll()
    }

    /// Cleans up stale services that haven't been used recently
    private func cleanupStaleServices() {
        let now = Date()
        var staleInboxIds: [String] = []

        for (inboxId, accessTime) in lastAccessTime where now.timeIntervalSince(accessTime) > maxServiceAge {
            staleInboxIds.append(inboxId)
        }

        if !staleInboxIds.isEmpty {
            Log.info("Cleaning up \(staleInboxIds.count) stale messaging services")
            for inboxId in staleInboxIds {
                let removedService = messagingServices.removeValue(forKey: inboxId)
                removedService?.stop()
                lastAccessTime.removeValue(forKey: inboxId)
            }
        }
    }

    // MARK: - Private Methods

    private func getOrCreateMessagingService(for inboxId: String, clientId: String, overrideJWTToken: String?) -> MessagingService {
        // Update access time
        lastAccessTime[inboxId] = Date()

        if let existing = messagingServices[inboxId] {
            Log.info("Reusing existing messaging service for inbox: \(inboxId)")
            return existing
        }

        Log
            .info(
                "Creating new messaging service for inbox: \(inboxId), clientId: \(clientId), with JWT: \(overrideJWTToken != nil)"
            )
        let messagingService = MessagingService.authorizedMessagingService(
            for: inboxId,
            clientId: clientId,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            startsStreamingServices: false,
            overrideJWTToken: overrideJWTToken,
            platformProviders: platformProviders
        )
        messagingServices[inboxId] = messagingService
        return messagingService
    }
}
