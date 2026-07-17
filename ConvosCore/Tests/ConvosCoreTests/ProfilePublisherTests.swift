@testable import ConvosCore
import Foundation
import Testing

private struct RecordedSend: Sendable {
    let name: String?
    let avatarURL: String?
    let metadata: ProfileMetadata?
    let conversationId: String
}

/// Test double for the XMTP/upload seam. Records uploads and sends, and can be
/// configured to fail a number of upload/send attempts before succeeding.
private actor FakeProfilePublishSession: ProfilePublishSession {
    nonisolated let inboxId: String
    private let imageKeys: [String: Data]
    private let missingConversations: Set<String>
    private var uploadFailuresRemaining: Int
    private var sendFailuresRemaining: Int
    private(set) var uploadAttempts: Int = 0
    private(set) var uploads: [String] = []
    private(set) var sends: [RecordedSend] = []

    init(
        inboxId: String,
        imageKeys: [String: Data],
        uploadFailures: Int = 0,
        sendFailures: Int = 0,
        missingConversations: Set<String> = []
    ) {
        self.inboxId = inboxId
        self.imageKeys = imageKeys
        self.uploadFailuresRemaining = uploadFailures
        self.sendFailuresRemaining = sendFailures
        self.missingConversations = missingConversations
    }

    func imageKey(conversationId: String) -> Data? { imageKeys[conversationId] }

    nonisolated func encrypt(_ plaintext: Data, groupKey: Data) -> EncryptedAvatarPayload {
        EncryptedAvatarPayload(ciphertext: plaintext, salt: Data(repeating: 9, count: 32), nonce: Data(repeating: 8, count: 12))
    }

    func upload(_ ciphertext: Data, filename: String) throws -> String {
        uploadAttempts += 1
        if uploadFailuresRemaining > 0 {
            uploadFailuresRemaining -= 1
            throw FakeSessionError.upload
        }
        uploads.append(filename)
        return "https://uploads/\(uploads.count)"
    }

    func sendProfileUpdate(name: String?, metadata: ProfileMetadata?, avatar: PublishedAvatar?, conversationId: String) throws {
        if missingConversations.contains(conversationId) {
            throw ProfilePublishSessionError.conversationNotFound(conversationId: conversationId)
        }
        if sendFailuresRemaining > 0 {
            sendFailuresRemaining -= 1
            throw FakeSessionError.send
        }
        sends.append(RecordedSend(name: name, avatarURL: avatar?.url, metadata: metadata, conversationId: conversationId))
    }
}

private enum FakeSessionError: Error {
    case upload
    case send
    case storeFetch
}

private actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// Wraps the in-memory store and, once `startFailing` is called, throws from
/// `nextReadyJob` - simulating a persistent row-read failure so tests can
/// assert the drain stops instead of hot-looping through the retry timer.
private actor FailingNextReadyPublishStore: ProfilePublishStoreProtocol {
    private let inner: InMemoryProfilePublishStore
    private var failing: Bool = false

    init(wrapping inner: InMemoryProfilePublishStore) {
        self.inner = inner
    }

    func startFailing() {
        failing = true
    }

    func nextReadyJob(now: Date) async throws -> DBProfilePublishJob? {
        if failing {
            throw FakeSessionError.storeFetch
        }
        return try await inner.nextReadyJob(now: now)
    }

    func setSource(_ source: DBProfileAvatarSource) async throws { try await inner.setSource(source) }
    func bumpAvatarSource(inboxId: String, plaintext: Data, updatedAt: Date) async throws -> Int64 {
        try await inner.bumpAvatarSource(inboxId: inboxId, plaintext: plaintext, updatedAt: updatedAt)
    }
    func source(inboxId: String) async throws -> DBProfileAvatarSource? { try await inner.source(inboxId: inboxId) }
    func clearSource(inboxId: String) async throws { try await inner.clearSource(inboxId: inboxId) }
    func enqueue(_ job: DBProfilePublishJob) async throws { try await inner.enqueue(job) }
    @discardableResult
    func enqueueNext(_ makeJob: @Sendable @escaping (Int64) -> DBProfilePublishJob) async throws -> DBProfilePublishJob {
        try await inner.enqueueNext(makeJob)
    }
    func update(_ job: DBProfilePublishJob) async throws { try await inner.update(job) }
    func claimJob(id: String, updatedAt: Date) async throws -> DBProfilePublishJob? {
        try await inner.claimJob(id: id, updatedAt: updatedAt)
    }
    func job(id: String) async throws -> DBProfilePublishJob? { try await inner.job(id: id) }
    func reclaimStalledJobs(excluding: Set<String>) async throws { try await inner.reclaimStalledJobs(excluding: excluding) }
    func activeJobs() async throws -> [DBProfilePublishJob] { try await inner.activeJobs() }
    func jobs(conversationId: String) async throws -> [DBProfilePublishJob] { try await inner.jobs(conversationId: conversationId) }
    func nextSeq() async throws -> Int64 { try await inner.nextSeq() }
    func earliestNextAttempt() async throws -> Date? { try await inner.earliestNextAttempt() }
    func deleteJob(id: String) async throws { try await inner.deleteJob(id: id) }
    func deleteJobs(conversationId: String) async throws { try await inner.deleteJobs(conversationId: conversationId) }
    func supersedeOlderThan(conversationId: String, seq: Int64) async throws {
        try await inner.supersedeOlderThan(conversationId: conversationId, seq: seq)
    }
    func deleteAll() async throws { try await inner.deleteAll() }
}

