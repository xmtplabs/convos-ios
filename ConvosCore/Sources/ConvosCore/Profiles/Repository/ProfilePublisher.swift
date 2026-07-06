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
/// `ProfilesRepository` owns the instance and attaches a session via
/// `bind(session:)` at startup, which resumes any leftover jobs. Within a
/// process, drains are serialized.
actor ProfilePublisher {
    private let publishStore: any ProfilePublishStoreProtocol
    private let profileStore: any ProfileStoreProtocol
    private let selfProfileStore: any SelfProfileStoreProtocol
    private let conversationLocalStateWriter: any ConversationLocalStateWriterProtocol
    private let selfInboxIdProvider: @Sendable () async -> String?
    private let now: @Sendable () -> Date
    private let backoff: PublishBackoff

    private var session: (any ProfilePublishSession)?
    private var draining: Bool = false
    private var cachedSelfInboxId: String?

    init(
        publishStore: any ProfilePublishStoreProtocol,
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        conversationLocalStateWriter: any ConversationLocalStateWriterProtocol,
        selfInboxIdProvider: @escaping @Sendable () async -> String?,
        now: @escaping @Sendable () -> Date = { Date() },
        backoff: PublishBackoff = .default
    ) {
        self.publishStore = publishStore
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.conversationLocalStateWriter = conversationLocalStateWriter
        self.selfInboxIdProvider = selfInboxIdProvider
        self.now = now
        self.backoff = backoff
    }

    private func resolveSelfInboxId() async -> String? {
        if let cachedSelfInboxId { return cachedSelfInboxId }
        let resolved = await selfInboxIdProvider()
        cachedSelfInboxId = resolved
        return resolved
    }

    func attach(session: any ProfilePublishSession) async {
        self.session = session
        await drainReadyJobs()
    }

    func detach() {
        session = nil
    }

    /// Records a new source avatar so subsequent per-conversation publishes
    /// re-encrypt it to each conversation's group key. Does not enqueue or fan
    /// out - propagation is lazy and per-conversation via `publishConversation`.
    func updateAvatarSource(_ avatarBytes: Data) async throws {
        guard let selfInboxId = await resolveSelfInboxId() else { return }
        // Atomic read-increment-write: two concurrent avatar edits must not read
        // the same version and both write it, or the stale-source supersede check
        // in processAvatarJob would fail to detect the earlier batch as stale.
        _ = try await publishStore.bumpAvatarSource(inboxId: selfInboxId, plaintext: avatarBytes, updatedAt: now())
    }

    /// Seeds a single conversation with the current profile (e.g. a freshly
    /// created or joined group), then drains.
    func publishConversation(_ conversationId: String) async throws {
        guard let selfInboxId = await resolveSelfInboxId() else { return }
        let source = try await publishStore.source(inboxId: selfInboxId)
        try await enqueueJob(conversationId: conversationId, sourceVersion: source?.version, hasAvatar: source != nil)
        await drainReadyJobs()
    }

    func drainReadyJobs() async {
        guard !draining, let session else { return }
        draining = true
        defer { draining = false }
        guard let selfInboxId = await resolveSelfInboxId() else { return }
        // Return jobs a previous drain left mid-flight to the ready pool.
        try? await publishStore.reclaimStalledJobs()
        while let job = try? await publishStore.nextReadyJob(now: now()) {
            guard let claimed = await claim(job) else { break }
            await process(claimed, session: session, selfInboxId: selfInboxId)
        }
    }

    /// Marks a ready job in-flight (`uploading`) before processing it. Because
    /// `nextReadyJob` only returns `pending` jobs, this guarantees a job whose
    /// delete or reschedule fails can't be handed straight back to the loop and
    /// spin it. Returns nil (stop draining) if the claim write itself fails, so
    /// a persistent write error can't hot-loop. A job left `uploading` by an
    /// interrupted drain is reclaimed at the next drain.
    private func claim(_ job: DBProfilePublishJob) async -> DBProfilePublishJob? {
        var claimed = job
        claimed.state = .uploading
        claimed.updatedAt = now()
        do {
            try await publishStore.update(claimed)
            return claimed
        } catch {
            Log.error("ProfilePublisher: failed to claim job \(job.id): \(error)")
            return nil
        }
    }

    // MARK: - Enqueue

    private func enqueueJob(conversationId: String, sourceVersion: Int64?, hasAvatar: Bool) async throws {
        let timestamp = now()
        // Assign seq, insert, and supersede this conversation's older jobs in one
        // atomic write so concurrent enqueues can't collide on seq.
        try await publishStore.enqueueNext { seq in
            DBProfilePublishJob(
                id: UUID().uuidString,
                seq: seq,
                conversationId: conversationId,
                sourceVersion: sourceVersion,
                hasAvatar: hasAvatar,
                nextAttemptAt: timestamp,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
    }

    // MARK: - Process

    private func process(_ job: DBProfilePublishJob, session: any ProfilePublishSession, selfInboxId: String) async {
        do {
            if job.hasAvatar {
                try await processAvatarJob(job, session: session, selfInboxId: selfInboxId)
            } else {
                try await processNameOnlyJob(job, session: session, selfInboxId: selfInboxId)
            }
            try? await publishStore.deleteJob(id: job.id)
        } catch is PublishDropError {
            try? await publishStore.deleteJob(id: job.id)
        } catch {
            await reschedule(job, error: error)
        }
    }

    private func processAvatarJob(_ job: DBProfilePublishJob, session: any ProfilePublishSession, selfInboxId: String) async throws {
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
        let selfProfile = try await selfProfileStore.load()
        try await session.sendProfileUpdate(name: selfProfile?.name, metadata: selfProfile?.metadata, avatar: published, conversationId: job.conversationId)
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
        await stampPublished(selfProfile, conversationId: job.conversationId)
    }

    private func processNameOnlyJob(_ job: DBProfilePublishJob, session: any ProfilePublishSession, selfInboxId: String) async throws {
        let existing = try await profileStore.avatar(inboxId: selfInboxId, conversationId: job.conversationId)
        let published = publishedAvatar(from: existing)
        let selfProfile = try await selfProfileStore.load()
        try await session.sendProfileUpdate(name: selfProfile?.name, metadata: selfProfile?.metadata, avatar: published, conversationId: job.conversationId)
        await stampPublished(selfProfile, conversationId: job.conversationId)
    }

    /// Records that the self profile as of `selfProfile.updatedAt` has actually
    /// been delivered to this conversation, so the change-aware lazy sync stops
    /// re-publishing until the next edit. Stamped only after a successful send -
    /// never optimistically - so a failed or dropped publish leaves the
    /// conversation marked stale and eligible for retry. Best-effort: a stamp
    /// failure just means a harmless duplicate publish next time.
    private func stampPublished(_ selfProfile: DBMyProfile?, conversationId: String) async {
        guard let updatedAt = selfProfile?.updatedAt else { return }
        try? await conversationLocalStateWriter.setPublishedProfileUpdatedAt(updatedAt, for: conversationId)
    }

    private func publishedAvatar(from slot: DBProfileAvatar?) -> PublishedAvatar? {
        guard let slot, let url = slot.url, let salt = slot.salt, let nonce = slot.nonce, let key = slot.encryptionKey else {
            return nil
        }
        return PublishedAvatar(url: url, salt: salt, nonce: nonce, key: key)
    }

    private func reschedule(_ job: DBProfilePublishJob, error: any Error) async {
        // Re-fetch so the reschedule preserves any ciphertext/uploaded URL cached
        // during the attempt. If the job is gone - a newer publish superseded and
        // deleted it while this attempt was in flight - do not re-insert it, or a
        // superseded (obsolete) profile/avatar would be retried and eventually
        // sent after a newer publish intent.
        guard var updated = await latestJob(id: job.id) else {
            Log.error("ProfilePublisher job \(job.id) failed but was superseded/deleted, skipping reschedule: \(error)")
            return
        }
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
