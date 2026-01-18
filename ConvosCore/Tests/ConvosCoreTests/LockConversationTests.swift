@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

@Suite("Lock Conversation Tests", .serialized)
struct LockConversationTests {

    // MARK: - Integration Tests (Real XMTP)

    @Test("Old invites cannot be used after group is locked")
    func testOldInvitesCannotBeUsedAfterLocking() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB else {
            throw TestError.missingClients
        }

        // Client A creates a group
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Store the original invite tag before locking
        let originalInviteTag = try group.inviteTag

        // Lock the group - this sets addMemberPermission to .deny and rotates the invite tag
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.rotateInviteTag()

        // Sync the group to ensure changes are propagated
        try await group.sync()

        // Verify the invite tag was rotated
        let newInviteTag = try group.inviteTag
        #expect(newInviteTag != originalInviteTag, "Invite tag should change after rotation")

        // Verify add member permission is now deny
        let permissionPolicy = try group.permissionPolicySet()
        #expect(permissionPolicy.addMemberPolicy == .deny, "Add member policy should be deny after locking")

        // Client B attempts to be added to the locked group - should fail
        var addMemberFailed = false
        do {
            _ = try await group.addMembers(inboxIds: [clientB.inboxId])
        } catch {
            addMemberFailed = true
        }
        #expect(addMemberFailed, "Adding members to a locked group should fail")

        // Verify client B was not added
        let members = try await group.members
        let memberInboxIds = members.map { $0.inboxId }
        #expect(!memberInboxIds.contains(clientB.inboxId), "Client B should not be a member of the locked group")

