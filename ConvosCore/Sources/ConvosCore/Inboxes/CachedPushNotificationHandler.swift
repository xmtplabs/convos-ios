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
    /// `NSLock` rather than `OSAllocatedUnfairLock` because we both read and
    /// mutate `_shared` across its lifetime; the lock keeps the guard + load
    /// atomic so `shared` can't observe a torn intermediate state if some
    /// future call path tears down and re-initializes the NSE handler.
    private static let registrationLock: NSLock = NSLock()
    nonisolated(unsafe) private static var _shared: CachedPushNotificationHandler?

    public static var shared: CachedPushNotificationHandler {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard let instance = _shared else {
            fatalError("CachedPushNotificationHandler.initialize() must be called before accessing shared")
        }
        return instance
    }

    /// Initialize the shared instance with required dependencies. Safe to
    /// call multiple times from the same process — the first invocation
    /// wins so early `shared` readers never observe a reconfigured handler.
    public static func initialize(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        platformProviders: PlatformProviders
    ) {
        let factory = PushNotificationServiceFactory(
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders
        )
        initialize(
            environment: environment,
            identityStore: identityStore,
            serviceFactory: factory
        )
    }

    /// Test-facing initialize that takes a pre-built factory. Production
    /// goes through the wrapper above; tests substitute a stub factory
    /// to assert cache invalidation behavior without firing a real
    /// `AuthorizeInboxOperation`.
    static func initialize(
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        serviceFactory: any PushNotificationServiceFactoryProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard _shared == nil else { return }
        _shared = CachedPushNotificationHandler(
            environment: environment,
            identityStore: identityStore,
            serviceFactory: serviceFactory,
            now: now
        )
    }

    /// Test-only reset hook. Lets a test suite re-initialize between
    /// scenarios. Never called in production.
    static func _resetForTesting() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        if let existing = _shared {
            // Tear down any cached service from the prior test run.
            Task { await existing.cleanup() }
        }
        _shared = nil
    }

    /// Test-only constructor. Bypasses the singleton/lock machinery so
    /// each test gets a fresh handler isolated from global state.
    static func _testInstance(
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        serviceFactory: any PushNotificationServiceFactoryProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> CachedPushNotificationHandler {
        CachedPushNotificationHandler(
            environment: environment,
            identityStore: identityStore,
            serviceFactory: serviceFactory,
            now: now
        )
    }

    /// Test-only entry point into the cache-or-build path. Bypasses the
    /// payload validation + identity-mismatch unregister logic in
    /// `handlePushNotification` to focus on caching semantics.
    func _getOrCreateMessagingServiceForTesting(
        inboxId: String,
        clientId: String,
        overrideJWTToken: String?
    ) async -> any PushNotificationProcessing {
        await getOrCreateMessagingService(
            inboxId: inboxId,
            clientId: clientId,
            overrideJWTToken: overrideJWTToken
        )
    }

    /// Test-only entry point into the stale-by-age cleanup path.
    func _cleanupIfStaleForTesting() async {
        await cleanupIfStale()
    }

    private let environment: AppEnvironment
    private let identityStore: any KeychainIdentityStoreProtocol
    private let serviceFactory: any PushNotificationServiceFactoryProtocol

    /// The currently-cached service, tagged with the identity it was built for.
    /// Tagging lets us detect and invalidate the cache when the user signs out
    /// and signs in as someone else within the same long-lived NSE process —
    /// without it, a payload for B would be handed a service still bound to
    /// A's MLS state.
    private struct CachedService {
        let inboxId: String
        let clientId: String
        let service: any PushNotificationProcessing
        var lastAccessTime: Date
    }
    private var cached: CachedService?

    /// Maximum age (15 minutes) before a cached service is torn down and
    /// re-created on the next notification. Protects against stale MLS
    /// state accumulating in a long-lived NSE process the system
    /// occasionally reuses for many back-to-back deliveries.
    private let maxServiceAge: TimeInterval = 15 * 60

    /// Injection seam for tests — the wall clock ticks under normal operation.
    private let now: @Sendable () -> Date

    private init(
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        serviceFactory: any PushNotificationServiceFactoryProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.identityStore = identityStore
        self.serviceFactory = serviceFactory
        self.now = now
    }

    /// Handles a push notification using the structured payload with timeout protection.
    public func handlePushNotification(
        payload: PushNotificationPayload,
        timeout: TimeInterval = 25
    ) async throws -> DecodedNotificationContent? {
        Log.debug("Processing push notification")

        await cleanupIfStale()

        guard payload.isValid, let payloadClientId = payload.clientId else {
            Log.debug("Dropping notification without clientId (v1/legacy)")
            return nil
        }

        // Distinguish "no identity" (legitimate orphan — user deleted
        // account) from "transient keychain error" (e.g. iCloud Keychain
        // not yet available after a fresh restore). Only unregister the
        // clientId from the backend when we are *certain* the identity is
        // gone (load returned `nil`, not threw) — a transient error
        // silently permanently breaks push delivery otherwise.
        let identity: KeychainIdentity?
        do {
            identity = try await identityStore.load()
        } catch {
            Log.warning("Dropping notification: keychain load error: \(error). Not unregistering — assume transient.")
            return nil
        }

        guard let identity else {
            Log.warning("Dropping notification: no identity in keychain (orphan clientId \(payloadClientId))")
            await unregisterOrphanedClient(clientId: payloadClientId, apiJWT: payload.apiJWT)
            return nil
        }

        guard identity.clientId == payloadClientId else {
            Log.warning("Dropping notification: payload clientId \(payloadClientId) does not match stored clientId \(identity.clientId)")
            await unregisterOrphanedClient(clientId: payloadClientId, apiJWT: payload.apiJWT)
            return nil
        }

        Log.debug("Matched payload clientId \(payloadClientId) to inbox \(identity.inboxId)")

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
    /// before this matters. Async so stream teardown truly precedes return — see
    /// `PushNotificationProcessing.stop()` for why the protocol method is async.
    public func cleanup() async {
        if let cached {
            await cached.service.stop()
        }
        cached = nil
    }

    // MARK: - Private

    private func cleanupIfStale() async {
        guard let cached, now().timeIntervalSince(cached.lastAccessTime) > maxServiceAge else {
            return
        }
        Log.info("Cleaning up stale messaging service (age > \(Int(maxServiceAge))s)")
        await cached.service.stop()
        self.cached = nil
    }

    private func getOrCreateMessagingService(
        inboxId: String,
        clientId: String,
        overrideJWTToken: String?
    ) async -> any PushNotificationProcessing {
        if var existing = cached {
            if existing.inboxId == inboxId, existing.clientId == clientId {
                existing.lastAccessTime = now()
                cached = existing
                Log.debug("Reusing existing messaging service for inbox: \(inboxId)")
                return existing.service
            }
            // Identity swapped out from under us (user signed out and in as
            // someone else while this NSE process was still warm). Await the
            // teardown so streams and sync workers from the prior identity
            // drain before the new service's state-machine touches disk.
            Log.info("Identity rotated mid-process: tearing down cached service for \(existing.inboxId), building for \(inboxId)")
            await existing.service.stop()
            cached = nil
        }

        Log.info("Creating new messaging service for inbox: \(inboxId), with JWT: \(overrideJWTToken != nil)")
        let service = serviceFactory.makeService(
            inboxId: inboxId,
            clientId: clientId,
            overrideJWTToken: overrideJWTToken
        )
        cached = CachedService(
            inboxId: inboxId,
            clientId: clientId,
            service: service,
            lastAccessTime: now()
        )
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
