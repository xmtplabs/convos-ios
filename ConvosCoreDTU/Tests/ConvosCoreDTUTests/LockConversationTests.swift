@testable import ConvosCore
import Foundation
import GRDB
import XCTest
@preconcurrency import XMTPiOS

/// Phase 2 batch 4: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/LockConversationTests.swift`.
///
/// Heavy-rewrite migration: the original suite leaned on
/// `fixtures.clientA as? Client` (raw XMTPiOS) plus direct
/// `group.rotateInviteTag()` / `group.updateAddMemberPermission(...)` /
/// `group.permissionPolicySet()` calls on `XMTPiOS.Group`. All of
/// those operations are now reachable via the abstraction:
///  - `MessagingGroup+CustomMetadata` exposes `rotateInviteTag()`,
///    `inviteTag()` (Stage 1 protocols extended with custom metadata).
///  - `MessagingGroup.updateAddMemberPermission(...)` and
///    `permissionPolicySet()` are on the core protocol.
///  - `MessagingGroup.isSuperAdmin(inboxId:)` and `members()` are on
///    the core protocol.
///
/// Two classes of tests split across the backends:
///  - **Pure-abstraction tests** (old-invites, rotation, unlock-join,
///    members-see-locked, stream-store consistency, permission level):
///    run on both backends.
///  - **ConversationMetadataWriter tests** (lock/unlock DB updates,
///    creator-super-admin cycle, DB member role cycle, throw-on-missing):
///    the writer depends on `InboxStateManager` → `InboxReadyResult` →
///    `any XMTPClientProvider`. On XMTPiOS the adapter's underlying
///    `XMTPiOS.Client` is itself an `XMTPClientProvider`, so these
///    remain green on the XMTPiOS lane. DTU has no `XMTPClientProvider`
///    conformer for its `MessagingClient`, so these are skipped on
///    DTU (scope would creep into Stage 6 / `XMTPClientProvider`
///    retirement to migrate further).
///
/// Test count: 11. XMTPiOS runs all 11; DTU runs the 6 abstraction
/// tests that don't transit the writer.
// swiftlint:disable:next type_body_length
final class LockConversationTests: XCTestCase {
    // MARK: - Lifecycle

    private var fixtures: DualBackendTestFixtures?

    override func tearDown() async throws {
        if let fixtures {
            try? await fixtures.cleanup()
            self.fixtures = nil
        }
        try await super.tearDown()
    }

    override class func tearDown() {
        Task {
            await DualBackendTestFixtures.tearDownSharedDTUIfNeeded()
        }
        super.tearDown()
    }

