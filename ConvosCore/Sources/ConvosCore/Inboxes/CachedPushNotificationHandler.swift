import Combine
import Foundation
import GRDB

// MARK: - Errors

public enum NotificationProcessingError: Error {
    case timeout
    case invalidPayload
}

// MARK: - Global Actor

/// NSE-side push notification handler. Caches one `MessagingService` for the
/// authorized identity and verifies incoming push payloads against it. A
/// `clientId` mismatch indicates the payload was issued to a now-stale
/// identity (e.g. the user deleted their account between send and deliver),
/// so the handler drops it.
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

    /// The single `MessagingService` for the process's lifetime (or until it ages out).
    private var messagingService: MessagingService?
    private var lastAccessTime: Date?

    /// Maximum age before a cached service is torn down and re-created on the next
    /// notification. Protects against stale MLS state accumulating in a long-lived NSE
    /// process the system occasionally reuses for many back-to-back deliveries.
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

    /// Handles a push notification using the structured payload with timeout protection.
    public func handlePushNotification(
        payload: PushNotificationPayload,
        timeout: TimeInterval = 25
    ) async throws -> DecodedNotificationContent? {
        Log.debug("Processing push notification")

        cleanupIfStale()

        guard payload.isValid, let payloadClientId = payload.clientId else {
            Log.debug("Dropping notification without clientId (v1/legacy)")
            return nil
        }

        // Distinguish "no identity" (legitimate orphan — user deleted account)
        // from "transient keychain error" (e.g. iCloud Keychain not yet
        // available after a fresh restore). The previous `try?` collapsed both
        // into "unregister this clientId from the backend" — which permanently
        // breaks push delivery for the user until the main app re-registers
        // the installation. We only unregister when we are *certain* the
        // identity is gone (load returned `nil`, not threw).
        let identity: KeychainIdentity?
        do {
            identity = try await identityStore.load()
        } catch {
            Log.warning("Dropping notification: keychain error reading singleton: \(error). Not unregistering — assume transient.")
            return nil
        }

        guard let identity else {
            Log.warning("Dropping notification: no singleton identity in keychain (orphan clientId \(payloadClientId))")
            await unregisterOrphanedClient(clientId: payloadClientId, apiJWT: payload.apiJWT)
            return nil
        }

        guard identity.clientId == payloadClientId else {
            Log.warning("Dropping notification: payload clientId \(payloadClientId) does not match singleton \(identity.clientId)")
            await unregisterOrphanedClient(clientId: payloadClientId, apiJWT: payload.apiJWT)
            return nil
        }

        Log.debug("Matched payload clientId \(payloadClientId) to singleton inbox \(identity.inboxId)")

        return try await withTimeout(seconds: timeout, timeoutError: NotificationProcessingError.timeout) {
            let service = await self.getOrCreateMessagingService(
                inboxId: identity.inboxId,
                clientId: identity.clientId,
                overrideJWTToken: payload.apiJWT
            )
            return try await service.processPushNotification(payload: payload)
        }
    }

    /// Tears down the cached messaging service, if any. Useful for explicit cleanup
    /// between processes or in tests; the system normally tears the NSE process down
    /// before this matters.
    public func cleanup() {
        if let service = messagingService {
            service.stop()
        }
        messagingService = nil
        lastAccessTime = nil
    }

    // MARK: - Private

    private func cleanupIfStale() {
        guard let lastAccess = lastAccessTime,
              let service = messagingService,
              Date().timeIntervalSince(lastAccess) > maxServiceAge else {
            return
        }
        Log.debug("Cleaning up stale messaging service (age > \(Int(maxServiceAge))s)")
        service.stop()
        messagingService = nil
        lastAccessTime = nil
    }

    private func getOrCreateMessagingService(
        inboxId: String,
        clientId: String,
        overrideJWTToken: String?
    ) -> MessagingService {
        lastAccessTime = Date()

        if let existing = messagingService {
            Log.debug("Reusing existing messaging service for singleton inbox: \(inboxId)")
            return existing
        }

        Log.info("Creating new messaging service for singleton inbox: \(inboxId), with JWT: \(overrideJWTToken != nil)")
        let service = MessagingService.authorizedMessagingService(
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
        messagingService = service
        return service
    }

    private func unregisterOrphanedClient(clientId: String, apiJWT: String?) async {
        guard let apiJWT, !apiJWT.isEmpty else {
            Log.warning("No API JWT available to unregister orphaned clientId: \(clientId)")
            return
        }

        let apiClient = ConvosAPIClientFactory.client(environment: environment, overrideJWTToken: apiJWT)
        do {
            try await apiClient.unregisterInstallation(clientId: clientId)
            Log.debug("Unregistered orphaned clientId: \(clientId)")
        } catch {
            Log.error("Failed to unregister orphaned clientId \(clientId): \(error)")
        }
    }
}
