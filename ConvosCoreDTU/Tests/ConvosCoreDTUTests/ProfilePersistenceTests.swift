import ConvosAppData
@testable import ConvosCore
import ConvosProfiles
import Foundation
import GRDB
import XCTest

/// Phase 2 batch 4: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/Integration/ProfilePersistenceTests.swift`.
///
/// Exercises how `ConversationWriter.store(...)` preserves member-profile
/// state across sync passes. The legacy version anchored on
/// `fixtures.clientA as? Client` with raw XMTPiOS `group.send` and
/// `group.messages(...)` calls; the Phase 2 rewrite drives the writer
/// through `any MessagingClient` + `MessagingGroup+CustomMetadata` so
/// both backends run the same code path where the backing stack allows.
///
/// Backend coverage matrix:
///  - `appDataProfileFillsGap` — fully abstraction-level, runs on both
///    backends (uses `MessagingGroup.updateProfile`, which reaches
///    through `updateAppData` atomically in the single-writer case that
///    DTU already models).
///  - `removedMemberProfilesCleaned` — fully abstraction-level, runs on
///    both backends (`MessagingGroup.removeMembers` is wired on DTU).
///  - `messageSourcedProfileSurvivesStore` — the ProfileUpdate wire path
///    still depends on the XMTPiOS codec pipeline (see
///    `ProfileSnapshotBridge.sendProfileUpdate` FIXME in
///    `XMTPiOSConversationWriterSupport.swift:420`); skipped on DTU and
///    delegated to the XMTPiOS bridge on the XMTPiOS lane so the
///    behaviour stays under test.
final class ProfilePersistenceTests: XCTestCase {
    private var fixtures: DualBackendTestFixtures?

    override func tearDown() async throws {
        if let fixtures {
            try? await fixtures.cleanup()
            self.fixtures = nil
        }
        try await super.tearDown()
    }

    override class func tearDown() {
        Task {
            await DualBackendTestFixtures.tearDownSharedDTUIfNeeded()
        }
        super.tearDown()
    }

