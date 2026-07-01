import Foundation

/// Capped exponential backoff with jitter for failed publish jobs.
struct PublishBackoff: Sendable {
    let base: TimeInterval
    let cap: TimeInterval
    let jitterFraction: Double

    static let `default`: PublishBackoff = .init(base: 1, cap: 300, jitterFraction: 0.25)

    func delay(forAttempt attempt: Int64) -> TimeInterval {
        let shift = Double(max(0, attempt - 1))
        let exponential = min(cap, base * pow(2, shift))
        let jitter = exponential * jitterFraction * Double.random(in: -1...1)
        return max(0, exponential + jitter)
    }
}

/// Drains the durable profile publish queue: for each conversation, encrypts the
/// current source avatar once (caching the ciphertext so a restart re-uploads
/// identical bytes), uploads it, sends a ProfileUpdate, and writes the local
/// avatar slot. Failures reschedule only that job with capped backoff so the
/// loop is never head-of-line blocked. XMTP and upload specifics live behind the
/// injected `ProfilePublishSession`.
///
/// Not wired into startup yet; the lifecycle PR attaches a session and triggers
/// drains on a wake timer. Within a process, drains are serialized.
actor ProfilePublisher {
    private let publishStore: any ProfilePublishStoreProtocol
    private let profileStore: any ProfileStoreProtocol
    private let selfProfileStore: any SelfProfileStoreProtocol
    private let selfInboxId: String
    private let now: @Sendable () -> Date
    private let backoff: PublishBackoff

    private var session: (any ProfilePublishSession)?
    private var draining: Bool = false

    init(
        publishStore: any ProfilePublishStoreProtocol,
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        selfInboxId: String,
        now: @escaping @Sendable () -> Date = { Date() },
        backoff: PublishBackoff = .default
    ) {
        self.publishStore = publishStore
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.selfInboxId = selfInboxId
        self.now = now
        self.backoff = backoff
    }

    func attach(session: any ProfilePublishSession) async {
        self.session = session
        await drainReadyJobs()
    }

    func detach() {
        session = nil
    }

    /// Records a new source avatar (when `avatarBytes` is provided) and enqueues
    /// a publish job per conversation, priority conversation first, then drains.
    /// A nil `avatarBytes` is a name/metadata-only publish that re-sends the
    /// existing avatar for each conversation rather than clearing it.
    func publish(avatarBytes: Data?, priorityConversationId: String?) async throws {
        let conversationIds = try await session?.conversationIds() ?? []
        var sourceVersion: Int64?
        var hasAvatar = false
        if let avatarBytes {
            let existing = try await publishStore.source(inboxId: selfInboxId)
            let version = (existing?.version ?? 0) + 1
            try await publishStore.setSource(
                DBProfileAvatarSource(inboxId: selfInboxId, plaintext: avatarBytes, version: version, updatedAt: now())
            )
            sourceVersion = version
            hasAvatar = true
        }
        for conversationId in ordered(conversationIds, priority: priorityConversationId) {
            try await enqueueJob(conversationId: conversationId, sourceVersion: sourceVersion, hasAvatar: hasAvatar)
        }
        await drainReadyJobs()
    }

    /// Seeds a single conversation with the current profile (e.g. a freshly
    /// created or joined group), then drains.
    func publishConversation(_ conversationId: String) async throws {
        let source = try await publishStore.source(inboxId: selfInboxId)
        try await enqueueJob(conversationId: conversationId, sourceVersion: source?.version, hasAvatar: source != nil)
        await drainReadyJobs()
    }

    func drainReadyJobs() async {
        guard !draining, let session else { return }
        draining = true
        defer { draining = false }
        while let job = try? await publishStore.nextReadyJob(now: now()) {
            await process(job, session: session)
        }
    }

    // MARK: - Enqueue

    private func enqueueJob(conversationId: String, sourceVersion: Int64?, hasAvatar: Bool) async throws {
        let seq = try await publishStore.nextSeq()
        let timestamp = now()
        let job = DBProfilePublishJob(
            id: UUID().uuidString,
            seq: seq,
            conversationId: conversationId,
            sourceVersion: sourceVersion,
            hasAvatar: hasAvatar,
            nextAttemptAt: timestamp,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try await publishStore.enqueue(job)
        // A newer publish for this conversation supersedes its older pending jobs.
        try await publishStore.supersedeOlderThan(conversationId: conversationId, seq: seq)
    }

    private func ordered(_ ids: [String], priority: String?) -> [String] {
        guard let priority, ids.contains(priority) else { return ids }
        return [priority] + ids.filter { $0 != priority }
    }

    // MARK: - Process

    private func process(_ job: DBProfilePublishJob, session: any ProfilePublishSession) async {
        do {
            if job.hasAvatar {
                try await processAvatarJob(job, session: session)
            } else {
                try await processNameOnlyJob(job, session: session)
            }
            try? await publishStore.deleteJob(id: job.id)
        } catch is PublishDropError {
            try? await publishStore.deleteJob(id: job.id)
        } catch {
            await reschedule(job, error: error)
        }
    }

    private func processAvatarJob(_ job: DBProfilePublishJob, session: any ProfilePublishSession) async throws {
        guard let version = job.sourceVersion,
              let source = try await publishStore.source(inboxId: selfInboxId),
              source.version == version else {
            throw PublishDropError.staleSource
        }
        guard let groupKey = try await session.imageKey(conversationId: job.conversationId) else {
            throw PublishDropError.conversationGone
        }

        var current = job
        if current.ciphertext == nil || current.groupKey != groupKey {
            let payload = try session.encrypt(source.plaintext, groupKey: groupKey)
            current.ciphertext = payload.ciphertext
            current.salt = payload.salt
            current.nonce = payload.nonce
            current.groupKey = groupKey
            current.filename = "ep-\(UUID().uuidString).enc"
            current.uploadedURL = nil
            current.updatedAt = now()
            try await publishStore.update(current)
        }

        let url: String
        if let uploaded = current.uploadedURL {
            url = uploaded
        } else {
            guard let ciphertext = current.ciphertext, let filename = current.filename else {
                throw PublishDropError.staleSource
            }
            url = try await session.upload(ciphertext, filename: filename)
            current.uploadedURL = url
            current.updatedAt = now()
            try await publishStore.update(current)
        }

        guard let salt = current.salt, let nonce = current.nonce, let key = current.groupKey else {
            throw PublishDropError.staleSource
        }
        let published = PublishedAvatar(url: url, salt: salt, nonce: nonce, key: key)
        let selfName = try await selfProfileStore.load()?.name
        try await session.sendProfileUpdate(name: selfName, avatar: published, conversationId: job.conversationId)
        let slot = DBProfileAvatar(
            inboxId: selfInboxId,
            conversationId: job.conversationId,
            url: url,
            salt: salt,
            nonce: nonce,
            encryptionKey: key,
            profileSource: .profileUpdate,
            updatedAt: now()
        )
        try await profileStore.saveAvatar(slot)
    }

    private func processNameOnlyJob(_ job: DBProfilePublishJob, session: any ProfilePublishSession) async throws {
        let existing = try await profileStore.avatar(inboxId: selfInboxId, conversationId: job.conversationId)
        let published = publishedAvatar(from: existing)
        let selfName = try await selfProfileStore.load()?.name
        try await session.sendProfileUpdate(name: selfName, avatar: published, conversationId: job.conversationId)
    }

    private func publishedAvatar(from slot: DBProfileAvatar?) -> PublishedAvatar? {
        guard let slot, let url = slot.url, let salt = slot.salt, let nonce = slot.nonce, let key = slot.encryptionKey else {
            return nil
        }
        return PublishedAvatar(url: url, salt: salt, nonce: nonce, key: key)
    }

    private func reschedule(_ job: DBProfilePublishJob, error: any Error) async {
        // Re-fetch so the reschedule preserves any ciphertext/uploaded URL cached
        // during the attempt, rather than overwriting it with the stale `job`.
        var updated = await latestJob(id: job.id) ?? job
        updated.attemptCount += 1
        updated.lastError = "\(error)"
        updated.nextAttemptAt = now().addingTimeInterval(backoff.delay(forAttempt: updated.attemptCount))
        updated.state = .pending
        updated.updatedAt = now()
        try? await publishStore.update(updated)
        Log.error("ProfilePublisher job \(job.id) failed (attempt \(updated.attemptCount)): \(error)")
    }

    private func latestJob(id: String) async -> DBProfilePublishJob? {
        try? await publishStore.job(id: id)
    }

    private enum PublishDropError: Error {
        case staleSource
        case conversationGone
    }
}
