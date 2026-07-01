@testable import ConvosCore
import Foundation
import Testing

private struct RecordedSend: Sendable {
    let name: String?
    let avatarURL: String?
    let conversationId: String
}

/// Test double for the XMTP/upload seam. Records uploads and sends, and can be
/// configured to fail a number of upload/send attempts before succeeding.
private actor FakeProfilePublishSession: ProfilePublishSession {
    nonisolated let inboxId: String
    private let conversations: [String]
    private let imageKeys: [String: Data]
    private var uploadFailuresRemaining: Int
    private var sendFailuresRemaining: Int
    private(set) var uploadAttempts: Int = 0
    private(set) var uploads: [String] = []
    private(set) var sends: [RecordedSend] = []

    init(
        inboxId: String,
        conversations: [String],
        imageKeys: [String: Data],
        uploadFailures: Int = 0,
        sendFailures: Int = 0
    ) {
        self.inboxId = inboxId
        self.conversations = conversations
        self.imageKeys = imageKeys
        self.uploadFailuresRemaining = uploadFailures
        self.sendFailuresRemaining = sendFailures
    }

    func conversationIds() -> [String] { conversations }

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

    func sendProfileUpdate(name: String?, avatar: PublishedAvatar?, conversationId: String) throws {
        if sendFailuresRemaining > 0 {
            sendFailuresRemaining -= 1
            throw FakeSessionError.send
        }
        sends.append(RecordedSend(name: name, avatarURL: avatar?.url, conversationId: conversationId))
    }
}

private enum FakeSessionError: Error {
    case upload
    case send
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

    private func makePublisher(
        publishStore: any ProfilePublishStoreProtocol,
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        clock: TestClock
    ) -> ProfilePublisher {
        ProfilePublisher(
            publishStore: publishStore,
            profileStore: profileStore,
            selfProfileStore: selfProfileStore,
            selfInboxId: "me",
            now: { clock.current },
            backoff: PublishBackoff(base: 1, cap: 5, jitterFraction: 0)
        )
    }

    @Test("publish enqueues, encrypts/uploads/sends per conversation, and writes local slots")
    func publishAvatar() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let profileStore = InMemoryProfileStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: profileStore, selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", conversations: ["c1", "c2"], imageKeys: ["c1": key, "c2": key])
        await publisher.attach(session: session)

        try await publisher.publish(avatarBytes: Data([1, 2, 3]), priorityConversationId: nil)

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

    @Test("priority conversation is published first")
    func priorityFirst() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", conversations: ["c1", "c2"], imageKeys: ["c1": key, "c2": key])
        await publisher.attach(session: session)

        try await publisher.publish(avatarBytes: Data([1]), priorityConversationId: "c2")

        let sends = await session.sends
        #expect(sends.first?.conversationId == "c2")
    }

    @Test("a failed upload is retried with backoff and eventually succeeds")
    func retriesFailedUpload() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let publisher = makePublisher(publishStore: publishStore, profileStore: InMemoryProfileStore(), selfProfileStore: InMemorySelfProfileStore(), clock: clock)
        let session = FakeProfilePublishSession(inboxId: "me", conversations: ["c1"], imageKeys: ["c1": key], uploadFailures: 1)
        await publisher.attach(session: session)

        try await publisher.publish(avatarBytes: Data([1]), priorityConversationId: nil)
        let sendsAfterFailure = await session.sends
        #expect(sendsAfterFailure.isEmpty)
        let attemptsAfterFailure = await session.uploadAttempts
        #expect(attemptsAfterFailure == 1)

        clock.advance(by: 2)
        await publisher.drainReadyJobs()

        let attempts = await session.uploadAttempts
        #expect(attempts == 2)
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
        let session = FakeProfilePublishSession(inboxId: "me", conversations: ["c1"], imageKeys: [:])
        await publisher.attach(session: session)

        try await publisher.publish(avatarBytes: Data([1]), priorityConversationId: nil)

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
        let session = FakeProfilePublishSession(inboxId: "me", conversations: ["c1"], imageKeys: ["c1": key])

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
        let session = FakeProfilePublishSession(inboxId: "me", conversations: ["c1"], imageKeys: ["c1": key])
        await publisher.attach(session: session)

        try await publisher.publish(avatarBytes: nil, priorityConversationId: nil)

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
        let session = FakeProfilePublishSession(inboxId: "me", conversations: ["c1"], imageKeys: ["c1": key])

        await publisher.attach(session: session)

        let sends = await session.sends
        #expect(sends.count == 1)
        let remaining = try await publishStore.activeJobs()
        #expect(remaining.isEmpty)
    }
}
