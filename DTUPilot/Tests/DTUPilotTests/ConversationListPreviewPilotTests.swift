import XCTest
import XMTPDTU

/// The first end-to-end Convos iOS pilot test that uses the XMTPDTU Swift
/// SDK to drive a local `dtu-server` subprocess — zero XMTP backend, zero
/// Docker. The scenario mirrors the most common UI surface on the Convos
/// home screen: bob joins two groups (one he created, one alice created)
/// and expects his conversation list to surface both, with the newest
/// user-authored message for each as the preview text.
///
/// Why this scenario:
///  - Exercises cross-actor sync (bob must pick up alice's welcome + posts).
///  - Exercises `list_conversations` + `newest_message_metadata` together,
///    which is exactly what a home-screen cell binding does.
///  - Keeps membership churn minimal so any failure here is a real wire/
///    SDK regression, not a test-scenario defect.
///
/// This test runs on macOS only — `DTUClient.spawn(...)` needs `Process`,
/// which iOS lacks. That's fine for v0.1: the goal is proving the SDK's
/// usability from Convos's Swift ecosystem before Stage 3 adds the
/// `MessagingClient` injection seam that lets the iOS app consume XMTPDTU
/// against a remote server.
final class ConversationListPreviewPilotTests: XCTestCase {
    private var client: DTUClient?
    private var universe: DTUUniverse?

    override func tearDown() async throws {
        // Order matters: destroy the universe first so the server doesn't
        // log a dangling-tenant warning on shutdown, then terminate the
        // subprocess. Both calls are idempotent.
        if let universe {
            await universe.destroy()
        }
        if let client {
            await client.terminate()
        }
        universe = nil
        client = nil
        try await super.tearDown()
    }

    func testConversationListAndNewestMessagePreview() async throws {
        #if !os(macOS)
        throw XCTSkip("DTUClient.spawn requires macOS; the pilot is a host-only test.")
        #else
        // MARK: Binary discovery
        //
        // 1. DTU_SERVER_BIN env var (CI override).
        // 2. Explicit workspace-relative fallback so `swift test` Just Works
        //    when the server is prebuilt at the conventional location. We
        //    resolve it against THIS source file's path rather than CWD —
        //    when `swift test` runs the working directory is the package
        //    root (DTUPilot), not the caller's shell pwd, and relative
        //    paths get confusing for folks reading the test code.
        let binary = try resolveBinary()

        // MARK: Spawn + health check
        let client: DTUClient
        do {
            client = try await DTUClient.spawn(binaryPath: binary)
        } catch {
            throw XCTSkip(
                """
                Could not spawn dtu-server at \(binary.path).
                Rebuild: `cd \(Self.xmtpDtuServerDir.path) && cargo build --release -p dtu-server`.
                Underlying: \(error)
                """
            )
        }
        self.client = client

        let health = try await client.health()
        XCTAssertEqual(health.status, "ok", "dtu-server health check should return ok")
        XCTAssertEqual(health.service, "dtu-server")

        // MARK: Universe bootstrap
        //
        // Deterministic `seedTimeNs` so downstream timestamp assertions (if
        // a future PR adds them) are stable. `id` is also fixed, purely for
        // log-grep friendliness across CI runs.
        let universe = try await client.createUniverse(
            id: "u_pilot_list_preview",
            seedTimeNs: 1_700_000_000_000_000_000
        )
        self.universe = universe

        // Actors: alice and bob each get a user, an inbox, and one
        // installation. The alias scheme (<user>-main for inboxes,
        // <user>-phone for installations) matches the convention used by
        // the DTU integration tests upstream.
        try await universe.createUser(id: "alice")
        try await universe.createInbox(inboxId: "alice-main", userId: "alice")
        try await universe.createInstallation(installationId: "alice-phone", inboxId: "alice-main")

        try await universe.createUser(id: "bob")
        try await universe.createInbox(inboxId: "bob-main", userId: "bob")
        try await universe.createInstallation(installationId: "bob-phone", inboxId: "bob-main")

        // MARK: Scenario — g1 (alice's group) with two sends
        let g1 = try await universe.createGroup(
            alias: "g1",
            members: ["alice-main", "bob-main"],
            actor: "alice-phone"
        )
        XCTAssertEqual(g1.conversation, "g1")
        XCTAssertEqual(g1.memberCount, 2, "g1 should count alice + bob")

        _ = try await universe.send(
            conversation: "g1",
            text: "first g1 msg",
            actor: "alice-phone"
        )
        _ = try await universe.send(
            conversation: "g1",
            text: "second g1 msg",
            actor: "alice-phone"
        )

        // MARK: Scenario — g2 (bob's group) with one send
        let g2 = try await universe.createGroup(
            alias: "g2",
            members: ["alice-main", "bob-main"],
            actor: "bob-phone"
        )
        XCTAssertEqual(g2.conversation, "g2")
        XCTAssertEqual(g2.memberCount, 2, "g2 should count alice + bob")

        _ = try await universe.send(
            conversation: "g2",
            text: "hello from bob in g2",
            actor: "bob-phone"
        )

        // MARK: Bob syncs to pull alice's g1 welcome + messages
        //
        // This is the critical step for the conversation-list scenario —
        // without the sync, bob's installation wouldn't know about g1 even
        // though he's a member. The returned count should include both
        // groups (the one he created + the one he joined via sync).
        let syncResult = try await universe.sync(actor: "bob-phone")
        XCTAssertGreaterThanOrEqual(
            syncResult.syncedConversations, 2,
            "bob should observe at least g1 + g2 after sync"
        )

        // MARK: Assert: conversation list
        //
        // Both groups should be present and active for bob. We compare as a
        // set because the wire contract doesn't nail down list ordering
        // (libxmtp's own `list_conversations` sorts by last-message time,
        // which is fine but not what we're asserting here — that's a job
        // for the newest-message projection below).
        let conversations = try await universe.listConversations(actor: "bob-phone")
        let aliases = Set(conversations.map(\.alias))
        XCTAssertEqual(aliases, Set(["g1", "g2"]), "bob should see both groups")
        for entry in conversations {
            XCTAssertTrue(entry.isActive, "bob should be active in \(entry.alias)")
        }

        // MARK: Assert: newest-message previews
        //
        // This is the payoff — the home-screen cell binding. For g1 the
        // second send must win (sequence ordering); for g2 the single send
        // is trivially the newest. Both entries must be application
        // messages (system/membership_change messages are filtered server-
        // side per the wire contract, matching libxmtp's
        // `ConversationListItem::last_message`).
        let newest = try await universe.newestMessageMetadata(
            conversations: ["g1", "g2"],
            actor: "bob-phone"
        )
        XCTAssertEqual(newest.count, 2, "expected both groups in newest-message map")

        guard case .message(let g1Newest) = newest["g1"] else {
            XCTFail("g1 should have a newest message; got \(String(describing: newest["g1"]))")
            return
        }
        XCTAssertEqual(g1Newest.kind, .application, "g1 newest should be application, not system")
        assertText(g1Newest.content, equals: "second g1 msg", in: "g1")

        guard case .message(let g2Newest) = newest["g2"] else {
            XCTFail("g2 should have a newest message; got \(String(describing: newest["g2"]))")
            return
        }
        XCTAssertEqual(g2Newest.kind, .application, "g2 newest should be application, not system")
        assertText(g2Newest.content, equals: "hello from bob in g2", in: "g2")

        // Redundant-but-intentional: explicit cleanup here so an assertion
        // failure above still leaves tearDown to pick up the slack, while
        // happy-path runs get deterministic teardown timing.
        await universe.destroy()
        self.universe = nil
        await client.terminate()
        self.client = nil
        #endif
    }