        try? await fixtures.cleanup()
    }

    @Test("Group can be unlocked and members can join again")
    func testGroupCanBeUnlockedAndMembersCanJoin() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB else {
            throw TestError.missingClients
        }

        // Client A creates a group
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Lock the group
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.sync()

        // Verify it's locked
        var permissionPolicy = try group.permissionPolicySet()
        #expect(permissionPolicy.addMemberPolicy == .deny, "Group should be locked")

        // Unlock the group
        try await group.updateAddMemberPermission(newPermissionOption: .allow)
        try await group.sync()

        // Verify it's unlocked
        permissionPolicy = try group.permissionPolicySet()
        #expect(permissionPolicy.addMemberPolicy == .allow, "Group should be unlocked")

        // Now client B can be added
        _ = try await group.addMembers(inboxIds: [clientB.inboxId])
        try await group.sync()

        // Verify client B was added
        let members = try await group.members
        let memberInboxIds = members.map { $0.inboxId }
        #expect(memberInboxIds.contains(clientB.inboxId), "Client B should be a member after unlocking")

        try? await fixtures.cleanup()
    }

    @Test("Invite tag rotation changes the tag")
    func testInviteTagRotation() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client else {
            throw TestError.missingClients
        }

        // Create a group
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Get original tag before any operations (following pattern from first test)
        let originalTag = try group.inviteTag

        // Rotate the invite tag
        try await group.rotateInviteTag()
        try await group.sync()

        let newTag = try group.inviteTag
        #expect(newTag != originalTag, "Invite tag should change after rotation")

        try? await fixtures.cleanup()
    }

    // MARK: - ConversationMetadataWriter Unit Tests

    @Test("Lock conversation updates database with isLocked true and new inviteTag")
    func testLockConversationUpdatesDatabase() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client else {
            throw TestError.missingClients
        }

        // Create a group
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let originalInviteTag = try group.inviteTag

        // Create DB records
        let clientId = fixtures.clientIdA ?? "test-client"
        let inboxId = clientA.inboxId
        let conversationId = group.id

        try await fixtures.databaseManager.dbWriter.write { db in
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
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: false
            ).insert(db)
        }

        // Create mock inbox state manager that returns the real client
        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: clientA, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: clientA,
            mockAPIClient: mockAPIClient
        )

        // Create mock invite writer to track regeneration
        let mockInviteWriter = MockInviteWriter()

        // Create the metadata writer
        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        // Lock the conversation
        try await metadataWriter.lockConversation(for: conversationId)

        // Verify database was updated
        let updatedConversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }

        #expect(updatedConversation != nil, "Conversation should exist")
        #expect(updatedConversation?.isLocked == true, "Conversation should be marked as locked")
        #expect(updatedConversation?.inviteTag != originalInviteTag, "Invite tag should have changed")

        // Verify invite was regenerated
        #expect(mockInviteWriter.regeneratedConversationIds.contains(conversationId), "Invite should be regenerated")

        try? await fixtures.cleanup()
    }

    @Test("Unlock conversation updates database with isLocked false")
    func testUnlockConversationUpdatesDatabase() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client else {
            throw TestError.missingClients
        }

        // Create a group
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Lock the group first
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.sync()

        let clientId = fixtures.clientIdA ?? "test-client"
        let inboxId = clientA.inboxId
        let conversationId = group.id
        let inviteTag = try group.inviteTag

        // Create DB records with isLocked = true
        try await fixtures.databaseManager.dbWriter.write { db in
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
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: true
            ).insert(db)
        }

        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: clientA, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: clientA,
            mockAPIClient: mockAPIClient
        )

        let mockInviteWriter = MockInviteWriter()

        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        // Unlock the conversation
        try await metadataWriter.unlockConversation(for: conversationId)

        // Verify database was updated
        let updatedConversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }

        #expect(updatedConversation != nil, "Conversation should exist")
        #expect(updatedConversation?.isLocked == false, "Conversation should be marked as unlocked")

        try? await fixtures.cleanup()
    }

    @Test("Lock conversation throws error for non-existent conversation")
    func testLockConversationThrowsForMissingConversation() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA else {
            throw TestError.missingClients
        }

        let clientId = fixtures.clientIdA ?? "test-client"

        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: clientA, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: clientA,
            mockAPIClient: mockAPIClient
        )

        let mockInviteWriter = MockInviteWriter()

        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        await #expect(throws: ConversationMetadataError.self) {
            try await metadataWriter.lockConversation(for: "non-existent-conversation-id")
        }

        try? await fixtures.cleanup()
    }

    // MARK: - Member Sync Tests

    @Test("Members syncing a locked group see isLocked state")
    func testMembersSeeLockedState() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        // Client A creates a group with client B
        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Sync client B to receive the group
        try await clientB.conversations.sync()

        // Lock the group as client A
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.sync()

        // Sync client B and get their view of the group
        try await clientB.conversations.sync()
        guard let clientBGroup = try clientB.conversations.listGroups(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityAfterNs: nil,
            lastActivityBeforeNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .lastActivity
        ).first(where: { $0.id == group.id }) else {
            throw TestError.groupNotFound
        }

        try await clientBGroup.sync()

        // Verify client B sees the locked state
        let permissionPolicy = try clientBGroup.permissionPolicySet()
        #expect(permissionPolicy.addMemberPolicy == .deny, "Client B should see the group as locked")

        try? await fixtures.cleanup()
    }

    // MARK: - Super Admin Retention Tests

    @Test("Creator remains superAdmin after lock/unlock cycle using ConversationMetadataWriter")
    func testCreatorRemainsSuperAdminAfterLockUnlockCycle() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client else {
            throw TestError.missingClients
        }

        // Client A creates a group (becomes superAdmin)
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let clientId = fixtures.clientIdA ?? "test-client"
        let inboxId = clientA.inboxId
        let conversationId = group.id
        let originalInviteTag = try group.inviteTag

        // Create DB records
        try await fixtures.databaseManager.dbWriter.write { db in
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
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: false
            ).insert(db)
        }

        // Create mock dependencies
        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: clientA, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: clientA,
            mockAPIClient: mockAPIClient
        )
        let mockInviteWriter = MockInviteWriter()

        // Create the metadata writer (the actual component we're testing)
        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        // Verify initial superAdmin status
        let initialIsSuperAdmin = try group.isSuperAdmin(inboxId: clientA.inboxId)
        #expect(initialIsSuperAdmin, "Creator should be superAdmin initially")

        // Lock the conversation using the actual writer
        try await metadataWriter.lockConversation(for: conversationId)
        try await group.sync()

        // Verify still superAdmin after locking
        let afterLockIsSuperAdmin = try group.isSuperAdmin(inboxId: clientA.inboxId)
        #expect(afterLockIsSuperAdmin, "Creator should still be superAdmin after locking")

        // Verify locked state in DB
        var dbConversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }
        #expect(dbConversation?.isLocked == true, "Conversation should be locked in DB")

        // Wait a moment (simulating real-world delay)
        try await Task.sleep(for: .seconds(1))

        // Unlock the conversation using the actual writer
        try await metadataWriter.unlockConversation(for: conversationId)
        try await group.sync()

        // Verify still superAdmin after unlocking
        let afterUnlockIsSuperAdmin = try group.isSuperAdmin(inboxId: clientA.inboxId)
        #expect(afterUnlockIsSuperAdmin, "Creator should still be superAdmin after unlocking")

        // Verify unlocked state in DB
        dbConversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: conversationId)
        }
        #expect(dbConversation?.isLocked == false, "Conversation should be unlocked in DB")

        // Verify can lock again using the actual writer
        try await metadataWriter.lockConversation(for: conversationId)
        try await group.sync()

        let permissionPolicy = try group.permissionPolicySet()
        #expect(permissionPolicy.addMemberPolicy == .deny, "Should be able to lock the group again")

        // Verify still superAdmin after second lock
        let afterSecondLockIsSuperAdmin = try group.isSuperAdmin(inboxId: clientA.inboxId)
        #expect(afterSecondLockIsSuperAdmin, "Creator should still be superAdmin after second lock")

        // Verify invite was regenerated for both lock operations and the unlock
        #expect(mockInviteWriter.regeneratedConversationIds.count == 3, "Invite should be regenerated for lock, unlock, and second lock")

        try? await fixtures.cleanup()
    }

    @Test("DBConversationMember.role remains superAdmin in local database after lock/unlock cycle")
    func testDBMemberRoleRemainsSuperAdminAfterLockUnlockCycle() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client else {
            throw TestError.missingClients
        }

        // Client A creates a group (becomes superAdmin)
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let clientId = fixtures.clientIdA ?? "test-client"
        let inboxId = clientA.inboxId
        let conversationId = group.id
        let originalInviteTag = try group.inviteTag

        // Create DB records including the member with superAdmin role
        try await fixtures.databaseManager.dbWriter.write { db in
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
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: false
            ).insert(db)

            // Create the member record with superAdmin role (this is what the UI reads)
            try DBMember(inboxId: inboxId).insert(db)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date()
            ).insert(db)
        }

        // Verify initial DB member role is superAdmin
        var dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        #expect(dbMember?.role == .superAdmin, "DB member role should be superAdmin initially")

        // Create mock dependencies
        let mockAPIClient = MockAPIClient()
        let readyResult = InboxReadyResult(client: clientA, apiClient: mockAPIClient)
        let mockInboxStateManager = MockInboxStateManager(
            initialState: .ready(clientId: clientId, result: readyResult),
            mockClient: clientA,
            mockAPIClient: mockAPIClient
        )
        let mockInviteWriter = MockInviteWriter()

        let metadataWriter = ConversationMetadataWriter(
            inboxStateManager: mockInboxStateManager,
            inviteWriter: mockInviteWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        // Lock the conversation
        try await metadataWriter.lockConversation(for: conversationId)

        // Verify DB member role is still superAdmin after locking
        dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        #expect(dbMember?.role == .superAdmin, "DB member role should still be superAdmin after locking")

        // Wait a moment
        try await Task.sleep(for: .seconds(1))

        // Unlock the conversation
        try await metadataWriter.unlockConversation(for: conversationId)

        // Verify DB member role is still superAdmin after unlocking
        // Lock/unlock only changes the addMember permission policy, not member roles
        dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        #expect(dbMember?.role == .superAdmin, "DB member role should still be superAdmin after unlocking")

        // Lock again
        try await metadataWriter.lockConversation(for: conversationId)

        // Verify DB member role is still superAdmin after second lock
        dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        #expect(dbMember?.role == .superAdmin, "DB member role should still be superAdmin after second lock")

        try? await fixtures.cleanup()
    }

    // MARK: - ConversationWriter Integration Tests

    @Test("Member role remains superAdmin after ConversationWriter.store() called during lock/unlock cycle")
    func testMemberRoleRemainsSuperAdminAfterConversationWriterStore() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client else {
            throw TestError.missingClients
        }

        // Client A creates a group (becomes superAdmin)
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let clientId = fixtures.clientIdA ?? "test-client"
        let inboxId = clientA.inboxId
        let conversationId = group.id

        // Create DB inbox record (required for ConversationWriter)
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            ).insert(db)
        }

        // Create the ConversationWriter (same component used in the app)
        // Use fixtures.identityStore which has the identity saved from createTestClients()
        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        // Check what XMTP reports BEFORE store
        let preStoreMembers = try await group.members
        let preStoreCreator = preStoreMembers.first(where: { $0.inboxId == inboxId })
        let preStorePermissionLevel = preStoreCreator?.permissionLevel
        print("PRE-STORE: XMTP member.permissionLevel = \(String(describing: preStorePermissionLevel))")
        print("PRE-STORE: group.isSuperAdmin = \(try group.isSuperAdmin(inboxId: inboxId))")

        // Initial store - this should create the member with superAdmin role
        let dbConversation = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        // Check what XMTP reports AFTER store
        let postStoreMembers = try await group.members
        let postStoreCreator = postStoreMembers.first(where: { $0.inboxId == inboxId })
        let postStorePermissionLevel = postStoreCreator?.permissionLevel
        print("POST-STORE: XMTP member.permissionLevel = \(String(describing: postStorePermissionLevel))")
        print("POST-STORE: group.isSuperAdmin = \(try group.isSuperAdmin(inboxId: inboxId))")

        // Verify initial member role is superAdmin
        var allMembers = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember.fetchAll(db)
        }
        print("ALL DB MEMBERS: \(allMembers.map { "conv=\($0.conversationId), inbox=\($0.inboxId), role=\($0.role)" })")
        print("LOOKING FOR: conversationId=\(conversationId), inboxId=\(inboxId)")

        var dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        print("DB MEMBER: role = \(String(describing: dbMember?.role))")
        #expect(dbMember?.role == .superAdmin, "Initial DB member role should be superAdmin")

        // Verify XMTP says we're superAdmin
        let initialIsSuperAdmin = try group.isSuperAdmin(inboxId: inboxId)
        #expect(initialIsSuperAdmin, "XMTP should report user as superAdmin initially")

        // Lock the group
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.rotateInviteTag()
        try await group.sync()

        // Simulate what happens when GroupUpdated message is streamed:
        // StreamProcessor calls conversationWriter.store()
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        // Verify member role is still superAdmin after lock + store
        dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        #expect(dbMember?.role == .superAdmin, "DB member role should still be superAdmin after lock + store")

        // Verify XMTP still says we're superAdmin
        let afterLockIsSuperAdmin = try group.isSuperAdmin(inboxId: inboxId)
        #expect(afterLockIsSuperAdmin, "XMTP should report user as superAdmin after lock")

        // Unlock the group
        try await group.rotateInviteTag()
        try await group.updateAddMemberPermission(newPermissionOption: .allow)
        try await group.sync()

        // Simulate stream processing again
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        // Verify member role is still superAdmin after unlock + store
        dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        #expect(dbMember?.role == .superAdmin, "DB member role should still be superAdmin after unlock + store")

        // Verify XMTP still says we're superAdmin
        let afterUnlockIsSuperAdmin = try group.isSuperAdmin(inboxId: inboxId)
        #expect(afterUnlockIsSuperAdmin, "XMTP should report user as superAdmin after unlock")

        // Lock again
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.rotateInviteTag()
        try await group.sync()

        // Simulate stream processing
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxId
        )

        // Verify member role is still superAdmin after second lock + store
        dbMember = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        #expect(dbMember?.role == .superAdmin, "DB member role should still be superAdmin after second lock + store")

        // This is the key assertion - can the UI still show the lock toggle as enabled?
        // In the app: viewModel.isCurrentUserSuperAdmin checks currentUserMember?.role == .superAdmin
        let canToggleLock = dbMember?.role == .superAdmin
        #expect(canToggleLock, "User should still be able to toggle lock (isCurrentUserSuperAdmin)")

        try? await fixtures.cleanup()
    }

    @Test("XMTP member.permissionLevel matches group.isSuperAdmin after lock/unlock")
    func testXMTPPermissionLevelConsistency() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client else {
            throw TestError.missingClients
        }

        // Client A creates a group
        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let inboxId = clientA.inboxId

        // Check initial consistency
        var members = try await group.members
        var creatorMember = members.first(where: { $0.inboxId == inboxId })
        var memberPermissionLevel = creatorMember?.permissionLevel
        var isSuperAdminMethod = try group.isSuperAdmin(inboxId: inboxId)

        #expect(memberPermissionLevel == .SuperAdmin, "Initial member.permissionLevel should be SuperAdmin")
        #expect(isSuperAdminMethod, "Initial group.isSuperAdmin should be true")

        // Lock the group
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.rotateInviteTag()
        try await group.sync()

        // Check consistency after lock
        members = try await group.members
        creatorMember = members.first(where: { $0.inboxId == inboxId })
        memberPermissionLevel = creatorMember?.permissionLevel
        isSuperAdminMethod = try group.isSuperAdmin(inboxId: inboxId)

        #expect(memberPermissionLevel == .SuperAdmin, "After lock: member.permissionLevel should be SuperAdmin")
        #expect(isSuperAdminMethod, "After lock: group.isSuperAdmin should be true")

        // Unlock the group
        try await group.rotateInviteTag()
        try await group.updateAddMemberPermission(newPermissionOption: .allow)
        try await group.sync()

        // Check consistency after unlock
        members = try await group.members
        creatorMember = members.first(where: { $0.inboxId == inboxId })
        memberPermissionLevel = creatorMember?.permissionLevel
        isSuperAdminMethod = try group.isSuperAdmin(inboxId: inboxId)

        #expect(memberPermissionLevel == .SuperAdmin, "After unlock: member.permissionLevel should be SuperAdmin")
        #expect(isSuperAdminMethod, "After unlock: group.isSuperAdmin should be true")

        // Lock again
        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.rotateInviteTag()
        try await group.sync()

        // Check consistency after second lock
        members = try await group.members
        creatorMember = members.first(where: { $0.inboxId == inboxId })
        memberPermissionLevel = creatorMember?.permissionLevel
        isSuperAdminMethod = try group.isSuperAdmin(inboxId: inboxId)

        #expect(memberPermissionLevel == .SuperAdmin, "After second lock: member.permissionLevel should be SuperAdmin")
        #expect(isSuperAdminMethod, "After second lock: group.isSuperAdmin should be true")

        try? await fixtures.cleanup()
    }

    // MARK: - Helper Types

    private enum TestError: Error {
        case missingClients
        case groupNotFound
    }
}

