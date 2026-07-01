import Combine
import Foundation

/// Canonical source of identity (name + avatar) for rendering. Owns a warmed
/// in-memory cache over the profile stores, merges inbound events by precedence
/// and recency, and authors the current user's own profile.
///
/// Not wired into sync, startup, or any view yet. `ProfileBackfill` (separate)
/// seeds the stores from legacy `DBMemberProfile` rows before `warmUp`, and the
/// durable publisher (separate) is attached for self-publishing.
actor ProfilesRepository {
    private let profileStore: any ProfileStoreProtocol
    private let selfProfileStore: any SelfProfileStoreProtocol
    private let selfInboxIdProvider: @Sendable () async -> String?

    private var identities: [String: DBProfile] = [:]
    private var avatarsByInbox: [String: [String: DBProfileAvatar]] = [:]
    private var cachedSelf: DBSelfProfile?
    private var cachedSelfInboxId: String?
    private var warmedUp: Bool = false

    private let changesRelay: ProfileChangesRelay = .init()

    /// Emits the `inboxId` whose identity or avatar changed. Repos and read
    /// models subscribe to invalidate; the reactive per-inbox publishers are
    /// added at the cutover when the ViewModels need them.
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
        selfInboxIdProvider: @escaping @Sendable () async -> String?
    ) {
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.selfInboxIdProvider = selfInboxIdProvider
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
    /// in `selfProfile`, not `DBProfile`.
    func apply(_ event: ProfileDomainEvent) async {
        // Skip the current user's own echoed profile; self identity lives in
        // `selfProfile`. If the inbox id isn't resolvable yet, process the event
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
        let existing = cachedSelf ?? DBSelfProfile(inboxId: selfId, updatedAt: .distantPast)
        let updated = edit.applied(to: existing, updatedAt: Date())
        try await selfProfileStore.save(updated)
        cachedSelf = updated
        changesRelay.subject.send(selfId)
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
