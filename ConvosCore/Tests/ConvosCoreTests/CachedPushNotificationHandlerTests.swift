@testable import ConvosCore
import Foundation
import os
import Testing

/// Unit coverage for `CachedPushNotificationHandler` cache invalidation
/// semantics. Uses a stub `PushNotificationServiceFactoryProtocol` so the
/// tests don't fire a real `AuthorizeInboxOperation` or an XMTP client.
@Suite("CachedPushNotificationHandler", .serialized)
struct CachedPushNotificationHandlerTests {
    @Test("Same identity across deliveries reuses the cached service")
    func cacheReusedOnIdentityMatch() async throws {
        let factory = StubServiceFactory()
        let handler = makeHandler(factory: factory)

        _ = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-A",
            clientId: "client-A",
            overrideJWTToken: nil
        )
        _ = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-A",
            clientId: "client-A",
            overrideJWTToken: nil
        )

        #expect(factory.madeCount == 1)
        #expect(factory.stopCountForLastService == 0)
    }

    @Test("Different identity invalidates and rebuilds")
    func cacheInvalidatedOnIdentityMismatch() async throws {
        let factory = StubServiceFactory()
        let handler = makeHandler(factory: factory)

        let first = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-A",
            clientId: "client-A",
            overrideJWTToken: nil
        )
        let second = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-B",
            clientId: "client-B",
            overrideJWTToken: nil
        )

        #expect(factory.madeCount == 2)
        #expect(factory.madeIdentities == [
            IdentityTag(inboxId: "inbox-A", clientId: "client-A"),
            IdentityTag(inboxId: "inbox-B", clientId: "client-B")
        ])
        #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
        // The first service was torn down before the second was built.
        #expect((first as! StubMessagingService).stopCount == 1)
    }

    @Test("Stale-by-age invalidates even on matching identity")
    func staleByAgeInvalidates() async throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_000_000))
        let factory = StubServiceFactory()
        let handler = makeHandler(factory: factory, now: clock.now)

        let first = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-A",
            clientId: "client-A",
            overrideJWTToken: nil
        )

        // Advance past the 15-minute stale-by-age threshold.
        clock.advance(by: 16 * 60)

        // Trigger `cleanupIfStale()` + rebuild.
        await handler._cleanupIfStaleForTesting()

        let second = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-A",
            clientId: "client-A",
            overrideJWTToken: nil
        )

        #expect(factory.madeCount == 2)
        #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
        #expect((first as! StubMessagingService).stopCount == 1)
    }

    @Test("Clientid-only mismatch still invalidates (A logs out, B logs in)")
    func clientIdMismatchInvalidates() async throws {
        // Same inboxId is unlikely in practice, but the invariant is
        // "either field differing forces a rebuild."
        let factory = StubServiceFactory()
        let handler = makeHandler(factory: factory)

        _ = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-shared",
            clientId: "client-old",
            overrideJWTToken: nil
        )
        _ = await handler._getOrCreateMessagingServiceForTesting(
            inboxId: "inbox-shared",
            clientId: "client-new",
            overrideJWTToken: nil
        )

        #expect(factory.madeCount == 2)
    }

    // MARK: - Helpers

    private func makeHandler(
        factory: any PushNotificationServiceFactoryProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> CachedPushNotificationHandler {
        CachedPushNotificationHandler._testInstance(
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            serviceFactory: factory,
            now: now
        )
    }
}

// MARK: - Test doubles

private struct IdentityTag: Equatable, Sendable {
    let inboxId: String
    let clientId: String
}

private final class StubMessagingService: PushNotificationProcessing, @unchecked Sendable {
    let tag: IdentityTag
    private let lock: OSAllocatedUnfairLock<Int> = .init(initialState: 0)

    var stopCount: Int { lock.withLock { $0 } }

    init(tag: IdentityTag) { self.tag = tag }

    func processPushNotification(payload: PushNotificationPayload) async throws -> DecodedNotificationContent? {
        nil
    }

    func stop() {
        lock.withLock { $0 += 1 }
    }
}

private final class StubServiceFactory: PushNotificationServiceFactoryProtocol, @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<State> = .init(initialState: State())

    private struct State {
        var made: [IdentityTag] = []
        var lastService: StubMessagingService?
    }

    var madeCount: Int { lock.withLock { $0.made.count } }
    var madeIdentities: [IdentityTag] { lock.withLock { $0.made } }
    var stopCountForLastService: Int {
        lock.withLock { $0.lastService?.stopCount ?? 0 }
    }

    func makeService(
        inboxId: String,
        clientId: String,
        overrideJWTToken: String?
    ) -> any PushNotificationProcessing {
        let tag = IdentityTag(inboxId: inboxId, clientId: clientId)
        let service = StubMessagingService(tag: tag)
        lock.withLock { state in
            state.made.append(tag)
            state.lastService = service
        }
        return service
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Date>

    init(start: Date) {
        lock = .init(initialState: start)
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var now: @Sendable () -> Date {
        { self.lock.withLock { $0 } }
    }
}
