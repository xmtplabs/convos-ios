@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

@Suite("Profile Persistence Tests", .serialized)
struct ProfilePersistenceTests {
    private enum TestError: Error {
        case missingClients
    }

    @Test("Message-sourced profile survives conversationWriter.store")
    func messageSourcedProfileSurvivesStore() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client,
              let clientIdB = fixtures.clientIdB else {
            throw TestError.missingClients
        }

        let inboxIdB = clientB.inboxID
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdB, clientId: clientIdB, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Test Group"
        )

        let update = ProfileUpdate(name: "Alice Updated Via Message")
        let encoded = try ProfileUpdateCodec().encode(content: update)
        _ = try await group.send(encodedContent: encoded)

        try await clientB.conversations.sync()
        let groupB = try #require(try clientB.conversations.listGroups().first { $0.id == group.id })
        try await groupB.sync()

        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        _ = try await conversationWriter.store(
            conversation: groupB,
            inboxId: inboxIdB
        )

        let profileAfterFirstStore = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: clientA.inboxID)
        }
        let nameFromAppData = profileAfterFirstStore?.name

        let messages = try await groupB.messages(limit: 10, direction: .descending)
        let profileUpdateMsg = try #require(messages.first {
            (try? $0.encodedContent.type) == ContentTypeProfileUpdate
        })
        let decoded = try ProfileUpdateCodec().decode(content: profileUpdateMsg.encodedContent)
        #expect(decoded.name == "Alice Updated Via Message")

        try await fixtures.databaseManager.dbWriter.write { db in
            let member = DBMember(inboxId: clientA.inboxID)
            try member.save(db)
            let profile = DBMemberProfile(
                conversationId: group.id,
                inboxId: clientA.inboxID,
                name: "Alice Updated Via Message",
                avatar: nil
            )
            try profile.save(db)
        }

        _ = try await conversationWriter.store(
            conversation: groupB,
            inboxId: inboxIdB
        )

        let profileAfterSecondStore = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: clientA.inboxID)
        }
        #expect(profileAfterSecondStore?.name == "Alice Updated Via Message")

        try? await fixtures.cleanup()
    }

    @Test("AppData profile fills gap for member without message-sourced data")
    func appDataProfileFillsGap() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Test Group"
        )

        try await group.updateProfile(
            DBMemberProfile(
                conversationId: group.id,
                inboxId: inboxIdA,
                name: "Alice From AppData",
                avatar: nil
            )
        )

        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA
        )

        let profile = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: inboxIdA)
        }
        #expect(profile?.name == "Alice From AppData")

        try? await fixtures.cleanup()
    }

    @Test("Profiles for removed members are preserved for message history")
    func removedMemberProfilesCleaned() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Test Group"
        )

        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA
        )

        try await fixtures.databaseManager.dbWriter.write { db in
            let member = DBMember(inboxId: clientB.inboxID)
            try member.save(db)
            let profile = DBMemberProfile(
                conversationId: group.id,
                inboxId: clientB.inboxID,
                name: "Bob",
                avatar: nil
            )
            try profile.save(db)
        }

        let bobBefore = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: clientB.inboxID)
        }
        #expect(bobBefore?.name == "Bob")

        _ = try await group.removeMembers(inboxIds: [clientB.inboxID])
        try await group.sync()

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA
        )

        let bobAfter = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: clientB.inboxID)
        }
        #expect(bobAfter?.name == "Bob")

        try? await fixtures.cleanup()
    }
}
