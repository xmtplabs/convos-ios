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
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var session: (any ProfilePublishSession)?
    private var draining: Bool = false
    private var redrainRequested: Bool = false
    /// Jobs currently claimed by the inline publish or the drain loop, so a
    /// concurrent drain's stalled-job reclaim never returns live work to the
    /// ready pool and processes it twice.
    private var inFlightJobIds: Set<String> = []
    private var cachedSelfInboxId: String?
    private var retryTimer: Task<Void, Never>?

    init(
        publishStore: any ProfilePublishStoreProtocol,
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        conversationLocalStateWriter: any ConversationLocalStateWriterProtocol,
        selfInboxIdProvider: @escaping @Sendable () async -> String?,
        now: @escaping @Sendable () -> Date = { Date() },
        backoff: PublishBackoff = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.publishStore = publishStore
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.conversationLocalStateWriter = conversationLocalStateWriter
        self.selfInboxIdProvider = selfInboxIdProvider
        self.now = now
        self.backoff = backoff
        self.sleep = sleep
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
        retryTimer?.cancel()
        retryTimer = nil
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

    /// Seeds the avatar source from pre-existing global avatar bytes, but only
    /// when no source exists yet. Lets an upgraded user's saved avatar propagate
    /// via the lazy per-conversation publish without clobbering a source the user
    /// set after upgrading.
    func seedAvatarSourceIfAbsent(_ avatarBytes: Data) async throws {
        guard let selfInboxId = await resolveSelfInboxId() else { return }
        guard try await publishStore.source(inboxId: selfInboxId) == nil else { return }
        try await publishStore.setSource(
            DBProfileAvatarSource(inboxId: selfInboxId, plaintext: avatarBytes, version: 1, updatedAt: now())
        )
    }

    /// Seeds a single conversation with the current profile (e.g. a freshly
    /// created or joined group). Processes that conversation's job inline -
    /// callers include the pre-send hook on every outgoing message, which must
    /// never wait behind other conversations' uploads - and kicks a background
    /// drain for whatever else is ready.
    func publishConversation(_ conversationId: String) async throws {
        guard let selfInboxId = await resolveSelfInboxId() else { return }
        let source = try await publishStore.source(inboxId: selfInboxId)
        let selfProfile = try await selfProfileStore.load()
        let job = try await enqueueJob(
            conversationId: conversationId,
            sourceVersion: source?.version,
            hasAvatar: source != nil,
            profileUpdatedAt: selfProfile?.updatedAt
        )
        if let session, let claimed = try? await publishStore.claimJob(id: job.id, updatedAt: now()) {
            inFlightJobIds.insert(claimed.id)
            defer { inFlightJobIds.remove(claimed.id) }
            await process(claimed, session: session, selfInboxId: selfInboxId)
        }
        kickBackgroundDrain()
    }

    /// Runs a full drain off the caller's execution path. The `draining` guard
    /// serializes with any drain already in flight.
    private func kickBackgroundDrain() {
        Task { await drainReadyJobs() }
    }

    func drainReadyJobs() async {
        // A drain requested while one is running must not be dropped: the
        // running drain's job scan and timer snapshot may both predate the
        // requester's enqueue, which would leave that job waiting for the next
        // external trigger. Flag it and let the running drain loop once more.
        if draining {
            redrainRequested = true
            return
        }
        guard session != nil else { return }
        draining = true
        defer { draining = false }
        repeat {
            redrainRequested = false
            await drainPass()
            await armRetryTimer()
        } while redrainRequested
    }

    private func drainPass() async {
        guard let session else { return }
        guard let selfInboxId = await resolveSelfInboxId() else { return }
        // Return jobs a previous process instance left mid-flight to the ready
        // pool. Jobs currently being processed inline by publishConversation
        // are alive, not stalled - reclaiming one mid-upload would let this
        // drain claim and process it a second time.
        try? await publishStore.reclaimStalledJobs(excluding: inFlightJobIds)
        while let job = try? await publishStore.nextReadyJob(now: now()) {
            // The atomic claim (pending -> uploading) is what keeps this loop
            // and the inline per-conversation path from double-processing a
            // job. A nil claim means the job was claimed or superseded between
            // fetch and claim - skip it; it is no longer pending so the next
            // fetch cannot return it again. A thrown claim (persistent write
            // error) stops the drain so it can't hot-loop.
            let claimed: DBProfilePublishJob?
            do {
                claimed = try await publishStore.claimJob(id: job.id, updatedAt: now())
            } catch {
                Log.error("ProfilePublisher: failed to claim job \(job.id): \(error)")
                break
            }
            guard let claimed else { continue }
            inFlightJobIds.insert(claimed.id)
            defer { inFlightJobIds.remove(claimed.id) }
            await process(claimed, session: session, selfInboxId: selfInboxId)
        }
    }

    /// Schedules the next drain for the earliest rescheduled job, so backoff
    /// deadlines actually fire instead of waiting for the next app launch or
    /// message send. Re-armed after every drain; cancelled on detach.
    private func armRetryTimer() async {
        retryTimer?.cancel()
        retryTimer = nil
        guard session != nil else { return }
        guard let earliest = try? await publishStore.earliestNextAttempt() else { return }
        let delay = max(0, earliest.timeIntervalSince(now()))
        retryTimer = Task { [sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self.drainReadyJobs()
        }
    }

    // MARK: - Enqueue

    private func enqueueJob(
        conversationId: String,
        sourceVersion: Int64?,
        hasAvatar: Bool,
        profileUpdatedAt: Date?
    ) async throws -> DBProfilePublishJob {
        let timestamp = now()
        // Assign seq, insert, and supersede this conversation's older jobs in one
        // atomic write so concurrent enqueues can't collide on seq.
        return try await publishStore.enqueueNext { seq in
            DBProfilePublishJob(
                id: UUID().uuidString,
                seq: seq,
                conversationId: conversationId,
                sourceVersion: sourceVersion,
                hasAvatar: hasAvatar,
                nextAttemptAt: timestamp,
                profileUpdatedAt: profileUpdatedAt,
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
        } catch is ProfilePublishSessionError {
            // The XMTP conversation is gone (deleted or left) - the send can
            // never succeed, so drop the job instead of retrying forever at
            // the backoff cap. The avatar path already drops via a nil image
            // key; this covers name-only jobs.
            Log.warning("ProfilePublisher: dropping job \(job.id) for missing conversation \(job.conversationId)")
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
        let metadata = try await outgoingMetadata(for: job.conversationId, selfInboxId: selfInboxId, selfProfile: selfProfile)
        try await session.sendProfileUpdate(name: selfProfile?.name, metadata: metadata, avatar: published, conversationId: job.conversationId)
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
        await stampPublished(job)
    }

    private func processNameOnlyJob(_ job: DBProfilePublishJob, session: any ProfilePublishSession, selfInboxId: String) async throws {
        let existing = try await profileStore.avatar(inboxId: selfInboxId, conversationId: job.conversationId)
        let published = publishedAvatar(from: existing)
        let selfProfile = try await selfProfileStore.load()
        let metadata = try await outgoingMetadata(for: job.conversationId, selfInboxId: selfInboxId, selfProfile: selfProfile)
        try await session.sendProfileUpdate(name: selfProfile?.name, metadata: metadata, avatar: published, conversationId: job.conversationId)
        await stampPublished(job)
    }

    // MARK: - Scoped metadata

    /// Publishes conversation-scoped metadata (cloud connection grants, agent
    /// timezone) to one conversation immediately, merged over the global self
    /// metadata, and persists the scoped map on success.
    ///
    /// Deliberately not routed through the durable queue: callers rely on a
    /// send failure propagating so they can decline to persist their own state
    /// (`CloudConnectionGrantWriter` declines the local grant change; the
    /// timezone publisher declines its throttle stamp and retries on the next
    /// foreground). The scoped map is persisted only after the send succeeds
    /// for the same reason - a failed publish must leave no trace that later
    /// lazy publishes would deliver.
    ///
    /// A persist failure after a successful send also throws, and that ordering
    /// is deliberate. The remote transiently holds the new map, but the caller
    /// declines its own state and the next queue publish (reading the old
    /// stored map) reverts the remote, so everything converges on the pre-send
    /// state. The alternatives are worse: persisting before the send turns a
    /// failed send into a durable map that later lazy publishes deliver even
    /// though the caller rolled back, and swallowing the persist failure lets
    /// the caller commit state whose metadata the next queue publish silently
    /// wipes from the remote.
    func publishScopedMetadata(_ metadata: ProfileMetadata?, conversationId: String) async throws {
        guard let session else { throw ProfilePublishError.sessionUnavailable }
        guard let selfInboxId = await resolveSelfInboxId() else {
            throw ProfilePublishError.selfInboxUnavailable
        }
        let slot = try await profileStore.avatar(inboxId: selfInboxId, conversationId: conversationId)
        let selfProfile = try await selfProfileStore.load()
        let merged = Self.mergedMetadata(global: selfProfile?.metadata, scoped: metadata)
        try await session.sendProfileUpdate(
            name: selfProfile?.name,
            metadata: merged,
            avatar: publishedAvatar(from: slot),
            conversationId: conversationId
        )
        try await selfProfileStore.saveScopedMetadata(metadata, inboxId: selfInboxId, conversationId: conversationId, updatedAt: now())
    }

    /// The metadata map for an outgoing ProfileUpdate to one conversation: the
    /// global self metadata with that conversation's scoped keys merged over it
    /// (scoped wins). Keeps every queue send carrying the conversation's grants
    /// and timezone, so a later name or avatar publish can never wipe them at
    /// the receiver. The caller's already-resolved inbox id is threaded through
    /// so the store read cannot disagree with the publish about the active
    /// account mid-flight.
    private func outgoingMetadata(for conversationId: String, selfInboxId: String, selfProfile: DBMyProfile?) async throws -> ProfileMetadata? {
        let scoped = try await selfProfileStore.scopedMetadata(inboxId: selfInboxId, conversationId: conversationId)
        return Self.mergedMetadata(global: selfProfile?.metadata, scoped: scoped)
    }

    static func mergedMetadata(global: ProfileMetadata?, scoped: ProfileMetadata?) -> ProfileMetadata? {
        var merged = global ?? [:]
        for (key, value) in scoped ?? [:] {
            merged[key] = value
        }
        return merged.isEmpty ? nil : merged
    }

    /// Records that the self profile as of the job's enqueue time has been
    /// delivered to this conversation, so the change-aware lazy sync stops
    /// re-publishing until the next edit. The stamp is the enqueue-time
    /// `profileUpdatedAt` pinned on the job, never the send-time value: the
    /// job's content decisions were made at enqueue, so an edit made after
    /// enqueue must leave the conversation stale and eligible for re-publish
    /// (stamping the newer value would suppress that edit's publish forever).
    /// Stamped only after a successful send - never optimistically - so a
    /// failed or dropped publish leaves the conversation stale. Best-effort: a
    /// stamp failure or a nil pin (legacy job rows) just means a harmless
    /// duplicate publish next time.
    private func stampPublished(_ job: DBProfilePublishJob) async {
        guard let profileUpdatedAt = job.profileUpdatedAt else { return }
        try? await conversationLocalStateWriter.setPublishedProfileUpdatedAt(profileUpdatedAt, for: job.conversationId)
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

/// Thrown by `publishScopedMetadata` when the immediate send cannot even be
/// attempted. Surfaced to callers (unlike queue jobs, which reschedule) because
/// scoped-metadata writers use the error to decline persisting their own state.
enum ProfilePublishError: Error {
    case sessionUnavailable
    case selfInboxUnavailable
}
