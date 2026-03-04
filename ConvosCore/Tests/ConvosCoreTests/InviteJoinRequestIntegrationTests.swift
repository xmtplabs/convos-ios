@testable import ConvosCore
import ConvosInvites
import ConvosInvitesCore
import Foundation
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

        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore
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

        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore
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

        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: fixtures.identityStore
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

    private enum TestError: Error {
        case missingClients
    }
}
