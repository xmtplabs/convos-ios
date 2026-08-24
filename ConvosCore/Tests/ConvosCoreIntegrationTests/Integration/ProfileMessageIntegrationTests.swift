import ConvosAppData
@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

/// Covers the profile message that is still authored: `ProfileUpdate`.
/// Snapshot *building* left with the relay - the app reads snapshots that
/// other clients send but no longer sends any of its own.
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
}
