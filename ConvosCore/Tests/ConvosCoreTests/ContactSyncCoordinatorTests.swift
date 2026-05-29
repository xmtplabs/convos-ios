@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactSyncCoordinator Tests", .serialized)
struct ContactSyncCoordinatorTests {
    private static func seedConversation(
        db: Database,
        conversationId: String,
        creatorInboxId: String,
        memberInboxIds: [String],
        memberProfiles: [String: (name: String?, avatar: String?)] = [:]
    ) throws {
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        for inboxId in memberInboxIds {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }

        try DBConversation(
            id: conversationId,
            clientConversationId: conversationId,
            inviteTag: "tag-\(conversationId)",
            creatorId: creatorInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false
        ).insert(db)

        for inboxId in memberInboxIds {
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)

            if let profile = memberProfiles[inboxId] {
                try DBMemberProfile(
                    conversationId: conversationId,
                    inboxId: inboxId,
                    name: profile.name,
                    avatar: profile.avatar
                ).save(db)
            }
        }
    }

    @Test("syncContacts pulls non-self members into contacts and writes a sync marker")
    func testSyncContactsHappyPath() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"],
                memberProfiles: [
                    "alice": (name: "Alice", avatar: "https://example.com/a.png"),
                    "bob": (name: "Bob", avatar: nil)
                ]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let contacts: [DBContact] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db)
        }
        #expect(Set(contacts.map(\.inboxId)) == Set(["alice", "bob"]))
        let alice = contacts.first { $0.inboxId == "alice" }
        #expect(alice?.displayName == "Alice")
        #expect(alice?.avatarURL == "https://example.com/a.png")
        #expect(alice?.addedViaConversationId == conversationId)

        let marker = try await dbManager.dbReader.read { db in
            try DBConversationContactsSync.fetchOne(db, key: conversationId)
        }
        #expect(marker != nil)
    }

    @Test("syncContacts is idempotent — second call short-circuits and preserves addedAt")
    func testSyncContactsIdempotent() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let firstAddedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: "alice")?.addedAt
        }

        try await Task.sleep(nanoseconds: 5_000_000)

        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let secondAddedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: "alice")?.addedAt
        }
        #expect(firstAddedAt == secondAddedAt)
    }

    @Test("force-rerun on never-synced conversation skips when local user is not the creator")
    func testForceRerunSkipsNeverSyncedConversation() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                // Creator is someone else — the local user was invited.
                creatorInboxId: "other-inbox",
                memberInboxIds: ["other-inbox", selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        let contacts: [DBContact] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db)
        }
        #expect(contacts.isEmpty, "Action-gated rule must skip when local user is not the conversation creator")
    }

    @Test("force-rerun on never-synced conversation proceeds when local user is the creator")
    func testForceRerunProceedsForCreator() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                // Local user created this group — bypass the action-gate.
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        let contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds == Set(["alice", "bob"]), "Self-as-creator should bypass the action-gate")

        // Marker should also be written, so future first-message hooks
        // are no-ops on this conversation.
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
    }

    @Test("force-rerun on already-synced conversation pulls in newly added members")
    func testForceRerunPicksUpNewMembers() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        // Add a new member after the initial sync.
        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: "carol").save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: "carol",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)
        }

        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        let contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds == Set(["alice", "carol"]))
    }

    @Test("self inbox is excluded from contacts")
    func testSelfSkip() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let inboxIds: [String] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db).map(\.inboxId)
        }
        #expect(!inboxIds.contains(selfInboxId))
    }

    @Test("syncContacts no-ops when selfInboxIdProvider returns nil (across both pre-fix-broken quadrants)")
    func testSyncContactsNoOpsWhenSelfUnknown() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        // Seed a conversation but deliberately omit the DBInbox row so the
        // default selfInboxIdProvider would return nil. We also pass an
        // explicit nil-returning provider here to make the contract explicit.
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            selfInboxIdProvider: { _ in nil }
        )

        // Quadrant 1: first-message hook on never-synced (force=false). Pre-fix
        // this fell through both short-circuits and upserted every member,
        // including the local user, because the per-iteration self-skip guard
        // can't fire when self is nil.
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        var contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds.isEmpty, "Sync must no-op when self is unknown — no contacts should be written")
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false, "No marker should be written when self is unknown")

        // Seed a marker so the next call hits the (alreadySynced=true,
        // force=true) quadrant — the other path that was previously broken.
        try await dbManager.dbWriter.write { db in
            try DBConversationContactsSync(
                conversationId: conversationId,
                contactsSyncedAt: Date()
            ).save(db)
        }

        // Quadrant 2: member-added hook on already-synced. Pre-fix this fell
        // through both short-circuits the same way.
        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        contactIds = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds.isEmpty, "Forced sync must also no-op when self is unknown")
    }

    @Test("hasSyncedContacts mirrors marker presence")
    func testHasSyncedContacts() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false)
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
    }

    @Test("syncContacts skips the marker when only self is present so a later sync can retry")
    func testEmptyRosterDefersMarker() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        // Initial state: peer rows have not yet streamed in — only self is
        // a member. This mirrors the race we saw in the field where the
        // first-message hook fires before the StreamProcessor commits the
        // peer's `conversation_members` row.
        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        // No contacts and no marker — we deliberately deferred so the next
        // outbound message gets another chance.
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false)
        let count = try await dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)

        // Peer arrives.
        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: "alice").save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: "alice",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)
        }

        // Next sync (e.g. from the next outbound message) lands the contact
        // and writes the marker.
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
        let inboxIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(inboxIds == Set(["alice"]))
    }

    @Test("syncContacts posts a single `contactsWereAdded` notification covering the whole batch")
    func testSyncContactsPostsSingleBatchNotification() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-batch"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob", "carol"]
            )
        }

        // Private center so other suites posting on `.default` cannot leak in.
        let center = NotificationCenter()
        let recorder = SyncNotificationRecorder(name: .contactsWereAdded, center: center)

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            notificationCenter: center
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        // Wait for the main-queue dispatch from `postContactsWereAdded` to
        // land. Polling beats a fixed sleep because the dispatch latency
        // varies under CI load.
        try await waitUntil(timeout: .seconds(2)) {
            recorder.notifications.count >= 1
        }

        #expect(recorder.notifications.count == 1, "Batch sync must coalesce N inserts into one notification")
        let payload = recorder.notifications.first?.userInfo?["inboxIds"] as? [String] ?? []
        #expect(Set(payload) == Set(["alice", "bob", "carol"]))

        // Second sync is a no-op (already-synced) and must not re-fire. Use
        // a happens-after sentinel: post a marker on the same center after
        // the no-op call, wait for the sentinel, then assert no second
        // `contactsWereAdded` arrived. Polling for the absence of a
        // notification would be a race; the sentinel pattern is not.
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)
        try await flush(center: center)
        #expect(recorder.notifications.count == 1)

        recorder.stop()
    }

    @Test("syncContacts does not post `contactsWereAdded` when no new contact rows are inserted")
    func testSyncContactsDoesNotPostWhenNothingInserted() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-noop"

        // Pre-seed the conversation members as contacts so the coordinator's
        // upserts merge into existing rows rather than inserting new ones.
        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
            try DBContact(
                inboxId: "alice",
                addedAt: Date(timeIntervalSince1970: 1),
                addedViaConversationId: nil,
                displayName: "Alice",
                avatarURL: nil,
                avatarSalt: nil,
                avatarNonce: nil,
                avatarKey: nil,
                profileUpdatedAt: Date(timeIntervalSince1970: 1),
                agentVerification: nil
            ).save(db)
        }

        let center = NotificationCenter()
        let recorder = SyncNotificationRecorder(name: .contactsWereAdded, center: center)

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            notificationCenter: center
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        // Happens-after sentinel: any real `contactsWereAdded` post from the
        // sync above would have been dispatched to the main queue before
        // the sentinel post we make here, so once the sentinel arrives the
        // recorder has seen everything the sync could have produced.
        try await flush(center: center)

        #expect(recorder.notifications.isEmpty, "No new contact rows, so no sweep-trigger should fire")

        recorder.stop()
    }
}

