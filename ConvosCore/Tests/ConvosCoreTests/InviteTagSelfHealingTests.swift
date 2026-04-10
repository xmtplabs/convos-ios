@testable import ConvosAppData
@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

@Suite("Invite Tag Self-Healing Tests")
struct InviteTagSelfHealingTests {
    private enum TestError: Error {
        case missingClients
    }

    @Test("Store preserves local invite tag when incoming XMTP metadata tag is empty")
    func preservesLocalInviteTagWhenIncomingTagIsEmpty() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        try await group.ensureInviteTag()
        let originalTag = try group.inviteTag

        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: MockIncomingMessageWriter()
        )

        _ = try await conversationWriter.store(conversation: group, inboxId: inboxIdA)

        var emptyMetadata = ConversationCustomMetadata()
        emptyMetadata.name = "Test Group"
        let encodedEmptyMetadata = try emptyMetadata.toCompactString()
        try await group.updateAppData(appData: encodedEmptyMetadata)

        _ = try await conversationWriter.store(conversation: group, inboxId: inboxIdA)

        let storedConversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: group.id)
        }

        #expect(storedConversation?.inviteTag == originalTag)
        #expect(try group.inviteTag == originalTag)

        try? await fixtures.cleanup()
    }

    @Test("restoreInviteTagIfMissing rejects invalid invite tag format")
    func restoreInviteTagRejectsInvalidFormat() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        await #expect(throws: ConversationCustomMetadataError.self) {
            try await group.restoreInviteTagIfMissing("bad-tag")
        }

        try? await fixtures.cleanup()
    }
}
