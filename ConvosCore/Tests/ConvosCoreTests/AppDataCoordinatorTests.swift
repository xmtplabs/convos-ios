import ConvosAppData
@testable import ConvosCore
import Foundation
import Testing

/// A scripted network: per-conversation blob strings, injectable read/write
/// failures, and a hook that mutates the blob between the coordinator's write
/// and its verification re-read (a foreign commit racing ours).
private actor FakeAppDataSyncSession: AppDataSyncSession {
    private(set) var blobs: [String: String] = [:]
    private(set) var writeCount: Int = 0
    private(set) var readCount: Int = 0
    var missingConversations: Set<String> = []
    var readFailures: Int = 0
    var writeFailures: Int = 0
    /// Applied to the stored blob after each write commits, before the
    /// coordinator re-reads (simulates a raced foreign commit). One-shot.
    var postWriteMutation: (@Sendable (String?) -> String?)?

    func setBlob(_ blob: String?, conversationId: String) {
        blobs[conversationId] = blob
    }

    func setMetadata(_ metadata: ConversationCustomMetadata, conversationId: String) throws {
        blobs[conversationId] = try metadata.toCompactString()
    }

    func metadata(conversationId: String) throws -> ConversationCustomMetadata {
        try ConversationCustomMetadata.strictParseAppData(blobs[conversationId])
    }

    func setMissing(_ conversationId: String) {
        missingConversations.insert(conversationId)
    }

    func setReadFailures(_ count: Int) { readFailures = count }
    func setWriteFailures(_ count: Int) { writeFailures = count }
    func setPostWriteMutation(_ mutation: (@Sendable (String?) -> String?)?) {
        postWriteMutation = mutation
    }

    func readAppData(conversationId: String) async throws -> String? {
        if missingConversations.contains(conversationId) {
            throw AppDataSyncSessionError.conversationNotFound(conversationId: conversationId)
        }
        if readFailures > 0 {
            readFailures -= 1
            throw FakeSessionError.readFailed
        }
        readCount += 1
        return blobs[conversationId]
    }

    func writeAppData(conversationId: String, appData: String) async throws {
        if missingConversations.contains(conversationId) {
            throw AppDataSyncSessionError.conversationNotFound(conversationId: conversationId)
        }
        if writeFailures > 0 {
            writeFailures -= 1
            throw FakeSessionError.writeFailed
        }
        writeCount += 1
        blobs[conversationId] = appData
        if let mutation = postWriteMutation {
            postWriteMutation = nil
            blobs[conversationId] = mutation(blobs[conversationId])
        }
    }
}

private enum FakeSessionError: Error {
    case readFailed
    case writeFailed
}

/// Store decorator whose `nextReadyConversation` throws, to prove the drain
/// stops instead of hot-looping on a persistent store failure.
private actor FailingNextReadyStore: AppDataPendingChangeStoreProtocol {
    private let wrapped: InMemoryAppDataPendingChangeStore
    var failNextReady: Bool = false
    private(set) var nextReadyAttempts: Int = 0

    init(wrapping wrapped: InMemoryAppDataPendingChangeStore) {
        self.wrapped = wrapped
    }

    func setFailNextReady(_ fail: Bool) { failNextReady = fail }

    func enqueueNext(
        _ makeChange: @Sendable @escaping (Int64) -> DBAppDataPendingChange
    ) async throws -> (inserted: DBAppDataPendingChange, supersededIds: [String]) {
        try await wrapped.enqueueNext(makeChange)
    }

    func pendingChanges(conversationId: String) async throws -> [DBAppDataPendingChange] {
        try await wrapped.pendingChanges(conversationId: conversationId)
    }

    func nextReadyConversation(now: Date) async throws -> String? {
        nextReadyAttempts += 1
        if failNextReady { throw FakeStoreError.storeUnavailable }
        return try await wrapped.nextReadyConversation(now: now)
    }

    func conversationsWithPendingChanges() async throws -> [String] {
        try await wrapped.conversationsWithPendingChanges()
    }

    func reschedule(ids: [String], attemptCount: Int64, nextAttemptAt: Date, lastError: String?, updatedAt: Date) async throws {
        try await wrapped.reschedule(ids: ids, attemptCount: attemptCount, nextAttemptAt: nextAttemptAt, lastError: lastError, updatedAt: updatedAt)
    }

    func resetBackoff(conversationId: String, now: Date) async throws {
        try await wrapped.resetBackoff(conversationId: conversationId, now: now)
    }

    func delete(ids: [String]) async throws {
        try await wrapped.delete(ids: ids)
    }

    func deleteAll(conversationId: String) async throws {
        try await wrapped.deleteAll(conversationId: conversationId)
    }

    func earliestNextAttempt() async throws -> Date? {
        try await wrapped.earliestNextAttempt()
    }

    func rowExists(id: String) async throws -> Bool {
        try await wrapped.rowExists(id: id)
    }

    func deleteAll() async throws {
        try await wrapped.deleteAll()
    }
}

