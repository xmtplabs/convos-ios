@testable import ConvosCore
import ConvosInvites
import ConvosInvitesCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

@Suite("Invite Join Request Integration Tests", .serialized, .timeLimit(.minutes(3)))
struct InviteJoinRequestIntegrationTests {

    @Test("Valid invite join request adds member to group")
    func validJoinRequestAddsMember() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        try await group.ensureInviteTag()
        try await group.sync()

        let tag = try group.inviteTag
        #expect(!tag.isEmpty, "Group should have an invite tag")

        let identity = try await fixtures.identityStore.identity(for: clientA.inboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        let slug = try SignedInvite.createSlug(
            conversationId: group.id,
            creatorInboxId: clientA.inboxId,
            privateKey: privateKey,
            tag: tag
        )

        let dm = try await clientB.conversations.findOrCreateDm(with: clientA.inboxId)
        _ = try await dm.send(content: slug)

        try await clientA.conversations.sync()
        _ = try await clientA.conversations.syncAllConversations(consentStates: [.unknown])

        let dms = try clientA.conversations.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .lastActivity
        )
        let incomingDm = dms.first
        let messages = try await incomingDm?.messages(afterNs: nil) ?? []
        let joinMessage = messages.first { $0.senderInboxId != clientA.inboxId }

        guard let joinMessage else {
            Issue.record("Should have a DM message from Client B")
            try? await fixtures.cleanup()
            return
        }

