@testable import ConvosCore
import ConvosMessagingProtocols
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

/// Local stand-in for the deleted `MockIncomingMessageWriter`. Short-circuits
/// `store(...)` because this test exercises `ConversationWriter` and the
/// profile-stream path; the message-write outcome isn't under test.
private final class MockIncomingMessageWriter: IncomingMessageWriterProtocol,
                                               @unchecked Sendable {
    func store(
        message: MessagingMessage,
        for conversation: DBConversation
    ) async throws -> IncomingMessageWriterResult {
        IncomingMessageWriterResult(
            contentType: .text,
            wasRemovedFromConversation: false,
            messageAlreadyExists: false
        )
    }

    func decodeExplodeSettings(from message: MessagingMessage) -> ExplodeSettings? {
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

/// Verifies that profile-stream/snapshot writers do not flip a previously-verified
/// agent back to `.agent` (unverified) when the cached attestation check
/// transiently returns `.unverified` (stale `attestation_ts`, missing
/// metadata, or a kid that the local keyset hasn't cached yet).
///
/// The NSE-side equivalents (`MessagingService+PushNotifications`) share the
/// same fix but their `processProfileUpdateInNSE` / `processProfileSnapshotInNSE`
/// entry points are private and don't have a lightweight test harness, so
/// they're covered indirectly by the StreamProcessor cases below.
@Suite("Agent Verification Downgrade Tests", .serialized)
struct AgentVerificationDowngradeTests {
    private enum TestError: Error {
        case missingClients
    }

    /// Configures `AgentKeysetStore` so that `verifyCachedAgentAttestation`
    /// resolves no kid and returns `.unverified`. Used to simulate the
    /// keyset-cache-miss / missing-metadata cases.
    private static func configureEmptyKeyset() {
        AgentKeysetStore.instance.configure(MockAgentKeyset(keys: [:]))
    }

    private static func seedVerifiedAgent(
        in databaseWriter: any DatabaseWriter,
        conversationId: String,
        inboxId: String,
        name: String? = nil,
        avatar: String? = nil
    ) async throws {
        try await databaseWriter.write { db in
            try DBMember(inboxId: inboxId).save(db)
            try DBMemberProfile(
                conversationId: conversationId,
                inboxId: inboxId,
                name: name,
                avatar: avatar,
                memberKind: .verifiedConvos
            ).save(db)
        }
    }

    @Test("Stream ProfileUpdate without attestation does not downgrade verified agent")
    func streamProfileUpdateMissingAttestationPreservesVerifiedConvos() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let wrappedA = fixtures.clientA as? XMTPiOSMessagingClient,
              let wrappedB = fixtures.clientB as? XMTPiOSMessagingClient,
              let clientIdB = fixtures.clientIdB else {
            throw TestError.missingClients
        }
        let clientA = wrappedA.xmtpClient
        let clientB = wrappedB.xmtpClient

        Self.configureEmptyKeyset()

        let inboxIdA = clientA.inboxID
        let inboxIdB = clientB.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdB, clientId: clientIdB, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(with: [inboxIdB], name: "Test Group")

        try await clientB.conversations.sync()
        let groupB = try #require(try clientB.conversations.listGroups().first { $0.id == group.id })
        try await groupB.sync()
        try await groupB.updateConsentState(state: .allowed)

        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )
        _ = try await conversationWriter.store(
            conversation: XMTPiOSMessagingGroup(xmtpGroup: groupB),
            inboxId: inboxIdB
        )

        try await Self.seedVerifiedAgent(
            in: fixtures.databaseManager.dbWriter,
            conversationId: group.id,
            inboxId: inboxIdA,
            name: "Verified Agent"
        )

        let preStateMemberKind = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: inboxIdA)?.memberKind
        }
        #expect(preStateMemberKind == .verifiedConvos, "Pre-condition: profile starts as verified")

        var update = ProfileUpdate(name: "Verified Agent")
        update.memberKind = .agent
        // Intentionally no attestation metadata.
        let encoded = try ProfileUpdateCodec().encode(content: update)
        _ = try await group.send(encodedContent: encoded)

        try await groupB.sync()

        let processor = StreamProcessor(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            notificationCenter: MockUserNotificationCenter()
        )
        let params = SyncClientParams(client: wrappedB, apiClient: MockAPIClient())

        let messages = try await groupB.messages(limit: 20, direction: .descending)
        let updateMsg = try #require(messages.first {
            (try? $0.encodedContent.type) == ContentTypeProfileUpdate
        })
        await processor.processMessage(updateMsg, params: params, activeConversationId: nil)

        let postMemberKind = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: inboxIdA)?.memberKind
        }
        #expect(postMemberKind == .verifiedConvos, "Verified agent must not downgrade after a missing-attestation update")

        try? await fixtures.cleanup()
    }

    @Test("Stream ProfileSnapshot without attestation does not downgrade verified agent")
    func streamProfileSnapshotMissingAttestationPreservesVerifiedConvos() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let wrappedA = fixtures.clientA as? XMTPiOSMessagingClient,
              let wrappedB = fixtures.clientB as? XMTPiOSMessagingClient,
              let clientIdB = fixtures.clientIdB else {
            throw TestError.missingClients
        }
        let clientA = wrappedA.xmtpClient
        let clientB = wrappedB.xmtpClient

        Self.configureEmptyKeyset()

        let inboxIdA = clientA.inboxID
        let inboxIdB = clientB.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdB, clientId: clientIdB, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(with: [inboxIdB], name: "Test Group")

        try await clientB.conversations.sync()
        let groupB = try #require(try clientB.conversations.listGroups().first { $0.id == group.id })
        try await groupB.sync()
        try await groupB.updateConsentState(state: .allowed)

        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )
        _ = try await conversationWriter.store(
            conversation: XMTPiOSMessagingGroup(xmtpGroup: groupB),
            inboxId: inboxIdB
        )

        try await Self.seedVerifiedAgent(
            in: fixtures.databaseManager.dbWriter,
            conversationId: group.id,
            inboxId: inboxIdA
        )

        var memberProfile = MemberProfile()
        if let inboxIdBytes = Data(hexString: inboxIdA), !inboxIdBytes.isEmpty {
            memberProfile.inboxID = inboxIdBytes
        }
        memberProfile.name = "Snapshot Name"
        memberProfile.memberKind = .agent
        // Intentionally no attestation metadata.
        var snapshot = ProfileSnapshot()
        snapshot.profiles = [memberProfile]

        let encoded = try ProfileSnapshotCodec().encode(content: snapshot)
        _ = try await group.send(encodedContent: encoded)

        try await groupB.sync()

        let processor = StreamProcessor(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            notificationCenter: MockUserNotificationCenter()
        )
        let params = SyncClientParams(client: wrappedB, apiClient: MockAPIClient())

        let messages = try await groupB.messages(limit: 20, direction: .descending)
        let snapshotMsg = try #require(messages.first {
            (try? $0.encodedContent.type) == ContentTypeProfileSnapshot
        })
        await processor.processMessage(snapshotMsg, params: params, activeConversationId: nil)

        let postMemberKind = try await fixtures.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: group.id, inboxId: inboxIdA)?.memberKind
        }
        #expect(postMemberKind == .verifiedConvos, "Verified agent must not downgrade after a missing-attestation snapshot")

        try? await fixtures.cleanup()
    }
}
