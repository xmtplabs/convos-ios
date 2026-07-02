@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Integration coverage for the self-leave signal against a local XMTP node
/// (`./dev/up`). `leaveGroup()` publishes a leave-request message rather than
/// removing the member directly; the remove-commit is finalized later by an
/// authorized client. These tests pin the protocol behavior the departure
/// pipeline is built on: the leave-request reaches the other members with
/// normal message latency, our ingest maps it to a self-leave membership
/// update, and the MLS roster still lists the leaver until finalization.
@Suite("Leave request Integration Tests", .serialized)
struct LeaveRequestIntegrationTests {
    private func createClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let dbKey = Data(keyBytes)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let options = ClientOptions(
            api: .init(env: .local, appVersion: "convos-tests/1.0.0"),
            codecs: [
                TextCodec(),
                GroupUpdatedCodec(),
                LeaveRequestCodec(),
            ],
            dbEncryptionKey: dbKey,
            dbDirectory: tmpDir.path
        )
        return try await Client.create(
            account: try PrivateKey.generate(),
            options: options
        )
    }

    @Test("leaveGroup publishes a leave-request other members ingest as a self-leave update")
    func leaveRequestReachesOtherMembers() async throws {
        let creatorClient = try await createClient()
        let leaverClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? leaverClient.deleteLocalDatabase()
        }

        let group = try await creatorClient.conversations.newGroup(with: [leaverClient.inboxId])

        _ = try await leaverClient.conversations.syncAllConversations(consentStates: nil)
        let leaverConversation = try await leaverClient.conversations.findConversation(conversationId: group.id)
        guard case .group(let leaverGroup) = try #require(leaverConversation) else {
            Issue.record("Leaver's conversation is not a group")
            return
        }

        // The leaver is a regular member (the creator holds super admin), so
        // the protocol accepts the self-leave.
        try await leaverGroup.leaveGroup()

        // The leaver's own client can't commit its own removal: it stays in
        // the roster in a pending-remove state until an authorized client
        // finalizes the commit.
        try await leaverGroup.sync()
        #expect(try leaverGroup.membershipState == .pendingRemove)
        let leaverRoster = try await leaverGroup.members.map(\.inboxId)
        #expect(leaverRoster.contains(leaverClient.inboxId))

        // The creator receives the leave-request as an ordinary message.
        try await group.sync()
        let messages = try await group.messages()
        let leaveRequest = try #require(
            messages.first { (try? $0.encodedContent.type) == ContentTypeLeaveRequest },
            "Creator should receive the leave-request message"
        )
        #expect(leaveRequest.senderInboxId == leaverClient.inboxId)

        // Ingest maps it to a membership update naming the sender as both
        // initiator and removed member -- the self-leave shape the transcript
        // renders as "<name> left" and the member-list drop keys off.
        let dbMessage = try leaveRequest.dbRepresentation()
        #expect(dbMessage.contentType == .update)
        #expect(dbMessage.update?.initiatedByInboxId == leaverClient.inboxId)
        #expect(dbMessage.update?.removedInboxIds == [leaverClient.inboxId])
        #expect(dbMessage.update?.addedInboxIds.isEmpty == true)
    }
}