        let testDb = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: testDb)
        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore,
            databaseWriter: testDb
        )

        let result = await joinRequestsManager.processJoinRequest(
            message: joinMessage,
            client: clientA
        )

        #expect(result != nil, "Should have processed the join request")
        #expect(result?.conversationId == group.id)
        #expect(result?.joinerInboxId == clientB.inboxId)

        try await group.sync()
        let members = try await group.members
        let memberInboxIds = members.map { $0.inboxId }
        #expect(memberInboxIds.contains(clientB.inboxId), "Client B should be a member of the group")

        try? await fixtures.cleanup()
    }

    @Test("Join request with revoked tag is rejected")
    func revokedTagJoinRequestRejected() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        try await group.ensureInviteTag()
        try await group.sync()

        let originalTag = try group.inviteTag

        let identity = try await fixtures.identityStore.identity(for: clientA.inboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        let slug = try SignedInvite.createSlug(
            conversationId: group.id,
            creatorInboxId: clientA.inboxId,
            privateKey: privateKey,
            tag: originalTag
        )

        try await group.rotateInviteTag()
        try await group.sync()

        let newTag = try group.inviteTag
        #expect(newTag != originalTag, "Tag should have changed after rotation")

        let dm = try await clientB.conversations.findOrCreateDm(with: clientA.inboxId)
        _ = try await dm.send(content: slug)

        try await clientA.conversations.sync()

        let testDb = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: testDb)
        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore,
            databaseWriter: testDb
        )

        let results = await joinRequestsManager.processJoinRequests(
            since: nil,
            client: clientA
        )

        #expect(results.isEmpty, "Join request with revoked tag should be rejected")

        try await group.sync()
        let members = try await group.members
        let memberInboxIds = members.map { $0.inboxId }
        #expect(!memberInboxIds.contains(clientB.inboxId), "Client B should not be added with a revoked invite")

        try? await fixtures.cleanup()
    }

    @Test("Join request via single message processing adds member")
    func singleMessageProcessingAddsMember() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        try await group.ensureInviteTag()
        try await group.sync()

        let tag = try group.inviteTag
        let identity = try await fixtures.identityStore.identity(for: clientA.inboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        let slug = try SignedInvite.createSlug(
            conversationId: group.id,
            creatorInboxId: clientA.inboxId,
            privateKey: privateKey,
            tag: tag
        )

        let dm = try await clientB.conversations.findOrCreateDm(with: clientA.inboxId)
        _ = try await dm.send(content: slug)

        try await clientA.conversations.sync()
        _ = try await clientA.conversations.syncAllConversations(consentStates: [.unknown])

        let dms = try clientA.conversations.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: [.unknown],
            orderBy: .lastActivity
        )

        guard let incomingDm = dms.first else {
            Issue.record("Should have received a DM")
            try? await fixtures.cleanup()
            return
        }

        let messages = try await incomingDm.messages(afterNs: nil)
        let joinMessage = messages.first { msg in
            msg.senderInboxId != clientA.inboxId
        }

        guard let joinMessage else {
            Issue.record("Should have a message from Client B")
            try? await fixtures.cleanup()
            return
        }

        let testDb = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: testDb)
        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore,
            databaseWriter: testDb
        )

        let result = await joinRequestsManager.processJoinRequest(
            message: joinMessage,
            client: clientA
        )

        #expect(result != nil, "Should have processed the join request")
        #expect(result?.conversationId == group.id)
        #expect(result?.joinerInboxId == clientB.inboxId)

        try await group.sync()
        let members = try await group.members
        let memberInboxIds = members.map { $0.inboxId }
        #expect(memberInboxIds.contains(clientB.inboxId), "Client B should be a member of the group")

        try? await fixtures.cleanup()
    }

    @Test("Join request via JoinRequestContent type adds member")
    func joinRequestContentTypeAddsMember() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Content Type Group",
            imageUrl: "",
            description: ""
        )
        try await group.ensureInviteTag()
        try await group.sync()

        let tag = try group.inviteTag
        let identity = try await fixtures.identityStore.identity(for: clientA.inboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        let slug = try SignedInvite.createSlug(
            conversationId: group.id,
            creatorInboxId: clientA.inboxId,
            privateKey: privateKey,
            tag: tag
        )

        let dm = try await clientB.conversations.findOrCreateDm(with: clientA.inboxId)
        let joinRequest = JoinRequestContent(
            inviteSlug: slug,
            profile: JoinRequestProfile(name: "Test User"),
            metadata: ["source": "integration-test"]
        )
        let codec = JoinRequestCodec()
        _ = try await dm.send(
            content: joinRequest,
            options: .init(contentType: codec.contentType)
        )

        try await clientA.conversations.sync()
        _ = try await clientA.conversations.syncAllConversations(consentStates: [.unknown])

        let dms = try clientA.conversations.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .lastActivity
        )
        let incomingDm = dms.first
        let messages = try await incomingDm?.messages(afterNs: nil) ?? []
        let joinMessage = messages.first { $0.senderInboxId != clientA.inboxId }

        guard let joinMessage else {
            Issue.record("Should have a DM message from Client B")
            try? await fixtures.cleanup()
            return
        }

        let testDb = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: testDb)
        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore,
            databaseWriter: testDb
        )

        let result = await joinRequestsManager.processJoinRequest(
            message: joinMessage,
            client: clientA
        )

        #expect(result != nil, "Should have processed the JoinRequestContent join request")
        #expect(result?.conversationId == group.id)
        #expect(result?.joinerInboxId == clientB.inboxId)
        #expect(result?.profile?.name == "Test User")
        #expect(result?.metadata?["source"] == "integration-test")

        try await group.sync()
        let members = try await group.members
        let memberInboxIds = members.map { $0.inboxId }
        #expect(memberInboxIds.contains(clientB.inboxId), "Client B should be a member of the group")

        try? await fixtures.cleanup()
    }

    @Test("Join request via InviteCoordinator.sendJoinRequest uses content type")
    func sendJoinRequestUsesContentType() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [],
            name: "Coordinator Group",
            imageUrl: "",
            description: ""
        )
        try await group.ensureInviteTag()
        try await group.sync()

        let tag = try group.inviteTag
        let identity = try await fixtures.identityStore.identity(for: clientA.inboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        let slug = try SignedInvite.createSlug(
            conversationId: group.id,
            creatorInboxId: clientA.inboxId,
            privateKey: privateKey,
            tag: tag
        )
        let signedInvite = try SignedInvite.fromURLSafeSlug(slug)

        let identityStore = fixtures.identityStore
        let coordinator = InviteCoordinator(
            privateKeyProvider: { inboxId in
                let identity = try await identityStore.identity(for: inboxId)
                return identity.keys.privateKey.secp256K1.bytes
            }
        )

        let dm = try await coordinator.sendJoinRequest(
            for: signedInvite,
            client: InviteClientProviderAdapter(clientB),
            profile: JoinRequestProfile(name: "Coordinator User", imageURL: "https://example.com/pic.jpg"),
            metadata: ["deviceName": "iPhone"]
        )

        try await clientA.conversations.sync()
        _ = try await clientA.conversations.syncAllConversations(consentStates: [.unknown])

        let messages = try await dm.messages(afterNs: nil)
        let clientBMessages = messages.filter { $0.senderInboxId != clientA.inboxId }
        #expect(clientBMessages.count >= 2, "Should have both JoinRequestContent and plain text messages")

        let joinRequestMessage = clientBMessages.first { msg in
            guard let contentType = try? msg.encodedContent.type else { return false }
            return contentType == ContentTypeJoinRequest
        }

        guard let joinRequestMessage else {
            Issue.record("Should have a JoinRequestContent message from Client B")
            try? await fixtures.cleanup()
            return
        }

        let decoded: JoinRequestContent = try joinRequestMessage.content()
        #expect(decoded.inviteSlug == slug)
        #expect(decoded.profile?.name == "Coordinator User")
        #expect(decoded.profile?.imageURL == "https://example.com/pic.jpg")
        #expect(decoded.metadata?["deviceName"] == "iPhone")

        let plainTextMessage = clientBMessages.first { msg in
            guard let contentType = try? msg.encodedContent.type else { return false }
            return contentType == ContentTypeText
        }
        #expect(plainTextMessage != nil, "Should also have a plain text fallback message")

        let testDb = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: testDb)
        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore,
            databaseWriter: testDb
        )

        let result = await joinRequestsManager.processJoinRequest(
            message: joinRequestMessage,
            client: clientA
        )

        #expect(result != nil, "Should have processed the join request sent via coordinator")
        #expect(result?.conversationId == group.id)
        #expect(result?.joinerInboxId == clientB.inboxId)

        try await group.sync()
        let members = try await group.members
        let memberInboxIds = members.map { $0.inboxId }
        #expect(memberInboxIds.contains(clientB.inboxId), "Client B should be a member of the group")

        try? await fixtures.cleanup()
    }

    private enum TestError: Error {
        case missingClients
    }
}