private enum FakeStoreError: Error {
    case storeUnavailable
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var current: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

@Suite("AppData coordinator")
struct AppDataCoordinatorTests {
    private let conversationId = "conv-1"

    private func makeCoordinator(
        store: any AppDataPendingChangeStoreProtocol = InMemoryAppDataPendingChangeStore(),
        clock: TestClock = TestClock(Date(timeIntervalSince1970: 1_000)),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: .max) }
    ) -> AppDataCoordinator {
        AppDataCoordinator(
            store: store,
            now: { clock.current },
            backoff: PublishBackoff(base: 1, cap: 5, jitterFraction: 0),
            sleep: sleep
        )
    }

    private func waitFor(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(try await condition())
    }

    @Test("Enqueue publishes and read-your-writes sees the change immediately")
    func enqueuePublishes() async throws {
        let session = FakeAppDataSyncSession()
        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)

        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .inviteTag) { metadata in
            metadata.ensureTag("abcDEF1234")
        }
        #expect(handle.localMerged.tag == "abcDEF1234")

        // Read-your-writes before the publish necessarily lands.
        let readBack = try await coordinator.currentAppData(conversationId: conversationId)
        #expect(readBack.tag == "abcDEF1234")

        try await handle.awaitPublished()
        let networkTag = try await session.metadata(conversationId: conversationId).tag
        #expect(networkTag == "abcDEF1234")
    }

    @Test("Enqueue without an attached session throws")
    func enqueueWithoutSession() async throws {
        let coordinator = makeCoordinator()
        await #expect(throws: AppDataCoordinatorError.self) {
            try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
                metadata.expiresAtUnix = 1
            }
        }
    }

    @Test("Multiple domains coalesce and all land")
    func multiDomainCoalesce() async throws {
        let session = FakeAppDataSyncSession()
        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)

        let tagHandle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .inviteTag) { metadata in
            metadata.ensureTag("abcDEF1234")
        }
        let emojiHandle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .emoji) { metadata in
            metadata.ensureEmoji("🦊")
        }
        let expiryHandle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 4_242
        }

        try await tagHandle.awaitPublished()
        try await emojiHandle.awaitPublished()
        try await expiryHandle.awaitPublished()

        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.tag == "abcDEF1234")
        #expect(network.emoji == "🦊")
        #expect(network.expiresAtUnix == 4_242)
    }

    @Test("Same-domain re-enqueue supersedes and transfers the waiter")
    func supersedeTransfersWaiter() async throws {
        let session = FakeAppDataSyncSession()
        // Block the first publish so the second enqueue supersedes it while
        // still pending. Whichever write fails leaves a backed-off row, so the
        // retry timer must be able to fire.
        await session.setWriteFailures(1)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let coordinator = makeCoordinator(clock: clock, sleep: { interval in
            clock.advance(by: interval + 0.1)
        })
        await coordinator.attach(session: session)

        let first = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 1
        }
        let second = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 2
        }

        // The first handle resolves via the superseding change's publish.
        try await first.awaitPublished()
        try await second.awaitPublished()

        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.expiresAtUnix == 2)
    }

    @Test("Self-echo: intent already on the network clears without writing")
    func selfEchoClearsWithoutWrite() async throws {
        let session = FakeAppDataSyncSession()
        var existing = ConversationCustomMetadata()
        existing.tag = "abcDEF1234"
        try await session.setMetadata(existing, conversationId: conversationId)

        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)

        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .inviteTag) { metadata in
            metadata.ensureTag("neverUsed0")
        }
        try await handle.awaitPublished()

        let writes = await session.writeCount
        #expect(writes == 0)
        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.tag == "abcDEF1234")
    }

    @Test("A raced foreign commit re-merges and converges")
    func foreignCommitConverges() async throws {
        let session = FakeAppDataSyncSession()
        // Between our write and the verification re-read, a peer overwrites
        // the whole blob with their own (keeping their emoji, dropping our
        // expiry).
        var peerBlob = ConversationCustomMetadata()
        peerBlob.emoji = "🐙"
        let peerEncoded = try peerBlob.toCompactString()
        await session.setPostWriteMutation { _ in peerEncoded }

        // The lost verification race backs the row off, so the retry timer
        // must fire for the re-publish to converge.
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let coordinator = makeCoordinator(clock: clock, sleep: { interval in
            clock.advance(by: interval + 0.1)
        })
        await coordinator.attach(session: session)

        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 9_999
        }
        try await handle.awaitPublished()

        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.expiresAtUnix == 9_999)
        // The peer's emoji rode the fresh blob through the retry.
        #expect(network.emoji == "🐙")
    }

    @Test("Corrupt network blob backs off and is never written over")
    func corruptBlobNeverClobbered() async throws {
        let session = FakeAppDataSyncSession()
        await session.setBlob("not-valid-base64!", conversationId: conversationId)

        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)

        // Enqueue must fail loudly: the current state is unreadable, so no
        // intent can be computed against it.
        await #expect(throws: (any Error).self) {
            try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
                metadata.expiresAtUnix = 1
            }
        }
        let writes = await session.writeCount
        #expect(writes == 0)
        let blob = await session.blobs[conversationId]
        #expect(blob == "not-valid-base64!")
    }

    @Test("Corrupt blob wedges pending rows until a commit signal after repair")
    func corruptBlobRecovery() async throws {
        let session = FakeAppDataSyncSession()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = InMemoryAppDataPendingChangeStore()
        let coordinator = makeCoordinator(store: store, clock: clock)
        await coordinator.attach(session: session)

        // Enqueue against a healthy (empty) blob; the first publish write
        // fails so the row survives, backed off, with nothing on the network.
        await session.setWriteFailures(1)
        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 77
        }
        try await waitFor {
            let rows = try await store.pendingChanges(conversationId: conversationId)
            return rows.first?.attemptCount == 1
        }

        // A corrupt blob keeps it wedged even when a commit signal arrives.
        // onAppDataCommitObserved resets the attempt counter to retry
        // immediately; the corrupt-read reschedule then records lastError and
        // backs off again without ever writing.
        await session.setBlob("not-valid-base64!", conversationId: conversationId)
        await coordinator.onAppDataCommitObserved(conversationId: conversationId)
        try await waitFor {
            let rows = try await store.pendingChanges(conversationId: conversationId)
            return rows.first?.lastError != nil && rows.first?.nextAttemptAt ?? Date.distantPast > Date(timeIntervalSince1970: 1_000)
        }
        let writesWhileCorrupt = await session.writeCount
        #expect(writesWhileCorrupt == 0)

        // The blob is repaired and a commit is observed: the row flushes.
        await session.setBlob(nil, conversationId: conversationId)
        await coordinator.onAppDataCommitObserved(conversationId: conversationId)
        try await handle.awaitPublished()
        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.expiresAtUnix == 77)
    }

    @Test("A gone conversation drops its rows and fails the waiter")
    func goneConversationDrops() async throws {
        let session = FakeAppDataSyncSession()
        let store = InMemoryAppDataPendingChangeStore()
        let coordinator = makeCoordinator(store: store)
        await coordinator.attach(session: session)

        // Enqueue succeeds, then the conversation disappears before publish.
        await session.setWriteFailures(1)
        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 5
        }
        await session.setMissing(conversationId)
        await coordinator.onAppDataCommitObserved(conversationId: conversationId)

        await #expect(throws: AppDataCoordinatorError.self) {
            try await handle.awaitPublished()
        }
        let rows = try await store.pendingChanges(conversationId: conversationId)
        #expect(rows.isEmpty)
    }

    @Test("The change closure cannot clear a non-empty invite tag")
    func tagClearGuard() async throws {
        let session = FakeAppDataSyncSession()
        var existing = ConversationCustomMetadata()
        existing.tag = "abcDEF1234"
        try await session.setMetadata(existing, conversationId: conversationId)

        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)

        await #expect(throws: AppDataCoordinatorError.self) {
            try await coordinator.enqueueChange(conversationId: conversationId, domain: .inviteTag) { metadata in
                metadata.tag = ""
            }
        }
    }

    @Test("An oversized merged blob is refused at enqueue")
    func byteLimitGuard() async throws {
        let session = FakeAppDataSyncSession()
        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)

        await #expect(throws: (any Error).self) {
            try await coordinator.enqueueChange(conversationId: conversationId, domain: .profile, scopeKey: "aa") { metadata in
                var profile = ConversationProfile()
                profile.inboxID = Data(repeating: 0xAA, count: 16)
                // Pseudo-random bytes don't compress below the 8 KiB cap.
                var random: [UInt8] = []
                var state: UInt64 = 0x9E37_79B9_7F4A_7C15
                for _ in 0..<(20 * 1_024) {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    random.append(UInt8(truncatingIfNeeded: state >> 33))
                }
                profile.image = Data(random).base64URLEncoded()
                metadata.profiles = [profile]
            }
        }
    }

    @Test("Restart flush: a second coordinator over the same store publishes leftovers")
    func restartFlush() async throws {
        let session = FakeAppDataSyncSession()
        let store = InMemoryAppDataPendingChangeStore()

        // First coordinator enqueues but its publish write fails; the process
        // "dies" (coordinator discarded) with the row durable.
        await session.setWriteFailures(1)
        let first = makeCoordinator(store: store)
        await first.attach(session: session)
        _ = try await first.enqueueChange(conversationId: conversationId, domain: .emoji) { metadata in
            metadata.ensureEmoji("🦊")
        }
        try await waitFor {
            let rows = try await store.pendingChanges(conversationId: conversationId)
            return rows.first?.attemptCount == 1
        }
        await first.detach()

        // Second coordinator attaches over the same store: backoff has not
        // expired, so nothing is ready until the clock advances; attach still
        // arms the retry timer. Use an immediate-fire sleep to let it drain.
        let clock = TestClock(Date(timeIntervalSince1970: 2_000))
        let second = makeCoordinator(store: store, clock: clock, sleep: { _ in })
        await second.attach(session: session)

        try await waitFor {
            let rows = try await store.pendingChanges(conversationId: conversationId)
            return rows.isEmpty
        }
        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.emoji == "🦊")
    }

    @Test("Authority fields always ride the fresh network blob")
    func authorityFieldsRideFresh() async throws {
        let session = FakeAppDataSyncSession()
        var existing = ConversationCustomMetadata()
        existing.spaceURL = "https://space.example/one"
        try await session.setMetadata(existing, conversationId: conversationId)

        // The server rotates the space URL (an authority field no updater
        // carries) once, during our first publish. Our emoji must still land
        // and the rotated URL must survive, so the retry timer must fire.
        var rotated = ConversationCustomMetadata()
        rotated.spaceURL = "https://space.example/two"
        let rotatedEncoded = try rotated.toCompactString()
        await session.setPostWriteMutation { _ in rotatedEncoded }

        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let coordinator = makeCoordinator(clock: clock, sleep: { interval in
            clock.advance(by: interval + 0.1)
        })
        await coordinator.attach(session: session)

        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .emoji) { metadata in
            metadata.ensureEmoji("🦊")
        }

        try await handle.awaitPublished()
        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.publishedSpaceURL == "https://space.example/two")
        #expect(network.emoji == "🦊")
    }

    @Test("A store failure stops the drain instead of hot-looping")
    func storeFailureStopsDrain() async throws {
        let session = FakeAppDataSyncSession()
        let inner = InMemoryAppDataPendingChangeStore()
        let store = FailingNextReadyStore(wrapping: inner)
        let coordinator = makeCoordinator(store: store)
        await coordinator.attach(session: session)

        await store.setFailNextReady(true)
        _ = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 3
        }

        // Give the drain a moment: it must stop after the failed fetch, not
        // spin. A hot loop would rack up hundreds of attempts here.
        try await Task.sleep(nanoseconds: 300_000_000)
        let attempts = await store.nextReadyAttempts
        #expect(attempts <= 4)

        // Recovery via the next external trigger.
        await store.setFailNextReady(false)
        await coordinator.onAppDataCommitObserved(conversationId: conversationId)
        try await waitFor {
            let rows = try await inner.pendingChanges(conversationId: conversationId)
            return rows.isEmpty
        }
    }

    @Test("awaitPublished after the change already landed returns immediately")
    func awaitAfterLanded() async throws {
        let session = FakeAppDataSyncSession()
        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)

        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .emoji) { metadata in
            metadata.ensureEmoji("🦊")
        }
        try await waitFor {
            let network = try await session.metadata(conversationId: self.conversationId)
            return network.conversationEmoji == "🦊"
        }
        // The row is long gone; both the original await and a repeat resolve.
        try await handle.awaitPublished()
        try await handle.awaitPublished()
    }

    @Test("The retry timer fires a backed-off publish without an external trigger")
    func retryTimerFires() async throws {
        let session = FakeAppDataSyncSession()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = InMemoryAppDataPendingChangeStore()
        // The injected sleeper advances the fake clock past the deadline.
        let coordinator = makeCoordinator(store: store, clock: clock, sleep: { interval in
            clock.advance(by: interval + 0.1)
        })
        await coordinator.attach(session: session)

        await session.setWriteFailures(1)
        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 11
        }

        try await handle.awaitPublished()
        let network = try await session.metadata(conversationId: conversationId)
        #expect(network.expiresAtUnix == 11)
    }

    @Test("awaitPublished(timeout:) gives up while the change stays durable")
    func awaitPublishedTimesOut() async throws {
        let session = FakeAppDataSyncSession()
        // Writes never succeed, so the change can only ever end via the timeout.
        await session.setWriteFailures(1_000)
        // The retry timer parks forever (it never sleeps for exactly the timeout
        // value), so the only sleep that returns is the awaitPublished timeout.
        let timeoutSeconds: TimeInterval = 999
        let coordinator = makeCoordinator(sleep: { seconds in
            guard seconds == timeoutSeconds else {
                try await Task.sleep(nanoseconds: .max)
                return
            }
        })
        await coordinator.attach(session: session)
        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 111
        }

        await #expect(throws: AppDataCoordinatorError.self) {
            try await handle.awaitPublished(timeout: timeoutSeconds)
        }

        // The abandoned wait leaves the durable intent intact - it still folds
        // into the local read and will publish once writes succeed.
        let folded = try await coordinator.currentAppData(conversationId: conversationId)
        #expect(folded.expiresAtUnix == 111)
        await coordinator.detach()
    }

    @Test("awaitPublished unparks when the awaiting task is cancelled")
    func awaitPublishedHonorsCancellation() async throws {
        let session = FakeAppDataSyncSession()
        await session.setWriteFailures(1_000)
        let coordinator = makeCoordinator()
        await coordinator.attach(session: session)
        let handle = try await coordinator.enqueueChange(conversationId: conversationId, domain: .expiry) { metadata in
            metadata.expiresAtUnix = 222
        }

        let waiter = Task { try await handle.awaitPublished() }
        // Let the waiter park before cancelling (the already-cancelled path is
        // covered too - both resolve with CancellationError).
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        await coordinator.detach()
    }
}