// MARK: - Mock Invite Writer

final class MockInviteWriter: InviteWriterProtocol, @unchecked Sendable {
    var generatedInvites: [(conversation: DBConversation, expiresAt: Date?, expiresAfterUse: Bool)] = []
    var updatedInvites: [(conversationId: String, name: String?, description: String?, imageURL: String?)] = []
    var regeneratedConversationIds: [String] = []
    var deletedConversationIds: [String] = []

    func generate(for conversation: DBConversation, expiresAt: Date?, expiresAfterUse: Bool) async throws -> Invite {
        generatedInvites.append((conversation: conversation, expiresAt: expiresAt, expiresAfterUse: expiresAfterUse))
        return Invite(
            conversationId: conversation.id,
            urlSlug: "mock-invite-slug",
            expiresAt: expiresAt,
            expiresAfterUse: expiresAfterUse
        )
    }

    func update(for conversationId: String, name: String?, description: String?, imageURL: String?) async throws -> Invite {
        updatedInvites.append((conversationId: conversationId, name: name, description: description, imageURL: imageURL))
        return Invite(
            conversationId: conversationId,
            urlSlug: "mock-updated-slug",
            expiresAt: nil,
            expiresAfterUse: false
        )
    }

    func regenerate(for conversationId: String) async throws -> Invite {
        regeneratedConversationIds.append(conversationId)
        return Invite(
            conversationId: conversationId,
            urlSlug: "mock-regenerated-slug",
            expiresAt: nil,
            expiresAfterUse: false
        )
    }

    func delete(for conversationId: String) async throws {
        deletedConversationIds.append(conversationId)
    }
}

// MARK: - Mock Incoming Message Writer

final class MockIncomingMessageWriter: IncomingMessageWriterProtocol, @unchecked Sendable {
    func store(
        message: XMTPiOS.DecodedMessage,
        for conversation: DBConversation
    ) async throws -> IncomingMessageWriterResult {
        IncomingMessageWriterResult(
            contentType: .text,
            wasRemovedFromConversation: false,
            messageAlreadyExists: false
        )
    }

    func decodeExplodeSettings(from message: XMTPiOS.DecodedMessage) -> ExplodeSettings? {
        nil
    }

    func processExplodeSettings(
        _ settings: ExplodeSettings,
        conversationId: String,
        senderInboxId: String,
        currentInboxId: String
    ) async -> ExplodeSettingsResult {
        .fromSelf
    }
}
