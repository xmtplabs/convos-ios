import Foundation
import GRDB

/// Fills in display identity from the backend for inboxes we do not know, or
/// have not checked in a while.
///
/// This is the pull half of the profile model. The XMTP change signal is the
/// push half and carries the values, so in the common case nothing here runs.
/// What this covers is everything the signal cannot: a member whose update
/// predates our joining the conversation, a reinstall with no local rows, an
/// agent nobody witnessed announce itself.
///
/// Three properties matter, and all three are about not making rendering worse:
///
/// - It never blocks a view. Callers ask it to resolve and carry on drawing
///   whatever they already have; the write lands in `profile` and the reactive
///   reads pick it up.
/// - Concurrent asks for the same inbox coalesce. A member list of 40 people
///   scrolling into view produces one request, not 40.
/// - A failure is silent and retryable. The backend being unreachable means a
///   monogram for a moment, never an error surfaced to a person.
actor RemoteProfileResolver {
    /// How long a resolved profile is trusted before a re-check. The change
    /// signal invalidates immediately when someone edits, so this only bounds
    /// how stale a profile can get when the signal never arrived.
    static let defaultTTL: TimeInterval = 24 * 60 * 60

    private let databaseWriter: any DatabaseWriter
    private let apiClientProvider: @Sendable () async -> (any ConvosAPIClientProtocol)?
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    /// Inboxes with a fetch in flight, so a second ask joins the first instead
    /// of issuing its own request.
    private var inFlight: Set<String> = []

    init(
        databaseWriter: any DatabaseWriter,
        apiClientProvider: @escaping @Sendable () async -> (any ConvosAPIClientProtocol)?,
        ttl: TimeInterval = RemoteProfileResolver.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseWriter = databaseWriter
        self.apiClientProvider = apiClientProvider
        self.ttl = ttl
        self.now = now
    }

    /// Resolves whatever in `inboxIds` is unknown or stale. Returns when the
    /// write has landed so callers that want to await it can; the usual caller
    /// does not.
    func resolve(inboxIds: [String]) async {
        let wanted = Set(inboxIds).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return }

        let stale: [String]
        do {
            stale = try await staleInboxIds(from: wanted)
        } catch {
            Log.error("RemoteProfileResolver: staleness check failed: \(error)")
            return
        }

        let toFetch = stale.filter { !inFlight.contains($0) }
        guard !toFetch.isEmpty else { return }

        inFlight.formUnion(toFetch)
        defer { inFlight.subtract(toFetch) }

        guard let apiClient = await apiClientProvider() else { return }

        do {
            let profiles = try await apiClient.getProfiles(inboxIds: toFetch)
            try await store(profiles, requested: toFetch)
        } catch {
            // Deliberately swallowed: the caller is a view that already has
            // something to draw, and the next appearance retries.
            Log.warning("RemoteProfileResolver: fetch failed: \(error.localizedDescription)")
        }
    }

    /// Rows we have never resolved, or resolved longer ago than the TTL.
    private func staleInboxIds(from wanted: Set<String>) async throws -> [String] {
        let cutoff = now().addingTimeInterval(-ttl)
        let ids = Array(wanted)
        return try await databaseWriter.read { db in
            let known = try DBProfile
                .filter(ids.contains(DBProfile.Columns.inboxId))
                .fetchAll(db)
            let fresh = Set(
                known
                    .filter { profile in
                        guard let fetchedAt = profile.remoteFetchedAt else { return false }
                        return fetchedAt > cutoff
                    }
                    .map(\.inboxId)
            )
            return ids.filter { !fresh.contains($0) }
        }
    }

    /// Writes what the backend returned.
    ///
    /// Inboxes that were asked for and came back absent are stamped as fetched
    /// with no values, so an unregistered person is re-checked on the TTL rather
    /// than on every single render.
    private func store(_ profiles: [ProfilesAPI.Profile], requested: [String]) async throws {
        let fetchedAt = now()
        let byInbox = Dictionary(uniqueKeysWithValues: profiles.map { ($0.inboxId, $0) })

        try await databaseWriter.write { db in
            for inboxId in requested {
                let existing = try DBProfile.fetchOne(db, inboxId: inboxId)
                let remote = byInbox[inboxId]
                var row = existing ?? DBProfile(
                    inboxId: inboxId,
                    profileSource: .profileUpdate,
                    updatedAt: fetchedAt
                )
                if let remote {
                    row.name = remote.name
                    row.avatarUrl = remote.avatarUrl
                    row.remoteVersion = remote.version
                    row.updatedAt = remote.updatedAt
                }
                row.remoteFetchedAt = fetchedAt
                try row.save(db)
            }
        }
    }
}
