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
    private let selfInboxId: String

    private var identities: [String: DBProfile] = [:]
    private var avatarsByInbox: [String: [String: DBProfileAvatar]] = [:]
    private var cachedSelf: DBSelfProfile?
    private var warmedUp: Bool = false

    private let changesSubject: PassthroughSubject<String, Never> = .init()

    /// Emits the `inboxId` whose identity or avatar changed. Repos and read
    /// models subscribe to invalidate; the reactive per-inbox publishers are
    /// added at the cutover when the ViewModels need them.
    nonisolated var profileChanges: AnyPublisher<String, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    init(
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        selfInboxId: String
    ) {
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.selfInboxId = selfInboxId
    }

    func warmUp() async {
        guard !warmedUp else { return }
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
        guard event.inboxId != selfInboxId else { return }
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
            changesSubject.send(event.inboxId)
        }
    }

    // MARK: - Self write

    func updateSelfProfile(_ edit: SelfProfileEdit) async throws {
        let existing = cachedSelf ?? DBSelfProfile(inboxId: selfInboxId, updatedAt: .distantPast)
        let updated = edit.applied(to: existing, updatedAt: Date())
        try await selfProfileStore.save(updated)
        cachedSelf = updated
        changesSubject.send(selfInboxId)
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
