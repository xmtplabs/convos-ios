import Foundation
import XCTest
@preconcurrency import XMTPiOS

/// Phase 2 batch 5: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/Integration/ProfileMessageIntegrationTests.swift`.
///
/// Round-trips `ProfileUpdate` / `ProfileSnapshot` through the
/// XMTPiOS codec pipeline and verifies that
/// `ProfileSnapshotBuilder.buildSnapshot(...)` resolves member
/// profiles correctly with the precedence rules
/// (`ProfileUpdate` > previous `ProfileSnapshot`) and the agent
/// member-kind passthrough.
///
/// The tests drive `XMTPiOS.Client` / `XMTPiOS.Group` directly
/// because the codec wire path (and `ProfileSnapshotBuilder` itself)
/// is XMTPiOS-only — there is no DTU equivalent yet (Stage 4e codec
/// migration pending). On the DTU lane we `XCTSkip` cleanly. The
/// XMTPiOS lane runs against the same Docker-backed XMTP node the
/// rest of the dual-backend suite already uses (see the
/// `XMTPEnvironment.customLocalAddress` hook below mirroring
/// `DualBackendTestFixtures.init`).
///
/// Converted from the original `swift-testing` `@Suite` / `@Test`
/// style to `XCTest` so the skip path is `XCTSkip`-clean (matches
/// how `ProfilePersistenceTests` skips DTU on the codec FIXME).
final class ProfileMessageIntegrationTests: XCTestCase {
    /// XMTPiOS-only: the ProfileUpdate / ProfileSnapshot codec path
    /// is not yet wired through DTU's wire format. Skip cleanly so
    /// the DTU lane stays green.
    private func guardXMTPiOSBackend() throws {
        if let raw = ProcessInfo.processInfo.environment["CONVOS_MESSAGING_BACKEND"],
           raw == "dtu" {
            throw XCTSkip(
                """
                [dtu] ProfileMessageIntegrationTests round-trips through
                the XMTPiOS codec pipeline (ProfileUpdate / ProfileSnapshot
                + ProfileSnapshotBuilder), which is not wired on the DTU
                backend yet. See FIXME(stage4e) on
                ProfileSnapshotBridge.sendProfileUpdate /
                ProfileSnapshotBuilder.buildSnapshot.
                """
            )
        }
        if ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] == nil {
            throw XCTSkip(
                "XMTP_NODE_ADDRESS is unset; skipping XMTPiOS-only integration. "
                    + "Start the Docker stack to run this test."
            )
        }
        // Mirror DualBackendTestFixtures: feed the env var into XMTPiOS.
        if let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
            XMTPEnvironment.customLocalAddress = endpoint
        }
    }

    private func createClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let key = Data(keyBytes)
        let options = ClientOptions(
            api: .init(env: .local, isSecure: false, appVersion: "convos-tests/1.0.0"),
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

    func testProfileUpdateRoundTrip() async throws {
        try guardXMTPiOSBackend()
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
        let groupB = try XCTUnwrap(groups.first { $0.id == group.id })
        try await groupB.sync()

        let messages = try await groupB.messages(limit: 10, direction: .descending)
        let profileMessages = messages.filter {
            (try? $0.encodedContent.type) == ContentTypeProfileUpdate
        }

        XCTAssertFalse(profileMessages.isEmpty)

        let decoded = try codec.decode(content: profileMessages[0].encodedContent)
        XCTAssertEqual(decoded.name, "Alice")
        XCTAssertEqual(decoded.memberKind, .agent)
        XCTAssertEqual(profileMessages[0].senderInboxId, clientA.inboxID)
    }

    // MARK: - ProfileSnapshot round-trip

    func testProfileSnapshotAfterAdd() async throws {
        try guardXMTPiOSBackend()
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
        let groupB = try XCTUnwrap(try clientB.conversations.listGroups().first { $0.id == groupA.id })
        try await groupB.sync()
        _ = try await groupB.send(encodedContent: try codecUpdate.encode(content: ProfileUpdate(name: "Bob")))

        try await groupA.sync()
        _ = try await groupA.addMembers(inboxIds: [clientC.inboxID])

        let allMembers = try await groupA.members.map(\.inboxId)
        try await ProfileSnapshotBuilder.sendSnapshot(group: groupA, memberInboxIds: allMembers)

        try await clientC.conversations.sync()
        let groupC = try XCTUnwrap(try clientC.conversations.listGroups().first { $0.id == groupA.id })
        try await groupC.sync()

        let messages = try await groupC.messages(limit: 20, direction: .descending)
        let snapshotMessages = messages.filter {
            (try? $0.encodedContent.type) == ContentTypeProfileSnapshot
        }

        XCTAssertFalse(snapshotMessages.isEmpty)

        let snapshot = try ProfileSnapshotCodec().decode(content: snapshotMessages[0].encodedContent)
        let aliceProfile = snapshot.findProfile(inboxId: clientA.inboxID)
        let bobProfile = snapshot.findProfile(inboxId: clientB.inboxID)

        XCTAssertEqual(aliceProfile?.name, "Alice")
        XCTAssertEqual(bobProfile?.name, "Bob")
    }

    // MARK: - Snapshot builder precedence

    func testSnapshotBuilderPrefersUpdateOverSnapshot() async throws {
        try guardXMTPiOSBackend()
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        let codecSnapshot = ProfileSnapshotCodec()
        let oldSnapshot = ProfileSnapshot(profiles: [
            try XCTUnwrap(MemberProfile(inboxIdString: clientA.inboxID, name: "Old Alice")),
            try XCTUnwrap(MemberProfile(inboxIdString: clientB.inboxID, name: "Old Bob")),
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

        XCTAssertEqual(aliceProfile?.name, "New Alice")
        XCTAssertEqual(bobProfile?.name, "Old Bob")
    }

    // MARK: - Snapshot builder fallback

    func testSnapshotBuilderFallsBackToSnapshot() async throws {
        try guardXMTPiOSBackend()
        let clientA = try await createClient()
        let clientB = try await createClient()
        defer {
            try? clientA.deleteLocalDatabase()
            try? clientB.deleteLocalDatabase()
        }

        let groupA = try await clientA.conversations.newGroup(with: [clientB.inboxID])

        let codecSnapshot = ProfileSnapshotCodec()
        let previousSnapshot = ProfileSnapshot(profiles: [
            try XCTUnwrap(MemberProfile(inboxIdString: clientA.inboxID, name: "Alice From Snapshot")),
            try XCTUnwrap(MemberProfile(inboxIdString: clientB.inboxID, name: "Bob From Snapshot")),
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

        XCTAssertEqual(aliceProfile?.name, "Alice From Snapshot")
        XCTAssertEqual(bobProfile?.name, "Bob From Snapshot")
    }

    // MARK: - Agent member kind preserved through snapshot

    func testAgentMemberKindPreservedInSnapshot() async throws {
        try guardXMTPiOSBackend()
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
        XCTAssertEqual(agentProfile?.name, "My Agent")
        XCTAssertEqual(agentProfile?.memberKind, .agent)
    }

    // MARK: - Empty group

    func testSnapshotBuilderEmptyGroup() async throws {
        try guardXMTPiOSBackend()
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

        XCTAssertTrue(builtSnapshot.profiles.isEmpty)
    }
}