    /// XMTPiOS backend requires the Docker-backed XMTP node. Skip the
    /// run cleanly instead of flaking when the env var isn't set.
    private func guardBackendReady(_ backend: DualBackendTestFixtures.Backend) throws {
        if backend == .xmtpiOS,
           ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] == nil {
            throw XCTSkip(
                "CONVOS_MESSAGING_BACKEND=\(backend.rawValue) (default) and "
                    + "XMTP_NODE_ADDRESS is unset; skipping to avoid a network-"
                    + "dependent failure. Start the XMTP Docker stack or set "
                    + "CONVOS_MESSAGING_BACKEND=dtu."
            )
        }
    }

    // MARK: - Test 1: Message-sourced profile survives conversationWriter.store

    /// Verifies that a profile surfaced from a ProfileUpdate message
    /// (rather than from the 8 KB appData blob) is not overwritten by
    /// a subsequent `ConversationWriter.store` call.
    ///
    /// The ProfileUpdate payload rides the XMTPiOS codec pipeline
    /// (`ProfileSnapshotBridge.sendProfileUpdate` only resolves on an
    /// `XMTPiOSMessagingGroup`). DTU has no ProfileUpdate codec wired
    /// end-to-end yet — skip it there and keep the XMTPiOS lane green.
    func testMessageSourcedProfileSurvivesStore() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)
        if backend == .dtu {
            throw XCTSkip(
                "[dtu] ProfileUpdate codec is still XMTPiOS-only "
                    + "(see ProfileSnapshotBridge FIXME). Running this "
                    + "scenario needs the Stage 4e codec migration."
            )
        }

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "profile-persistence-msg"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()
        let inboxIdB = bob.inboxAlias
        let clientIdB = bob.clientId

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdB, clientId: clientIdB, createdAt: Date())
                .insert(db)
        }

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [inboxIdB],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // The XMTPiOS bridge is the only path that can encode+send a
        // ProfileUpdate today. `ProfileSnapshotBridge.sendProfileUpdate`
        // is internal-to-ConvosCore; `@testable import ConvosCore`
        // above gives us access for the migration.
        let update = ProfileUpdate(name: "Alice Updated Via Message")
        try await ProfileSnapshotBridge.sendProfileUpdate(update, on: group)

        // Bob syncs and observes the group; we need his handle to call
        // `ConversationWriter.store` on the recipient side so the
        // "message sourced profile vs appData" collision is reproduced.
        try await bob.client.conversations.sync()
        let bobConversations = try await bob.client.conversations.list(
            query: MessagingConversationQuery(orderBy: .lastActivity)
        )
        let bobGroupConvo = try XCTUnwrap(bobConversations.first { $0.id == group.id })
        guard case .group(let bobGroup) = bobGroupConvo else {
            XCTFail("[\(backend.rawValue)] expected group conversation for bob")
            return
        }
        try await bobGroup.sync()

        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: DualBackendMockIncomingMessageWriter()
        )

        _ = try await conversationWriter.store(
            conversation: bobGroup,
            inboxId: inboxIdB
        )

        // Round-trip the ProfileUpdate message and verify it was visible.
        // `MessagingContentType` is the Convos-owned mirror of XMTPiOS's
        // `ContentTypeID`; match on authority + typeID pair directly.
        let messages = try await bobGroup.messages(
            query: MessagingMessageQuery(limit: 10)
        )
        let profileUpdateMsg = try XCTUnwrap(
            messages.first { message in
                message.encodedContent.type.authorityID == ContentTypeProfileUpdate.authorityID
                    && message.encodedContent.type.typeID == ContentTypeProfileUpdate.typeID
            },
            "[\(backend.rawValue)] ProfileUpdate message should be visible"
        )
        // Adapter-side projection back to XMTPiOS so the codec can decode.
        let decoded = try ProfileUpdateCodec().decode(
            content: profileUpdateMsg.encodedContent.xmtpEncodedContent
        )
        XCTAssertEqual(
            decoded.name,
            "Alice Updated Via Message",
            "[\(backend.rawValue)] decoded ProfileUpdate should match what was sent"
        )

        // Simulate the IncomingMessageWriter writing the profile from
        // the decoded message (real flow: MessageWriter writes
        // DBMemberProfile keyed by inboxIdA / conversationId).
        try await fixture.databaseManager.dbWriter.write { db in
            let member = DBMember(inboxId: alice.inboxAlias)
            try member.save(db)
            let profile = DBMemberProfile(
                conversationId: group.id,
                inboxId: alice.inboxAlias,
                name: "Alice Updated Via Message",
                avatar: nil
            )
            try profile.save(db)
        }

        _ = try await conversationWriter.store(
            conversation: bobGroup,
            inboxId: inboxIdB
        )

        let profileAfterSecondStore = try await fixture.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(
                db,
                conversationId: group.id,
                inboxId: alice.inboxAlias
            )
        }
        XCTAssertEqual(
            profileAfterSecondStore?.name,
            "Alice Updated Via Message",
            "[\(backend.rawValue)] message-sourced profile must survive re-store"
        )
    }

    // MARK: - Test 2: AppData profile fills gap for member without message data

    func testAppDataProfileFillsGap() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        // `MessagingGroup.updateProfile` stuffs the inbox ID into the
        // custom-metadata protobuf via `ConversationProfile`'s
        // `inboxIdString:` initialiser, which rejects non-hex inputs
        // (see `ConvosAppData.ProfileHelpers`). XMTPiOS inbox IDs are
        // real hex, so the readable aliases the fixture defaults to
        // work there. The DTU path ordinarily uses human-readable
        // aliases (`alice-inbox-1`), so opt into hex-encoded aliases
        // for this test only — DTU's engine accepts opaque strings as
        // inbox IDs regardless of shape.
        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "profile-persistence-appdata",
            aliasesHexEncoded: backend == .dtu
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()
        let inboxIdA = alice.inboxAlias
        let clientIdA = alice.clientId

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date())
                .insert(db)
        }

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        try await group.updateProfile(
            DBMemberProfile(
                conversationId: group.id,
                inboxId: inboxIdA,
                name: "Alice From AppData",
                avatar: nil
            )
        )

        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: DualBackendMockIncomingMessageWriter()
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA
        )

        let profile = try await fixture.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(
                db,
                conversationId: group.id,
                inboxId: inboxIdA
            )
        }
        XCTAssertEqual(
            profile?.name,
            "Alice From AppData",
            "[\(backend.rawValue)] appData profile must populate when no message data exists"
        )
    }

    // MARK: - Test 3: Profiles for removed members are preserved

    func testRemovedMemberProfilesCleaned() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "profile-persistence-removed"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()
        let inboxIdA = alice.inboxAlias
        let clientIdA = alice.clientId

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date())
                .insert(db)
        }

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: DualBackendMockIncomingMessageWriter()
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA
        )

        try await fixture.databaseManager.dbWriter.write { db in
            let member = DBMember(inboxId: bob.inboxAlias)
            try member.save(db)
            let profile = DBMemberProfile(
                conversationId: group.id,
                inboxId: bob.inboxAlias,
                name: "Bob",
                avatar: nil
            )
            try profile.save(db)
        }

        let bobBefore = try await fixture.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(
                db,
                conversationId: group.id,
                inboxId: bob.inboxAlias
            )
        }
        XCTAssertEqual(bobBefore?.name, "Bob")

        try await group.removeMembers(inboxIds: [bob.inboxAlias])
        try await group.sync()

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA
        )

        let bobAfter = try await fixture.databaseManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(
                db,
                conversationId: group.id,
                inboxId: bob.inboxAlias
            )
        }
        XCTAssertEqual(
            bobAfter?.name,
            "Bob",
            "[\(backend.rawValue)] removed member's profile is preserved for message history"
        )
    }
}
