@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the single-inbox lock-guarded service cache in
/// `SessionManager.loadOrCreateService`. The tests don't await the spawned
/// `AuthorizeInboxOperation` completion because the invariant we care about
/// — "every accessor returns the same `MessagingService` instance" — holds
/// the moment the builder runs under the lock, regardless of whether the
/// underlying XMTP client build succeeds. Keeps the suite Docker-free.
@Suite("SessionManager service caching")
struct SessionManagerServiceCachingTests {
    @Test("Sync and async accessors return the same cached instance")
    func syncAndAsyncReturnSameInstance() throws {
        let session = makeSession()

        let first = identity(of: session.messagingService())
        let second = identity(of: session.messagingServiceSync())

        #expect(first == second)
    }

    @Test("Repeated calls hit the cache — no rebuild")
    func repeatedCallsHitCache() throws {
        let session = makeSession()

        let first = identity(of: session.messagingService())
        let second = identity(of: session.messagingService())
        let third = identity(of: session.messagingService())

        #expect(first == second)
        #expect(second == third)
    }

    @Test("Concurrent callers converge on a single instance")
    func concurrentCallersConverge() async throws {
        let session = makeSession()

        async let a = identity(of: session.messagingService())
        async let b = identity(of: session.messagingService())
        async let c = identity(of: session.messagingService())
        async let d = identity(of: session.messagingService())

        let ids = await (a, b, c, d)
        #expect(ids.0 == ids.1)
        #expect(ids.0 == ids.2)
        #expect(ids.0 == ids.3)
    }

    @Test("Pre-seeded keychain identity is preserved, not overwritten")
    func preSeededIdentityPreserved() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(
            inboxId: "seeded-inbox",
            clientId: "seeded-client",
            keys: keys
        )

        let session = makeSession(identityStore: identityStore)
        _ = session.messagingService()

        // The authorize branch read the identity without mutating it; the
        // register branch would have generated new keys + saved over them.
        let after = try await identityStore.load()
        #expect(after?.inboxId == "seeded-inbox")
        #expect(after?.clientId == "seeded-client")
    }

    // MARK: - Helpers

    private func makeSession(
        identityStore: MockKeychainIdentityStore = MockKeychainIdentityStore()
    ) -> SessionManager {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        return SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: identityStore,
            platformProviders: .mock
        )
    }

    /// Returns a stable identity for the object underlying an
    /// `AnyMessagingService`, suitable for equality assertions.
    /// The protocol extends `AnyObject` so `ObjectIdentifier` is well-defined.
    private func identity(of service: AnyMessagingService) -> ObjectIdentifier {
        ObjectIdentifier(service)
    }
}
