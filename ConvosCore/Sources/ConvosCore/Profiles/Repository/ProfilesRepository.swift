import Combine
import Foundation
import GRDB

/// Canonical source of identity (name + avatar) for rendering. Owns a warmed
/// in-memory cache over the profile stores, merges inbound events by precedence
/// and recency, and authors the current user's own profile.
///
/// Seeded and running, but not yet read by any view - the cutover flips
/// rendering onto it. `ProfileBackfill` (separate) seeds the stores from legacy
/// `DBMemberProfile` rows before `warmUp`, and the durable publisher is attached
/// via `bind(session:)` for self-publishing.
public actor ProfilesRepository {
    private let profileStore: any ProfileStoreProtocol
    private let selfProfileStore: any SelfProfileStoreProtocol
    private let databaseReader: any DatabaseReader
    private let conversationLocalStateWriter: any ConversationLocalStateWriterProtocol
    private let selfInboxIdProvider: @Sendable () async -> String?
    private let publisher: ProfilePublisher

    private var identities: [String: DBProfile] = [:]
    private var avatarsByInbox: [String: [String: DBProfileAvatar]] = [:]
    private var cachedSelf: DBMyProfile?
    private var cachedSelfInboxId: String?
    private var warmedUp: Bool = false

    private let changesRelay: ProfileChangesRelay = .init()

    /// Emits the `inboxId` whose identity or avatar changed. A coarse
    /// invalidation signal; the per-inbox reactive reads (`profilePublisher`)
    /// are the preferred subscription for rendering.
    nonisolated var profileChanges: AnyPublisher<String, Never> {
        changesRelay.subject.eraseToAnyPublisher()
    }

    /// `selfInboxIdProvider` resolves the current user's inbox id, which becomes
    /// available asynchronously (after inbox-ready). The repository caches the
    /// first non-nil result. This lets the DI construct the repository
    /// synchronously while the inbox id resolves lazily, matching the
    /// `ConnectionServicesStore` pattern.
    init(
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        publishStore: any ProfilePublishStoreProtocol,
        databaseReader: any DatabaseReader,
        conversationLocalStateWriter: any ConversationLocalStateWriterProtocol,
        selfInboxIdProvider: @escaping @Sendable () async -> String?
    ) {
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.databaseReader = databaseReader
        self.conversationLocalStateWriter = conversationLocalStateWriter
        self.selfInboxIdProvider = selfInboxIdProvider
        self.publisher = ProfilePublisher(
            publishStore: publishStore,
            profileStore: profileStore,
            selfProfileStore: selfProfileStore,
            conversationLocalStateWriter: conversationLocalStateWriter,
            selfInboxIdProvider: selfInboxIdProvider
        )
    }

    // MARK: - Reactive reads

    /// Reactive identity for one inbox, hydrated fresh from the stores via
    /// `ValueObservation`. This is the read path ViewModels subscribe to; it does
    /// not depend on the in-memory cache, so it is always current.
    public nonisolated func profilePublisher(inboxId: String) -> AnyPublisher<UnifiedProfile, Never> {
        ValueObservation
            // Handle the fetch per-element: a transient error yields a default
            // rather than throwing, which would fail the observation and, via the
            // terminal catch, complete the stream - freezing this reactive read
            // for the subscriber's lifetime. The trailing catch remains only as
            // the Error -> Never conversion for an unrecoverable database error.
            .tracking { db -> UnifiedProfile in
                do {
                    return try Self.fetchProfile(db, inboxId: inboxId)
                } catch {
                    return .empty(inboxId: inboxId)
                }
            }
            .removeDuplicates()
            .publisher(in: databaseReader)
            .catch { _ in Just(UnifiedProfile.empty(inboxId: inboxId)) }
            .eraseToAnyPublisher()
    }

    nonisolated func profilesPublisher(inboxIds: [String]) -> AnyPublisher<[String: UnifiedProfile], Never> {
        ValueObservation
            .tracking { db -> [String: UnifiedProfile] in
                do {
                    var result: [String: UnifiedProfile] = [:]
                    for inboxId in inboxIds {
                        result[inboxId] = try Self.fetchProfile(db, inboxId: inboxId)
                    }
                    return result
                } catch {
                    return [:]
                }
            }
            .removeDuplicates()
            .publisher(in: databaseReader)
            .catch { _ in Just([:]) }
            .eraseToAnyPublisher()
    }

    nonisolated func selfProfilePublisher() -> AnyPublisher<UnifiedProfile?, Never> {
        ValueObservation
            // Scope to the current user's row: resolve the current inbox id from
            // `DBInbox` inside the read so a leftover `DBMyProfile` row from a
            // previous account can't surface as the current user. Handled
            // per-element so a transient error doesn't terminate the stream.
            .tracking { db -> UnifiedProfile? in
                do {
                    guard let inboxId = try DBInbox.currentInboxId(db) else { return nil }
                    return try Self.fetchSelfProfile(db, inboxId: inboxId)
                } catch {
                    return nil
                }
            }
            .removeDuplicates()
            .publisher(in: databaseReader)
            .catch { _ in Just(nil) }
            .eraseToAnyPublisher()
    }

    static func fetchProfile(_ db: Database, inboxId: String) throws -> UnifiedProfile {
        let identity = try DBProfile.fetchOne(db, inboxId: inboxId)
        let avatars = try DBProfileAvatar.fetchAll(db, inboxId: inboxId)
        return UnifiedProfile.hydrate(identity: identity, avatarRows: avatars, inboxId: inboxId)
    }

    static func fetchSelfProfile(_ db: Database, inboxId: String) throws -> UnifiedProfile? {
        // Scope to the current user's row. `DBMyProfile.fetchOne(db)` with no
        // predicate returns whichever row exists, so a leftover row from a
        // previous account could otherwise surface as the current user.
        guard let selfRow = try DBMyProfile
            .filter(DBMyProfile.Columns.inboxId == inboxId)
            .fetchOne(db) else { return nil }
        let avatars = try DBProfileAvatar.fetchAll(db, inboxId: selfRow.inboxId)
        return UnifiedProfile(
            inboxId: selfRow.inboxId,
            name: selfRow.name,
            memberKind: nil,
            metadata: selfRow.metadata,
            avatars: UnifiedProfile.avatarMap(from: avatars),
            updatedAt: selfRow.updatedAt
        )
    }

    func warmUp() async {
        guard !warmedUp else { return }
        _ = await resolveSelfInboxId()
        do {
            for identity in try await profileStore.allIdentities() {
                identities[identity.inboxId] = identity
            }
            for row in try await profileStore.allAvatars() {
                avatarsByInbox[row.inboxId, default: [:]][row.conversationId] = row
            }
            cachedSelf = try await selfProfileStore.load()
            warmedUp = true
        } catch {
            Log.error("ProfilesRepository.warmUp failed: \(error)")
        }
    }

    private func resolveSelfInboxId() async -> String? {
        if let cachedSelfInboxId { return cachedSelfInboxId }
        let resolved = await selfInboxIdProvider()
        cachedSelfInboxId = resolved
        return resolved
    }

    // MARK: - Reads

    func profile(inboxId: String) -> UnifiedProfile {
        let rows = avatarsByInbox[inboxId].map { Array($0.values) } ?? []
        return UnifiedProfile.hydrate(identity: identities[inboxId], avatarRows: rows, inboxId: inboxId)
    }

    func profiles(inboxIds: [String]) -> [String: UnifiedProfile] {
        var result: [String: UnifiedProfile] = [:]
        for inboxId in inboxIds {
            result[inboxId] = profile(inboxId: inboxId)
        }
        return result
    }

    func selfProfile() -> UnifiedProfile? {
        guard let cachedSelf else { return nil }
        let rows = avatarsByInbox[cachedSelf.inboxId].map { Array($0.values) } ?? []
        return UnifiedProfile(
            inboxId: cachedSelf.inboxId,
            name: cachedSelf.name,
            memberKind: nil,
            metadata: cachedSelf.metadata,
            avatars: UnifiedProfile.avatarMap(from: rows),
            updatedAt: cachedSelf.updatedAt
        )
    }

    // MARK: - Inbound

    /// Merges one inbound identity/avatar event into the canonical stores.
    /// Events authored by the current user are ignored - self identity is held
    /// in `myProfile`, not `DBProfile`.
    func apply(_ event: ProfileDomainEvent) async {
        // Skip the current user's own echoed profile; self identity lives in
        // `myProfile`. If the inbox id isn't resolvable yet, process the event
        // rather than risk dropping another member's data.
        if let selfId = await resolveSelfInboxId(), event.inboxId == selfId {
            return
        }
        var changed = false

        let existingIdentity = identities[event.inboxId]
        let mergedIdentity = ProfileMerge.mergeIdentity(
            existing: existingIdentity,
            inboxId: event.inboxId,
            incoming: event.identity,
            source: event.source,
            sentAt: event.sentAt
        )
        if mergedIdentity != existingIdentity {
            do {
                try await profileStore.saveIdentity(mergedIdentity)
                identities[event.inboxId] = mergedIdentity
                changed = true
            } catch {
                Log.error("ProfilesRepository.apply identity failed: \(error)")
            }
        }

        let existingAvatar = avatarsByInbox[event.inboxId]?[event.conversationId]
        let mergedAvatar = ProfileMerge.mergeAvatar(
            existing: existingAvatar,
            inboxId: event.inboxId,
            conversationId: event.conversationId,
            incoming: event.avatar,
            source: event.source,
            sentAt: event.sentAt
        )
        if let mergedAvatar, mergedAvatar != existingAvatar {
            do {
                try await profileStore.saveAvatar(mergedAvatar)
                avatarsByInbox[event.inboxId, default: [:]][event.conversationId] = mergedAvatar
                changed = true
            } catch {
                Log.error("ProfilesRepository.apply avatar failed: \(error)")
            }
        }

        if changed {
            changesRelay.subject.send(event.inboxId)
        }
    }

    // MARK: - Self write

    func updateSelfProfile(_ edit: SelfProfileEdit) async throws {
        guard let selfId = await resolveSelfInboxId() else {
            throw ProfilesRepositoryError.selfInboxUnavailable
        }
        // Load the current row first so an edit before warm-up carries forward
        // the existing name/metadata rather than starting from a blank profile.
        // The store additionally preserves image fields atomically on save.
        let existing: DBMyProfile
        if let cachedSelf {
            existing = cachedSelf
        } else {
            // Propagate a load error rather than falling back to a blank row: a
            // transient read failure must not overwrite the stored name,
            // metadata, and image with an empty profile. A genuinely absent row
            // (nil) starts fresh.
            existing = try await selfProfileStore.load() ?? DBMyProfile(inboxId: selfId)
        }
        let updated = edit.applied(to: existing, updatedAt: Date())
        try await selfProfileStore.save(updated)
        cachedSelf = updated
        changesRelay.subject.send(selfId)
    }

    // MARK: - Self publish

    /// Attaches the XMTP/upload session so the durable publisher can drain. Also
    /// resumes any jobs left over from a previous run.
    func bind(session: any ProfilePublishSession) async {
        await publisher.attach(session: session)
    }

    func unbind() async {
        await publisher.detach()
    }

    /// Records a name and/or new avatar edit locally and bumps the self
    /// profile's `updatedAt`. Propagation is lazy: the edit reaches a
    /// conversation only when the user next opens or sends in it (via
    /// `publishMyProfileToConversation`), so it never fans out to conversations
    /// the user has stopped engaging with. When a `priorityConversationId` (the
    /// active conversation) is given, it is published immediately so the user
    /// sees their change reflected without waiting for the next send.
    public func publishMyProfile(displayName: String?, avatarBytes: Data?, priorityConversationId: String?) async throws {
        let nameField: SelfProfileEdit.Field<String?>
        if let displayName {
            nameField = .set(displayName)
        } else {
            nameField = .keep
        }
        try await updateSelfProfile(SelfProfileEdit(name: nameField))
        if let avatarBytes {
            try await publisher.updateAvatarSource(avatarBytes)
        }
        if let priorityConversationId {
            try await publishMyProfileToConversation(priorityConversationId)
        }
    }

    /// Publishes the current self profile to one conversation, but only if it has
    /// changed since the last profile published there. The comparison is
    /// `ConversationLocalState.publishedProfileUpdatedAt` (what we last sent here)
    /// against `DBMyProfile.updatedAt` (the current profile). This is the lazy
    /// propagation seam: a fresh conversation (no stamp) always publishes, an
    /// up-to-date conversation is a no-op, and a stale one re-publishes and
    /// re-stamps. Called on conversation open and before an outgoing send, so it
    /// is impossible to send a message after editing your profile without also
    /// sending the profile update.
    public func publishMyProfileToConversation(_ conversationId: String) async throws {
        guard let selfId = await resolveSelfInboxId() else { return }
        let shouldPublish = try await databaseReader.read { db -> Bool in
            guard let myUpdatedAt = try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == selfId)
                .fetchOne(db)?.updatedAt else {
                return false
            }
            let publishedAt = try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)?.publishedProfileUpdatedAt
            guard let publishedAt else { return true }
            return publishedAt < myUpdatedAt
        }
        guard shouldPublish else { return }
        // Enqueue the publish. The conversation's publishedProfileUpdatedAt is
        // stamped by the publisher only after the ProfileUpdate is actually
        // delivered - never optimistically here - so a send that fails or is
        // dropped (e.g. the conversation isn't fully joined yet) leaves the
        // conversation stale and eligible for retry rather than being silently
        // marked as up to date.
        try await publisher.publishConversation(conversationId)
    }

    /// Records new self metadata locally and bumps `updatedAt`. Propagation is
    /// lazy per conversation, same as `publishMyProfile`.
    public func publishMyProfileMetadata(_ metadata: ProfileMetadata?) async throws {
        try await updateSelfProfile(SelfProfileEdit(metadata: .set(metadata)))
    }

    /// Drops a conversation's avatar slots from every person's cache and the
    /// store (called when a conversation is deleted). Identity is preserved.
    func purgeConversationAvatars(_ conversationId: String) async {
        for inboxId in Array(avatarsByInbox.keys) {
            avatarsByInbox[inboxId]?[conversationId] = nil
        }
        do {
            try await profileStore.deleteAvatars(conversationId: conversationId)
        } catch {
            Log.error("ProfilesRepository.purgeConversationAvatars failed: \(error)")
        }
    }
}

/// Holds the change subject so the actor can vend it from a nonisolated context.
/// `PassthroughSubject` is not `Sendable`, so it cannot be an actor-isolated
/// `let` read from `nonisolated`. This box is safe: the subject is only sent to
/// from inside the actor and only read (to build the publisher) via `subject`.
private final class ProfileChangesRelay: @unchecked Sendable {
    let subject: PassthroughSubject<String, Never> = .init()
}

enum ProfilesRepositoryError: Error {
    case selfInboxUnavailable
}
