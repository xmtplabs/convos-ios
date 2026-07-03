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
        selfInboxIdProvider: @escaping @Sendable () async -> String?
    ) {
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.databaseReader = databaseReader
        self.selfInboxIdProvider = selfInboxIdProvider
        self.publisher = ProfilePublisher(
            publishStore: publishStore,
            profileStore: profileStore,
            selfProfileStore: selfProfileStore,
            selfInboxIdProvider: selfInboxIdProvider
        )
    }

    // MARK: - Reactive reads

    /// Reactive identity for one inbox, hydrated fresh from the stores via
    /// `ValueObservation`. This is the read path ViewModels subscribe to; it does
    /// not depend on the in-memory cache, so it is always current.
    public nonisolated func profilePublisher(inboxId: String) -> AnyPublisher<UnifiedProfile, Never> {
        ValueObservation
            .tracking { db in try Self.fetchProfile(db, inboxId: inboxId) }
            .removeDuplicates()
            .publisher(in: databaseReader)
            .catch { _ in Just(UnifiedProfile.empty(inboxId: inboxId)) }
            .eraseToAnyPublisher()
    }

    nonisolated func profilesPublisher(inboxIds: [String]) -> AnyPublisher<[String: UnifiedProfile], Never> {
        ValueObservation
            .tracking { db -> [String: UnifiedProfile] in
                var result: [String: UnifiedProfile] = [:]
                for inboxId in inboxIds {
                    result[inboxId] = try Self.fetchProfile(db, inboxId: inboxId)
                }
                return result
            }
            .removeDuplicates()
            .publisher(in: databaseReader)
            .catch { _ in Just([:]) }
            .eraseToAnyPublisher()
    }

    nonisolated func selfProfilePublisher() -> AnyPublisher<UnifiedProfile?, Never> {
        ValueObservation
            .tracking { db -> UnifiedProfile? in try Self.fetchSelfProfile(db) }
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

    static func fetchSelfProfile(_ db: Database) throws -> UnifiedProfile? {
        guard let selfRow = try DBMyProfile.fetchOne(db) else { return nil }
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
        } else if let loaded = try? await selfProfileStore.load() {
            existing = loaded
        } else {
            existing = DBMyProfile(inboxId: selfId)
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

    /// Records a name and/or new avatar and fans the update out to every
    /// conversation via the durable publish queue. The name is written to the
    /// self profile first so the publisher's jobs send the current name.
    public func publishMyProfile(displayName: String?, avatarBytes: Data?, priorityConversationId: String?) async throws {
        if let displayName {
            try await updateSelfProfile(SelfProfileEdit(name: .set(displayName)))
        }
        try await publisher.publish(avatarBytes: avatarBytes, priorityConversationId: priorityConversationId)
    }

    /// Seeds a freshly created or joined conversation with the current profile.
    ///
    /// Idempotent: skips when the current user already has an avatar slot for
    /// this conversation, i.e. we have already published our profile here. This
    /// prevents a redundant `ProfileUpdate` on every conversation open. Skipping
    /// cannot drop a real change - a genuine profile edit fans out to every known
    /// conversation via `publishMyProfile`, not the seeder. (A name-only user has
    /// no avatar slot, so they may re-seed on open; a cheap, known residual.)
    public func publishMyProfileToConversation(_ conversationId: String) async throws {
        if let selfId = await resolveSelfInboxId(),
           let existing = try? await profileStore.avatar(inboxId: selfId, conversationId: conversationId),
           existing.url != nil {
            return
        }
        try await publisher.publishConversation(conversationId)
    }

    /// Records new self metadata and re-publishes it (a name/metadata-only fan-out
    /// that re-sends the existing avatar) to every conversation.
    public func publishMyProfileMetadata(_ metadata: ProfileMetadata?) async throws {
        try await updateSelfProfile(SelfProfileEdit(metadata: .set(metadata)))
        try await publisher.publish(avatarBytes: nil, priorityConversationId: nil)
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