    // MARK: - Helpers

    /// Resolve the `dtu-server` binary with a CI-friendly discovery chain:
    /// `DTU_SERVER_BIN` override first, workspace-relative release build
    /// second. On miss, emit an `XCTSkip` with a runnable `cargo build`
    /// command so local users can recover without hunting through docs.
    private func resolveBinary() throws -> URL {
        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo.environment["DTU_SERVER_BIN"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath)
            guard fm.isExecutableFile(atPath: url.path) else {
                throw XCTSkip(
                    "DTU_SERVER_BIN=\(envPath) is not executable. "
                    + "Build with `cargo build --release -p dtu-server` under "
                    + Self.xmtpDtuServerDir.path
                )
            }
            return url
        }
        let fallback = Self.defaultBinaryURL
        guard fm.isExecutableFile(atPath: fallback.path) else {
            throw XCTSkip(
                """
                dtu-server binary not found at \(fallback.path).
                Build it with:
                    cd \(Self.xmtpDtuServerDir.path) && cargo build --release -p dtu-server
                Or set DTU_SERVER_BIN to an absolute path.
                """
            )
        }
        return fallback
    }

    /// Workspace-relative path anchored against THIS source file rather than
    /// CWD — that way `swift test` behaves the same whether invoked from
    /// the package root or the enclosing workspace.
    private static var xmtpDtuServerDir: URL {
        // This file: .../xmtplabs/convos-ios-task-A/DTUPilot/Tests/DTUPilotTests/ConversationListPreviewPilotTests.swift
        // Server:    .../xmtplabs/xmtp-dtu/server/
        let thisFile = URL(fileURLWithPath: #filePath)
        // Walk up five levels from the file to the shared workspace parent
        // (xmtplabs/), then descend into the xmtp-dtu sibling.
        let workspaceParent = thisFile
            .deletingLastPathComponent() // DTUPilotTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // DTUPilot/
            .deletingLastPathComponent() // convos-ios-task-A/
            .deletingLastPathComponent() // xmtplabs/
        return workspaceParent
            .appendingPathComponent("xmtp-dtu")
            .appendingPathComponent("server")
    }

    private static var defaultBinaryURL: URL {
        xmtpDtuServerDir
            .appendingPathComponent("target")
            .appendingPathComponent("release")
            .appendingPathComponent("dtu-server")
    }

    /// XCTAssert-style helper that unwraps a `NormalizedMessage.Content`'s
    /// text case and compares it. Keeps the call site in the test body
    /// reading like prose, and gives a more useful failure message than a
    /// bare `if case` / `XCTFail` pair.
    private func assertText(
        _ content: NormalizedMessage.Content,
        equals expected: String,
        in alias: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch content {
        case .text(let text):
            XCTAssertEqual(
                text, expected,
                "newest preview text mismatch for \(alias)",
                file: file, line: line
            )
        case .binary:
            XCTFail(
                "expected text content on newest message in \(alias); got binary",
                file: file, line: line
            )
        }
    }
}