/// Posts a sentinel notification on `center` and awaits its delivery on the
/// main queue. Use this in tests that need to assert "nothing happened":
/// because `postContactsWereAdded` dispatches to the main queue, any real
/// post made before this call lands on the queue before the sentinel.
private func flush(center: NotificationCenter) async throws {
    let sentinelName = Notification.Name("ContactSyncCoordinatorTests.Sentinel.\(UUID().uuidString)")
    let arrived = SentinelLatch()
    let token = center.addObserver(forName: sentinelName, object: nil, queue: nil) { _ in
        arrived.fire()
    }
    defer { center.removeObserver(token) }

    await MainActor.run {
        center.post(name: sentinelName, object: nil)
    }
    try await waitUntil(timeout: .seconds(2)) { arrived.didFire }
}

private final class SentinelLatch: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var _didFire: Bool = false

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didFire
    }

    func fire() {
        lock.lock()
        _didFire = true
        lock.unlock()
    }
}

/// Local copy of the recorder used by `ContactsWriterTests`. Kept private
/// to this file so each test file can opt into the helper without coupling
/// suites to a shared scaffolding module.
///
/// The recorder is bound to a specific `NotificationCenter` so callers can
/// scope it to a private center and avoid cross-suite leakage through
/// `.default`. The `lock`-guarded array makes concurrent appends safe when
/// the center delivers to its own queue.
private final class SyncNotificationRecorder: @unchecked Sendable {
    private let center: NotificationCenter
    private var _notifications: [Notification] = []
    private var token: NSObjectProtocol?
    private let lock: NSLock = NSLock()

    var notifications: [Notification] {
        lock.lock()
        defer { lock.unlock() }
        return _notifications
    }

    init(name: Notification.Name, center: NotificationCenter = .default) {
        self.center = center
        token = center.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            self.lock.lock()
            self._notifications.append(notification)
            self.lock.unlock()
        }
    }

    func stop() {
        if let token {
            center.removeObserver(token)
            self.token = nil
        }
    }

    deinit { stop() }
}