    /// XMTPiOS backend requires the Docker-backed XMTP node.
    private func guardBackendReady(_ backend: DualBackendTestFixtures.Backend) throws {
        if backend == .xmtpiOS,
           ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] == nil {
            throw XCTSkip(
                "CONVOS_MESSAGING_BACKEND=\(backend.rawValue) (default) and "
                    + "XMTP_NODE_ADDRESS is unset; skipping to avoid a network-"
                    + "dependent failure. Start the XMTP Docker stack or set "
                    + "CONVOS_MESSAGING_BACKEND=dtu."
            )
        }
    }

    /// Returns the underlying `XMTPClientProvider` for the ConversationMetadataWriter
    /// tests, or skips if we're on DTU (which has no XMTPClientProvider conformer).
    private func xmtpClientOrSkip(
        _ client: any MessagingClient,
        backend: DualBackendTestFixtures.Backend
    ) throws -> any XMTPClientProvider {
        guard let xmtpiosClient = (client as? XMTPiOSMessagingClient)?.xmtpClient else {
            throw XCTSkip(
                "[\(backend.rawValue)] ConversationMetadataWriter tests require an "
                    + "XMTPClientProvider; only the XMTPiOS adapter conforms today. "
                    + "DTU equivalent tracks Stage 6 / XMTPClientProvider retirement."
            )
        }
        return xmtpiosClient
    }

    // MARK: - Integration Tests (Pure-abstraction; run on both lanes)

    func testOldInvitesCannotBeUsedAfterLocking() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)
        // DTU now enforces the add-member permission policy at commit time
        // (matches libxmtp's `evaluate_commit` → `InsufficientPermissions`
        // rejection). `addMembers(...)` under an `add_member_policy: deny`
        // policy surfaces `DTUError.permissionDenied`, bubbled up as a
        // throw from the abstraction layer — same shape as XMTPiOS's
        // `GroupError::NotAuthorized`.

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-old-invite"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Seed an invite tag first — both lanes expose this via
        // MessagingGroup+CustomMetadata; DTU's single-writer flow is
        // known-green.
        try await group.ensureInviteTag()
        let originalInviteTag = try await group.inviteTag()

        try await group.updateAddMemberPermission(.deny)
        try await group.rotateInviteTag()
        try await group.sync()

        let newInviteTag = try await group.inviteTag()
        XCTAssertNotEqual(
            newInviteTag,
            originalInviteTag,
            "[\(backend.rawValue)] invite tag should change after rotation"
        )

        let permissionPolicy = try await group.permissionPolicySet()
        XCTAssertEqual(
            permissionPolicy.addMemberPolicy,
            .deny,
            "[\(backend.rawValue)] add-member policy should be deny after locking"
        )

        var addMemberFailed = false
        do {
            try await group.addMembers(inboxIds: [bob.inboxAlias])
        } catch {
            addMemberFailed = true
        }
        XCTAssertTrue(
            addMemberFailed,
            "[\(backend.rawValue)] adding members to a locked group should fail"
        )

        let members = try await group.members()
        let memberInboxIds = members.map { $0.inboxId }
        XCTAssertFalse(
            memberInboxIds.contains(bob.inboxAlias),
            "[\(backend.rawValue)] Bob should not be a member of the locked group"
        )
    }

    func testGroupCanBeUnlockedAndMembersCanJoin() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-unlock-join"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        try await group.updateAddMemberPermission(.deny)
        try await group.sync()

        var permissionPolicy = try await group.permissionPolicySet()
        XCTAssertEqual(
            permissionPolicy.addMemberPolicy,
            .deny,
            "[\(backend.rawValue)] group should be locked"
        )

        try await group.updateAddMemberPermission(.allow)
        try await group.sync()

        permissionPolicy = try await group.permissionPolicySet()
        XCTAssertEqual(
            permissionPolicy.addMemberPolicy,
            .allow,
            "[\(backend.rawValue)] group should be unlocked"
        )

        try await group.addMembers(inboxIds: [bob.inboxAlias])
        try await group.sync()

        let members = try await group.members()
        let memberInboxIds = members.map { $0.inboxId }
        XCTAssertTrue(
            memberInboxIds.contains(bob.inboxAlias),
            "[\(backend.rawValue)] Bob should be a member after unlocking"
        )
    }

    func testInviteTagRotation() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-rotate-tag"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        try await group.ensureInviteTag()
        let originalTag = try await group.inviteTag()

        try await group.rotateInviteTag()
        try await group.sync()

        let newTag = try await group.inviteTag()
        XCTAssertNotEqual(
            newTag,
            originalTag,
            "[\(backend.rawValue)] invite tag should change after rotation"
        )
    }

    func testMembersSeeLockedState() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-members-see"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        try await bob.client.conversations.sync()

        try await group.updateAddMemberPermission(.deny)
        try await group.sync()

        try await bob.client.conversations.sync()

        let bobConversations = try await bob.client.conversations.list(
            query: MessagingConversationQuery(orderBy: .lastActivity)
        )
        let bobGroupConvo = try XCTUnwrap(
            bobConversations.first { $0.id == group.id },
            "[\(backend.rawValue)] Bob should see the group"
        )
        guard case .group(let bobGroup) = bobGroupConvo else {
            XCTFail("[\(backend.rawValue)] expected group conversation for bob")
            return
        }
        try await bobGroup.sync()

        let permissionPolicy = try await bobGroup.permissionPolicySet()
        XCTAssertEqual(
            permissionPolicy.addMemberPolicy,
            .deny,
            "[\(backend.rawValue)] Bob should see the group as locked"
        )
    }

    // MARK: - ConversationWriter integration (pure-abstraction)

    func testMemberRoleRemainsSuperAdminAfterConversationWriterStore() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)
        // DTU now models admin / super-admin roles on the member surface
        // (`DTUMessagingGroup.members()` maps the engine's `role` onto
        // `MessagingMemberRole` 1:1). `ConversationWriter.store(...)` is
        // pure-abstraction (takes `MessagingGroup.members()` via
        // `dbRepresentation(conversationId:)`), so the lock-cycle
        // assertions now light up on both backends.

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-writer-role"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let clientId = alice.clientId
        let inboxId = alice.inboxAlias
        let conversationId = group.id

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            ).insert(db)
        }

        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: DualBackendMockIncomingMessageWriter()
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        var dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] initial DB member role should be superAdmin"
        )

        let initialIsSuperAdmin = try await group.isSuperAdmin(inboxId: inboxId)
        XCTAssertTrue(
            initialIsSuperAdmin,
            "[\(backend.rawValue)] XMTP should report user as superAdmin initially"
        )

        // Lock
        try await group.updateAddMemberPermission(.deny)
        try await group.rotateInviteTag()
        try await group.sync()

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] DB member role should still be superAdmin after lock + store"
        )

        let afterLockIsSuperAdmin = try await group.isSuperAdmin(inboxId: inboxId)
        XCTAssertTrue(
            afterLockIsSuperAdmin,
            "[\(backend.rawValue)] XMTP should report user as superAdmin after lock"
        )

        // Unlock
        try await group.rotateInviteTag()
        try await group.updateAddMemberPermission(.allow)
        try await group.sync()

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] DB member role should still be superAdmin after unlock + store"
        )

        let afterUnlockIsSuperAdmin = try await group.isSuperAdmin(inboxId: inboxId)
        XCTAssertTrue(
            afterUnlockIsSuperAdmin,
            "[\(backend.rawValue)] XMTP should report user as superAdmin after unlock"
        )

        // Lock again
        try await group.updateAddMemberPermission(.deny)
        try await group.rotateInviteTag()
        try await group.sync()

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] DB member role should still be superAdmin after second lock + store"
        )

        let canToggleLock = dbMember?.role == .superAdmin
        XCTAssertTrue(
            canToggleLock,
            "[\(backend.rawValue)] user should still be able to toggle lock (isCurrentUserSuperAdmin)"
        )
    }

    func testXMTPPermissionLevelConsistency() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)
        // DTU's `list_members` now carries `{inboxId, role}` per member —
        // the engine resolves the role against its tracked admin /
        // super-admin sets. `group.isSuperAdmin` (via `listSuperAdmins`)
        // and `group.members().role` now agree on both backends.

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-perm-level"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let inboxId = alice.inboxAlias

        // Initial consistency
        var members = try await group.members()
        var creatorMember = members.first { $0.inboxId == inboxId }
        var memberRole = creatorMember?.role
        var isSuperAdminMethod = try await group.isSuperAdmin(inboxId: inboxId)

        XCTAssertEqual(
            memberRole,
            .superAdmin,
            "[\(backend.rawValue)] initial member role should be superAdmin"
        )
        XCTAssertTrue(
            isSuperAdminMethod,
            "[\(backend.rawValue)] initial group.isSuperAdmin should be true"
        )

        // Lock
        try await group.updateAddMemberPermission(.deny)
        try await group.rotateInviteTag()
        try await group.sync()

        members = try await group.members()
        creatorMember = members.first { $0.inboxId == inboxId }
        memberRole = creatorMember?.role
        isSuperAdminMethod = try await group.isSuperAdmin(inboxId: inboxId)

        XCTAssertEqual(
            memberRole,
            .superAdmin,
            "[\(backend.rawValue)] after lock: member role should be superAdmin"
        )
        XCTAssertTrue(
            isSuperAdminMethod,
            "[\(backend.rawValue)] after lock: group.isSuperAdmin should be true"
        )

        // Unlock
        try await group.rotateInviteTag()
        try await group.updateAddMemberPermission(.allow)
        try await group.sync()

        members = try await group.members()
        creatorMember = members.first { $0.inboxId == inboxId }
        memberRole = creatorMember?.role
        isSuperAdminMethod = try await group.isSuperAdmin(inboxId: inboxId)

        XCTAssertEqual(
            memberRole,
            .superAdmin,
            "[\(backend.rawValue)] after unlock: member role should be superAdmin"
        )
        XCTAssertTrue(
            isSuperAdminMethod,
            "[\(backend.rawValue)] after unlock: group.isSuperAdmin should be true"
        )

        // Second lock
        try await group.updateAddMemberPermission(.deny)
        try await group.rotateInviteTag()
        try await group.sync()

        members = try await group.members()
        creatorMember = members.first { $0.inboxId == inboxId }
        memberRole = creatorMember?.role
        isSuperAdminMethod = try await group.isSuperAdmin(inboxId: inboxId)

        XCTAssertEqual(
            memberRole,
            .superAdmin,
            "[\(backend.rawValue)] after second lock: member role should be superAdmin"
        )
        XCTAssertTrue(
            isSuperAdminMethod,
            "[\(backend.rawValue)] after second lock: group.isSuperAdmin should be true"
        )
    }

    // MARK: - ConversationMetadataWriter Unit Tests (XMTPiOS only)

    func testLockConversationUpdatesDatabase() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-metadata-lock-db"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let xmtpClientProvider = try xmtpClientOrSkip(alice.client, backend: backend)

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        try await group.ensureInviteTag()
        let originalInviteTag = try await group.inviteTag()

        let clientId = alice.clientId
        let inboxId = alice.inboxAlias
        let conversationId = group.id

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            ).insert(db)

            try DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: conversationId,
                inviteTag: originalInviteTag,
                creatorId: inboxId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test Group",
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
                hasHadVerifiedAssistant: false
            ).insert(db)
        }

        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: xmtpClientProvider, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: xmtpClientProvider,
            mockAPIClient: mockAPIClient
        )

        let mockInviteWriter = MockInviteWriter()

        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixture.databaseManager.dbWriter
        )

        try await metadataWriter.lockConversation(for: conversationId)

        let updatedConversation = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }

        XCTAssertNotNil(updatedConversation, "[\(backend.rawValue)] conversation should exist")
        XCTAssertEqual(updatedConversation?.isLocked, true, "[\(backend.rawValue)] should be locked")
        XCTAssertNotEqual(
            updatedConversation?.inviteTag,
            originalInviteTag,
            "[\(backend.rawValue)] invite tag should have changed"
        )

        let generatedForConversation = mockInviteWriter.generatedInvites.contains {
            $0.conversation.id == conversationId
        }
        XCTAssertTrue(
            generatedForConversation,
            "[\(backend.rawValue)] invite should be regenerated after lock"
        )
    }

    func testUnlockConversationUpdatesDatabase() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-metadata-unlock-db"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let xmtpClientProvider = try xmtpClientOrSkip(alice.client, backend: backend)

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        try await group.updateAddMemberPermission(.deny)
        try await group.sync()

        let clientId = alice.clientId
        let inboxId = alice.inboxAlias
        let conversationId = group.id
        try await group.ensureInviteTag()
        let inviteTag = try await group.inviteTag()

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            ).insert(db)

            try DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: conversationId,
                inviteTag: inviteTag,
                creatorId: inboxId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test Group",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: true,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                conversationEmoji: nil,
                imageLastRenewed: nil,
                isUnused: false,
                hasHadVerifiedAssistant: false
            ).insert(db)
        }

        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: xmtpClientProvider, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: xmtpClientProvider,
            mockAPIClient: mockAPIClient
        )

        let mockInviteWriter = MockInviteWriter()
        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixture.databaseManager.dbWriter
        )

        try await metadataWriter.unlockConversation(for: conversationId)

        let updatedConversation = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }

        XCTAssertNotNil(updatedConversation, "[\(backend.rawValue)] conversation should exist")
        XCTAssertEqual(
            updatedConversation?.isLocked,
            false,
            "[\(backend.rawValue)] conversation should be marked as unlocked"
        )
    }

    func testLockConversationThrowsForMissingConversation() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-metadata-missing"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let xmtpClientProvider = try xmtpClientOrSkip(alice.client, backend: backend)
        let clientId = alice.clientId

        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: xmtpClientProvider, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: xmtpClientProvider,
            mockAPIClient: mockAPIClient
        )

        let mockInviteWriter = MockInviteWriter()
        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixture.databaseManager.dbWriter
        )

        do {
            try await metadataWriter.lockConversation(for: "non-existent-conversation-id")
            XCTFail("[\(backend.rawValue)] expected ConversationMetadataError but got success")
        } catch is ConversationMetadataError {
            // expected
        }
    }

    // MARK: - Super Admin Retention Tests

    func testCreatorRemainsSuperAdminAfterLockUnlockCycle() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-super-admin-cycle"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let xmtpClientProvider = try xmtpClientOrSkip(alice.client, backend: backend)

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let clientId = alice.clientId
        let inboxId = alice.inboxAlias
        let conversationId = group.id
        try await group.ensureInviteTag()
        let originalInviteTag = try await group.inviteTag()

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            ).insert(db)

            try DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: conversationId,
                inviteTag: originalInviteTag,
                creatorId: inboxId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test Group",
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
                hasHadVerifiedAssistant: false
            ).insert(db)
        }

        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: xmtpClientProvider, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: xmtpClientProvider,
            mockAPIClient: mockAPIClient
        )
        let mockInviteWriter = MockInviteWriter()

        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixture.databaseManager.dbWriter
        )

        let initialIsSuperAdmin = try await group.isSuperAdmin(inboxId: inboxId)
        XCTAssertTrue(initialIsSuperAdmin, "[\(backend.rawValue)] creator should be superAdmin initially")

        try await metadataWriter.lockConversation(for: conversationId)
        try await group.sync()

        let afterLockIsSuperAdmin = try await group.isSuperAdmin(inboxId: inboxId)
        XCTAssertTrue(afterLockIsSuperAdmin, "[\(backend.rawValue)] creator should still be superAdmin after lock")

        var dbConversation = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }
        XCTAssertEqual(dbConversation?.isLocked, true, "[\(backend.rawValue)] should be locked in DB")

        try await Task.sleep(for: .seconds(1))

        try await metadataWriter.unlockConversation(for: conversationId)
        try await group.sync()

        let afterUnlockIsSuperAdmin = try await group.isSuperAdmin(inboxId: inboxId)
        XCTAssertTrue(afterUnlockIsSuperAdmin, "[\(backend.rawValue)] creator should still be superAdmin after unlock")

        dbConversation = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }
        XCTAssertEqual(dbConversation?.isLocked, false, "[\(backend.rawValue)] should be unlocked in DB")

        try await metadataWriter.lockConversation(for: conversationId)
        try await group.sync()

        let permissionPolicy = try await group.permissionPolicySet()
        XCTAssertEqual(
            permissionPolicy.addMemberPolicy,
            .deny,
            "[\(backend.rawValue)] should be able to lock the group again"
        )

        let afterSecondLockIsSuperAdmin = try await group.isSuperAdmin(inboxId: inboxId)
        XCTAssertTrue(
            afterSecondLockIsSuperAdmin,
            "[\(backend.rawValue)] creator should still be superAdmin after second lock"
        )

        let generatedCount = mockInviteWriter.generatedInvites.filter {
            $0.conversation.id == conversationId
        }.count
        XCTAssertEqual(
            generatedCount,
            3,
            "[\(backend.rawValue)] invite should be regenerated for lock, unlock, and second lock"
        )
    }

    func testDBMemberRoleRemainsSuperAdminAfterLockUnlockCycle() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "lock-db-member-cycle"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let xmtpClientProvider = try xmtpClientOrSkip(alice.client, backend: backend)

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let clientId = alice.clientId
        let inboxId = alice.inboxAlias
        let conversationId = group.id
        try await group.ensureInviteTag()
        let originalInviteTag = try await group.inviteTag()

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            ).insert(db)

            try DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: conversationId,
                inviteTag: originalInviteTag,
                creatorId: inboxId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test Group",
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
                hasHadVerifiedAssistant: false
            ).insert(db)

            try DBMember(inboxId: inboxId).insert(db)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
        }

        var dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] DB member role should be superAdmin initially"
        )

        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: xmtpClientProvider, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: xmtpClientProvider,
            mockAPIClient: mockAPIClient
        )
        let mockInviteWriter = MockInviteWriter()

        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixture.databaseManager.dbWriter
        )

        try await metadataWriter.lockConversation(for: conversationId)

        dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] DB member role should still be superAdmin after lock"
        )

        try await Task.sleep(for: .seconds(1))

        try await metadataWriter.unlockConversation(for: conversationId)

        dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] DB member role should still be superAdmin after unlock"
        )

        try await metadataWriter.lockConversation(for: conversationId)

        dbMember = try await fixture.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        XCTAssertEqual(
            dbMember?.role,
            .superAdmin,
            "[\(backend.rawValue)] DB member role should still be superAdmin after second lock"
        )
    }
}

