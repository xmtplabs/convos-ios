import ConvosAppData
@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

@Suite("ProfileMessage Integration Tests", .serialized)
struct ProfileMessageIntegrationTests {
    private func createClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let key = Data(keyBytes)
        let options = ClientOptions(
            api: .init(env: .local, appVersion: "convos-tests/1.0.0"),
            codecs: [
                TextCodec(),
                ProfileUpdateCodec(),
                ProfileSnapshotCodec()
            ],
            dbEncryptionKey: key
        )
        return try await Client.create(
            account: try PrivateKey.generate(),
            options: options
        )
    }

    // MARK: - ProfileUpdate round-trip

    @Test("ProfileUpdate sent by member A is readable by member B")
    func profileUpdateRoundTrip() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let group = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        var update = ProfileUpdate(name: "Alice")
        update.memberKind = .agent
        let codec = ProfileUpdateCodec()
        _ = try await group.send(encodedContent: try codec.encode(content: update))

        try await clientB.conversations.sync()
        let groups = try clientB.conversations.listGroups()
        let groupB = try #require(groups.first { $0.id == group.id })
        try await groupB.sync()

        let messages = try await groupB.messages(limit: 10, direction: .descending)
        let profileMessages = messages.filter {
            (try? $0.encodedContent.type) == ContentTypeProfileUpdate
        }

        #expect(!profileMessages.isEmpty)

        let decoded = try codec.decode(content: profileMessages[0].encodedContent)
        #expect(decoded.name == "Alice")
        #expect(decoded.memberKind == .agent)
        #expect(profileMessages[0].senderInboxId == clientA.inboxID)
    }

    // MARK: - ProfileSnapshot round-trip

    @Test("ProfileSnapshot sent after adding member contains all profiles")
    func profileSnapshotAfterAdd() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        let clientC = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
            try? clientC.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        let codecUpdate = ProfileUpdateCodec()
        _ = try await groupA.send(encodedContent: try codecUpdate.encode(content: ProfileUpdate(name: "Alice")))

        try await clientB.conversations.sync()
        let groupB = try #require(try clientB.conversations.listGroups().first { $0.id == groupA.id })
        try await groupB.sync()
        _ = try await groupB.send(encodedContent: try codecUpdate.encode(content: ProfileUpdate(name: "Bob")))

        try await groupA.sync()
        _ = try await groupA.addMembers(inboxIds: [clientC.inboxID])

        let allMembers = try await groupA.members.map(\.inboxId)
        try await ProfileSnapshotBuilder.sendSnapshot(group: groupA, memberInboxIds: allMembers)

        try await clientC.conversations.sync()
        let groupC = try #require(try clientC.conversations.listGroups().first { $0.id == groupA.id })
        try await groupC.sync()

        let messages = try await groupC.messages(limit: 20, direction: .descending)
        let snapshotMessages = messages.filter {
            (try? $0.encodedContent.type) == ContentTypeProfileSnapshot
        }

        #expect(!snapshotMessages.isEmpty)

        let snapshot = try ProfileSnapshotCodec().decode(content: snapshotMessages[0].encodedContent)
        let aliceProfile = snapshot.findProfile(inboxId: clientA.inboxID)
        let bobProfile = snapshot.findProfile(inboxId: clientB.inboxID)

        #expect(aliceProfile?.name == "Alice")
        #expect(bobProfile?.name == "Bob")
    }

    // MARK: - Snapshot builder precedence

    @Test("Snapshot builder prefers ProfileUpdate over ProfileSnapshot for the same member")
    func snapshotBuilderPrefersUpdateOverSnapshot() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        let codecSnapshot = ProfileSnapshotCodec()
        let oldSnapshot = ProfileSnapshot(profiles: [
            try #require(MemberProfile(inboxIdString: clientA.inboxID, name: "Old Alice")),
            try #require(MemberProfile(inboxIdString: clientB.inboxID, name: "Old Bob")),
        ])
        _ = try await groupA.send(encodedContent: try codecSnapshot.encode(content: oldSnapshot))

        let codecUpdate = ProfileUpdateCodec()
        _ = try await groupA.send(encodedContent: try codecUpdate.encode(content: ProfileUpdate(name: "New Alice")))

        try await groupA.sync()

        let allMembers = try await groupA.members.map(\.inboxId)
        let builtSnapshot = try await ProfileSnapshotBuilder.buildSnapshot(
            group: groupA,
            memberInboxIds: allMembers
        )

        let aliceProfile = builtSnapshot.findProfile(inboxId: clientA.inboxID)
        let bobProfile = builtSnapshot.findProfile(inboxId: clientB.inboxID)

        #expect(aliceProfile?.name == "New Alice")
        #expect(bobProfile?.name == "Old Bob")
    }

    // MARK: - Snapshot builder fallback

    @Test("Snapshot builder falls back to previous snapshot for members without ProfileUpdate")
    func snapshotBuilderFallsBackToSnapshot() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        let codecSnapshot = ProfileSnapshotCodec()
        let previousSnapshot = ProfileSnapshot(profiles: [
            try #require(MemberProfile(inboxIdString: clientA.inboxID, name: "Alice From Snapshot")),
            try #require(MemberProfile(inboxIdString: clientB.inboxID, name: "Bob From Snapshot")),
        ])
        _ = try await groupA.send(encodedContent: try codecSnapshot.encode(content: previousSnapshot))

        try await groupA.sync()

        let allMembers = try await groupA.members.map(\.inboxId)
        let builtSnapshot = try await ProfileSnapshotBuilder.buildSnapshot(
            group: groupA,
            memberInboxIds: allMembers
        )

        let aliceProfile = builtSnapshot.findProfile(inboxId: clientA.inboxID)
        let bobProfile = builtSnapshot.findProfile(inboxId: clientB.inboxID)

        #expect(aliceProfile?.name == "Alice From Snapshot")
        #expect(bobProfile?.name == "Bob From Snapshot")
    }

    // MARK: - Agent member kind preserved through snapshot

    @Test("Agent member kind is preserved through snapshot build")
    func agentMemberKindPreservedInSnapshot() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        var agentUpdate = ProfileUpdate(name: "My Agent")
        agentUpdate.memberKind = .agent
        _ = try await groupA.send(encodedContent: try ProfileUpdateCodec().encode(content: agentUpdate))

        try await groupA.sync()

        let allMembers = try await groupA.members.map(\.inboxId)
        let builtSnapshot = try await ProfileSnapshotBuilder.buildSnapshot(
            group: groupA,
            memberInboxIds: allMembers
        )

        let agentProfile = builtSnapshot.findProfile(inboxId: clientA.inboxID)
        #expect(agentProfile?.name == "My Agent")
        #expect(agentProfile?.memberKind == .agent)
    }

    // MARK: - Snapshot builder unions database rows with recent messages

    @Test("Snapshot builder includes a database-only member with no recent profile message")
    func snapshotBuilderIncludesDatabaseOnlyMember() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        // The human (clientA) has a recent profile update. The agent (clientB)
        // never published one, so the inviter knows it only through the
        // authoritative database row - the case that rendered "Somebody".
        _ = try await groupA.send(encodedContent: try ProfileUpdateCodec().encode(content: ProfileUpdate(name: "Human")))
        try await groupA.sync()

        var agentProfile = try #require(MemberProfile(inboxIdString: clientB.inboxID, name: "My Agent"))
        agentProfile.memberKind = .agent

        let allMembers = try await groupA.members.map(\.inboxId)
        let builtSnapshot = try await ProfileSnapshotBuilder.buildSnapshot(
            group: groupA,
            memberInboxIds: allMembers,
            dbProfiles: [agentProfile]
        )

        let humanProfile = builtSnapshot.findProfile(inboxId: clientA.inboxID)
        let resolvedAgent = builtSnapshot.findProfile(inboxId: clientB.inboxID)
        #expect(humanProfile?.name == "Human")
        #expect(resolvedAgent?.name == "My Agent")
        #expect(resolvedAgent?.memberKind == .agent)
    }

    @Test("Snapshot builder includes a message-only member missing from the database")
    func snapshotBuilderUnionsMessageOnlyMember() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        // clientB publishes a profile update the inviter has synced but not yet
        // flushed to its database; only clientA has a database row. The union
        // must surface both: the message-only member and the database-only one.
        try await clientB.conversations.sync()
        let groupB = try #require(try clientB.conversations.listGroups().first { $0.id == groupA.id })
        try await groupB.sync()
        _ = try await groupB.send(encodedContent: try ProfileUpdateCodec().encode(content: ProfileUpdate(name: "Fresh Bob")))

        try await groupA.sync()

        let aliceProfile = try #require(MemberProfile(inboxIdString: clientA.inboxID, name: "DB Alice"))

        let allMembers = try await groupA.members.map(\.inboxId)
        let builtSnapshot = try await ProfileSnapshotBuilder.buildSnapshot(
            group: groupA,
            memberInboxIds: allMembers,
            dbProfiles: [aliceProfile]
        )

        let resolvedAlice = builtSnapshot.findProfile(inboxId: clientA.inboxID)
        let resolvedBob = builtSnapshot.findProfile(inboxId: clientB.inboxID)
        #expect(resolvedAlice?.name == "DB Alice")
        #expect(resolvedBob?.name == "Fresh Bob")
    }

    // MARK: - Empty group

    @Test("Snapshot builder returns empty profiles when no profile messages exist")
    func snapshotBuilderEmptyGroup() async throws {
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])
        try await groupA.sync()

        let allMembers = try await groupA.members.map(\.inboxId)
        let builtSnapshot = try await ProfileSnapshotBuilder.buildSnapshot(
            group: groupA,
            memberInboxIds: allMembers
        )

        #expect(builtSnapshot.profiles.isEmpty)
    }
}