/// Monotonic clock the tests advance by hand for deterministic backoff retries.
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

@Suite("ProfilePublisher")
struct ProfilePublisherTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    /// The default sleeper parks forever so the retry timer never fires on its
    /// own mid-test; tests that exercise the timer inject a sleeper that
    /// advances the fake clock instead.
    private func makePublisher(
        publishStore: any ProfilePublishStoreProtocol,
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        clock: TestClock,
        conversationLocalStateWriter: any ConversationLocalStateWriterProtocol = MockConversationLocalStateWriter(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: .max) }
    ) -> ProfilePublisher {
        ProfilePublisher(
            publishStore: publishStore,
            profileStore: profileStore,
            selfProfileStore: selfProfileStore,
            conversationLocalStateWriter: conversationLocalStateWriter,
            selfInboxIdProvider: { "me" },
            now: { clock.current },
            backoff: PublishBackoff(base: 1, cap: 5, jitterFraction: 0),
            sleep: sleep
        )
    }

    /// Polls until `condition` holds or ~5s elapse; the publisher's background
    /// drain and retry timer run off the caller's execution path, so tests
    /// await their effects rather than their completion.
    private func waitFor(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(try await condition())
    }

    @Test("publish enqueues, encrypts/uploads/sends per conversation, and writes local slots")
    func publishAvatar() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let profileStore = InMemoryProfileStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: profileStore, selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key, "c2": key])
        await publisher.attach(session: session)

        try await publisher.updateAvatarSource(Data([1, 2, 3]))
        try await publisher.publishConversation("c1")
        try await publisher.publishConversation("c2")

        let sends = await session.sends
        #expect(sends.count == 2)
        #expect(Set(sends.map(\.conversationId)) == ["c1", "c2"])
        #expect(sends.allSatisfy { $0.avatarURL != nil })
        let uploadAttempts = await session.uploadAttempts
        #expect(uploadAttempts == 2)

        let slot = try await profileStore.avatar(inboxId: "me", conversationId: "c1")
        #expect(slot?.url != nil)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }

    @Test("a failed upload is retried with backoff and eventually succeeds")
    func retriesFailedUpload() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key], uploadFailures: 1)
        await publisher.attach(session: session)

        try await publisher.updateAvatarSource(Data([1]))
        try await publisher.publishConversation("c1")
        let sendsAfterFailure = await session.sends
        #expect(sendsAfterFailure.isEmpty)
        let attemptsAfterFailure = await session.uploadAttempts
        #expect(attemptsAfterFailure == 1)

        clock.advance(by: 2)
        // Drain in a poll: a single call can no-op against the `draining`
        // guard while the publish's own kicked background drain is mid-run.
        try await waitFor {
            await publisher.drainReadyJobs()
            return await session.uploadAttempts == 2
        }

        let sends = await session.sends
        #expect(sends.count == 1)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }

    @Test("a job for a missing conversation is dropped")
    func dropsMissingConversation() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: [:])
        await publisher.attach(session: session)

        try await publisher.updateAvatarSource(Data([1]))
        try await publisher.publishConversation("c1")

        let sends = await session.sends
        #expect(sends.isEmpty)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }

    @Test("a job pinned to a superseded source version is dropped without uploading")
    func dropsStaleSourceVersion() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        try await publishStore.setSource(DBProfileAvatarSource(inboxId: "me", plaintext: Data([9]), version: 2, updatedAt: clock.current))
        let seq = try await publishStore.nextSeq()
        try await publishStore.enqueue(DBProfilePublishJob(
            id: "j1", seq: seq, conversationId: "c1", sourceVersion: 1, hasAvatar: true,
            nextAttemptAt: clock.current, createdAt: clock.current, updatedAt: clock.current
        ))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key])

        await publisher.attach(session: session)

        let sends = await session.sends
        #expect(sends.isEmpty)
        let attempts = await session.uploadAttempts
        #expect(attempts == 0)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }

    @Test("a name-only publish re-sends the existing avatar rather than clearing it")
    func nameOnlyResendsAvatar() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let profileStore = InMemoryProfileStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        try await profileStore.saveAvatar(DBProfileAvatar(
            inboxId: "me", conversationId: "c1", url: "existing", salt: salt, nonce: nonce,
            encryptionKey: key, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 1)
        ))
        let publisher = makePublisher(publishStore: publishStore, profileStore: profileStore, selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key])
        await publisher.attach(session: session)

        try await publisher.publishConversation("c1")

        let sends = await session.sends
        #expect(sends.count == 1)
        #expect(sends.first?.avatarURL == "existing")
        let attempts = await session.uploadAttempts
        #expect(attempts == 0)
    }

    @Test("attach drains jobs left over from a previous run")
    func resumesLeftoverJobs() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let seq = try await publishStore.nextSeq()
        try await publishStore.enqueue(DBProfilePublishJob(
            id: "j1", seq: seq, conversationId: "c1", hasAvatar: false,
            nextAttemptAt: clock.current, createdAt: clock.current, updatedAt: clock.current
        ))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key])

        await publisher.attach(session: session)

        let sends = await session.sends
        #expect(sends.count == 1)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }

    @Test("a successful publish stamps publishedProfileUpdatedAt for the conversation")
    func stampsConversationOnSuccessfulPublish() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let selfProfileStore = InMemorySelfProfileStore()
        let updatedAt = Date(timeIntervalSince1970: 500)
        try await selfProfileStore.save(DBMyProfile(inboxId: "me", name: "Ziggy", updatedAt: updatedAt))
        let localStateWriter = MockConversationLocalStateWriter()
        let publisher = makePublisher(
            publishStore: publishStore, profileStore: InMemoryProfileStore(),
            selfProfileStore: selfProfileStore, clock: clock, conversationLocalStateWriter: localStateWriter
        )
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key])
        await publisher.attach(session: session)

        try await publisher.publishConversation("c1")

        let sends = await session.sends
        #expect(sends.count == 1)
        let stamped = localStateWriter.publishedProfileUpdatedAtStates["c1"] ?? nil
        #expect(stamped == updatedAt)
    }

    @Test("a job left uploading by an interrupted drain is reclaimed and processed")
    func reclaimsStalledUploadingJob() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        // Seed a job stuck in-flight, as if a prior drain died mid-upload.
        let seq = try await publishStore.nextSeq()
        try await publishStore.enqueue(DBProfilePublishJob(
            id: "stuck", seq: seq, conversationId: "c1", hasAvatar: false, state: .uploading,
            nextAttemptAt: clock.current, createdAt: clock.current, updatedAt: clock.current
        ))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key])

        await publisher.attach(session: session)

        let sends = await session.sends
        #expect(sends.count == 1)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }

    @Test("seedAvatarSourceIfAbsent seeds only when no source exists")
    func seedAvatarSourceIfAbsentIsIdempotent() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)

        try await publisher.seedAvatarSourceIfAbsent(Data([1, 2, 3]))
        let seeded = try await publishStore.source(inboxId: "me")
        #expect(seeded?.version == 1)
        #expect(seeded?.plaintext == Data([1, 2, 3]))

        // Second call must not overwrite an existing source.
        try await publisher.seedAvatarSourceIfAbsent(Data([9, 9]))
        let unchanged = try await publishStore.source(inboxId: "me")
        #expect(unchanged?.version == 1)
        #expect(unchanged?.plaintext == Data([1, 2, 3]))
    }

    @Test("queue sends carry the conversation's scoped metadata merged over the global map")
    func queueSendsMergeScopedMetadata() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let selfProfileStore = InMemorySelfProfileStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: selfProfileStore, clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key, "c2": key])
        await publisher.attach(session: session)

        // Global identity metadata plus scoped keys for c1 only; the scoped
        // "emoji" overrides the global value for c1 (scoped wins on conflict).
        try await selfProfileStore.save(DBMyProfile(
            inboxId: "me", name: "Me",
            metadata: ["emoji": .string("global"), "kind": .string("person")],
            updatedAt: clock.current
        ))
        try await selfProfileStore.saveScopedMetadata(
            ["connections": .string("grants-c1"), "emoji": .string("scoped")],
            inboxId: "me",
            conversationId: "c1",
            updatedAt: clock.current
        )

        try await publisher.publishConversation("c1")
        try await publisher.publishConversation("c2")

        let sends = await session.sends
        let sendC1 = try #require(sends.first { $0.conversationId == "c1" })
        let sendC2 = try #require(sends.first { $0.conversationId == "c2" })
        #expect(sendC1.metadata?["connections"] == .string("grants-c1"))
        #expect(sendC1.metadata?["emoji"] == .string("scoped"))
        #expect(sendC1.metadata?["kind"] == .string("person"))
        // Another conversation never receives c1's scoped keys.
        #expect(sendC2.metadata?["connections"] == nil)
        #expect(sendC2.metadata?["emoji"] == .string("global"))
    }

    @Test("publishScopedMetadata sends immediately, persists on success, and scopes per conversation")
    func scopedMetadataPublishesImmediately() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let selfProfileStore = InMemorySelfProfileStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: selfProfileStore, clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: [:])
        await publisher.attach(session: session)
        try await selfProfileStore.save(DBMyProfile(inboxId: "me", name: "Me", updatedAt: clock.current))

        try await publisher.publishScopedMetadata(["connections": .string("grants-a")], conversationId: "convo-a")
        try await publisher.publishScopedMetadata(["connections": .string("grants-b")], conversationId: "convo-b")

        // Both sends went out, each carrying only its own conversation's grants.
        let sends = await session.sends
        #expect(sends.count == 2)
        let sendA = try #require(sends.first { $0.conversationId == "convo-a" })
        let sendB = try #require(sends.first { $0.conversationId == "convo-b" })
        #expect(sendA.metadata?["connections"] == .string("grants-a"))
        #expect(sendB.metadata?["connections"] == .string("grants-b"))

        // Writing conversation B never clobbered conversation A's stored map -
        // the regression this table exists to prevent.
        let storedA = try await selfProfileStore.scopedMetadata(inboxId: "me", conversationId: "convo-a")
        let storedB = try await selfProfileStore.scopedMetadata(inboxId: "me", conversationId: "convo-b")
        #expect(storedA?["connections"] == .string("grants-a"))
        #expect(storedB?["connections"] == .string("grants-b"))
        // Nothing leaked into the global map.
        let global = try await selfProfileStore.load()
        #expect(global?.metadata == nil)
    }

    @Test("a failed scoped send throws and persists nothing")
    func scopedMetadataSendFailureLeavesNoTrace() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let selfProfileStore = InMemorySelfProfileStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: selfProfileStore, clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: [:], sendFailures: 1)
        await publisher.attach(session: session)

        await #expect(throws: (any Error).self) {
            try await publisher.publishScopedMetadata(["connections": .string("grants")], conversationId: "c1")
        }
        // The scoped map was not persisted, so no later lazy publish can
        // deliver a grant the caller declined to keep.
        let stored = try await selfProfileStore.scopedMetadata(inboxId: "me", conversationId: "c1")
        #expect(stored == nil)
    }

    @Test("publishScopedMetadata without a bound session throws")
    func scopedMetadataRequiresSession() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let selfProfileStore = InMemorySelfProfileStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: selfProfileStore, clock: clock)

        await #expect(throws: (any Error).self) {
            try await publisher.publishScopedMetadata(["connections": .string("grants")], conversationId: "c1")
        }
        let stored = try await selfProfileStore.scopedMetadata(inboxId: "me", conversationId: "c1")
        #expect(stored == nil)
    }

    @Test("the stamp is the enqueue-time profile updatedAt, so an edit after enqueue stays publishable")
    func stampsEnqueueTimeProfileUpdatedAt() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let selfProfileStore = InMemorySelfProfileStore()
        let localState = MockConversationLocalStateWriter()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(
            publishStore: publishStore,
            profileStore: InMemoryProfileStore(),
            selfProfileStore: selfProfileStore,
            clock: clock,
            conversationLocalStateWriter: localState
        )

        // Enqueue with the profile at t=1000 (no session bound, so the job
        // waits), then edit the profile before the job is processed.
        let enqueueTime = Date(timeIntervalSince1970: 1_000)
        let editTime = Date(timeIntervalSince1970: 2_000)
        try await selfProfileStore.save(DBMyProfile(inboxId: "me", name: "Me", updatedAt: enqueueTime))
        try await publisher.publishConversation("c1")
        try await selfProfileStore.save(DBMyProfile(inboxId: "me", name: "Me Edited", updatedAt: editTime))

        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: [:])
        await publisher.attach(session: session)

        // The send happened, but the stamp is the enqueue-time value: the
        // post-enqueue edit must leave the conversation stale (stamp < edit)
        // so the change-aware sync re-publishes it, instead of marking the
        // conversation current for content that reflected a decision made
        // before the edit.
        try await waitFor { await session.sends.count == 1 }
        #expect(localState.publishedProfileUpdatedAtStates["c1"] == enqueueTime)
    }

    @Test("a rescheduled job retries via the timer without any external trigger")
    func retryTimerFiresWithoutExternalTrigger() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(
            publishStore: publishStore,
            profileStore: InMemoryProfileStore(),
            selfProfileStore: InMemorySelfProfileStore(),
            clock: clock,
            // The timer's sleeper advances the fake clock past the backoff
            // deadline, standing in for real elapsed time.
            sleep: { delay in clock.advance(by: delay) }
        )
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: ["c1": key], uploadFailures: 1)
        await publisher.attach(session: session)

        try await publisher.updateAvatarSource(Data([1]))
        try await publisher.publishConversation("c1")

        // No manual drain and no clock manipulation here: the armed timer
        // must wake the queue and complete the retry on its own.
        try await waitFor {
            let attempts = await session.uploadAttempts
            let remaining = try await publishStore.activeJobs()
            return attempts == 2 && remaining.isEmpty
        }
        let sends = await session.sends
        #expect(sends.count == 1)
    }

    @Test("a message-send publish processes its own conversation first, never behind the queue")
    func inlinePublishDoesNotWaitBehindQueue() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: [:])
        await publisher.attach(session: session)

        // An older, ready job for another conversation sits at the head of
        // the queue (seeded directly so the attach drain doesn't consume it).
        try await publishStore.enqueue(DBProfilePublishJob(
            id: "queued-first", seq: 0, conversationId: "c-other",
            nextAttemptAt: clock.current, createdAt: clock.current, updatedAt: clock.current
        ))

        // The pre-send hook's publish returns with its own conversation
        // already delivered - it must not drain c-other first.
        try await publisher.publishConversation("c-mine")
        let firstSend = await session.sends.first
        #expect(firstSend?.conversationId == "c-mine")

        // The background drain still delivers the rest.
        try await waitFor { await session.sends.count == 2 }
        let all = await session.sends
        #expect(Set(all.map(\.conversationId)) == ["c-mine", "c-other"])
    }

    @Test("a store fetch error stops the drain without arming the timer (no hot loop)")
    func fetchErrorStopsDrainWithoutTimer() async throws {
        let inner = InMemoryProfilePublishStore()
        let store = FailingNextReadyPublishStore(wrapping: inner)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let sleepCount = Counter()
        let publisher = makePublisher(
            publishStore: store,
            profileStore: InMemoryProfileStore(),
            selfProfileStore: InMemorySelfProfileStore(),
            clock: clock,
            sleep: { _ in
                await sleepCount.increment()
                try await Task.sleep(nanoseconds: .max)
            }
        )
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: [:])
        await publisher.attach(session: session)

        // A ready pending job exists, but every fetch throws. With `try?`
        // semantics this looked like an empty queue, and the past-deadline
        // pending job armed a zero-delay timer that re-entered the failing
        // drain forever. The drain must stop and arm nothing.
        try await inner.enqueue(DBProfilePublishJob(
            id: "stuck", seq: 1, conversationId: "c1",
            nextAttemptAt: Date(timeIntervalSince1970: 0),
            createdAt: clock.current, updatedAt: clock.current
        ))
        await store.startFailing()
        await publisher.drainReadyJobs()

        let sends = await session.sends
        #expect(sends.isEmpty)
        let armed = await sleepCount.value
        #expect(armed == 0, "a failed drain pass must not arm the retry timer")
    }

    @Test("a job whose XMTP conversation is gone is dropped, not retried forever")
    func dropsJobForMissingXMTPConversation() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", imageKeys: [:], missingConversations: ["gone"])
        await publisher.attach(session: session)

        try await publisher.publishConversation("gone")

        let sends = await session.sends
        #expect(sends.isEmpty)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }
}