// MARK: - Mock Invite Writer

private final class MockInviteWriter: InviteWriterProtocol, @unchecked Sendable {
    struct GeneratedInvite {
        let conversation: DBConversation
        let expiresAt: Date?
        let expiresAfterUse: Bool
    }

    struct UpdatedInvite {
        let conversationId: String
        let name: String?
        let description: String?
        let imageURL: String?
    }

    var generatedInvites: [GeneratedInvite] = []
    var updatedInvites: [UpdatedInvite] = []
    var deletedConversationIds: [String] = []

    func generate(for conversation: DBConversation, expiresAt: Date?, expiresAfterUse: Bool) async throws -> Invite {
        generatedInvites.append(
            GeneratedInvite(conversation: conversation, expiresAt: expiresAt, expiresAfterUse: expiresAfterUse)
        )
        return Invite(
            conversationId: conversation.id,
            urlSlug: "mock-invite-slug",
            expiresAt: expiresAt,
            expiresAfterUse: expiresAfterUse
        )
    }

    func update(for conversationId: String, name: String?, description: String?, imageURL: String?) async throws -> Invite {
        updatedInvites.append(
            UpdatedInvite(conversationId: conversationId, name: name, description: description, imageURL: imageURL)
        )
        return Invite(
            conversationId: conversationId,
            urlSlug: "mock-updated-slug",
            expiresAt: nil,
            expiresAfterUse: false
        )
    }

    func delete(for conversationId: String) async throws {
        deletedConversationIds.append(conversationId)
    }
}
