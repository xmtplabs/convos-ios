import ConvosCore
@testable import ConvosCoreDTU
import ConvosMessagingProtocols
import XCTest
import XMTPDTU

/// Stage 5 validation milestone: prove that `MessagingClient` works
/// end-to-end against DTU.
///
/// The test walks the minimum scenario needed to exercise the adapter's
/// happy paths:
///
///  1. Spawn `dtu-server` as a subprocess (via `DTUClient.spawn`).
///  2. Create a universe + bootstrap two actors (alice + bob).
///  3. Build a `DTUMessagingClient` for each actor via
///     `DTUMessagingClientFactory`.
///  4. Drive alice's client through the generic `MessagingClient`
///     surface: `conversations.newGroup(...)`, `group.sendOptimistic(...)`.
///  5. Sync bob's client and assert he sees the group + the message
///     via `conversations.list(...)` + `group.messages(...)`.
///
/// The test intentionally goes through the abstraction surface
/// (`MessagingClient.conversations`) not the raw `DTUUniverse` — the
/// whole point of Stage 5 is to validate that the abstraction can be
/// backed by something other than XMTPiOS.
///
/// macOS-only: `DTUClient.spawn(...)` needs `Process`, which iOS lacks.
/// The test skips gracefully on iOS, matching the DTUPilot pattern at
/// `DTUPilot/Tests/DTUPilotTests/ConversationListPreviewPilotTests.swift`.
final class DTUMessagingClientSmokeTests: XCTestCase {
    private var dtuClient: DTUClient?
    private var universe: DTUUniverse?

    override func tearDown() async throws {
        // Order matters: destroy universe before terminating the
        // subprocess so the server doesn't log a dangling-tenant
        // warning on shutdown. Both calls are idempotent.
        if let universe {
            await universe.destroy()
        }
        if let dtuClient {
            await dtuClient.terminate()
        }
        universe = nil
        dtuClient = nil
        DTUMessagingClient.setDefaultUniverse(nil)
        try await super.tearDown()
    }

    func testCreateGroupAndSendMessageEndToEnd() async throws {
        #if !os(macOS)
        throw XCTSkip("DTUClient.spawn requires macOS; smoke test is host-only.")
        #else
        // MARK: Binary discovery
        let binary = try resolveBinary()

        // MARK: Spawn dtu-server + universe bootstrap
        let dtuClient: DTUClient
        do {
            dtuClient = try await DTUClient.spawn(binaryPath: binary)
        } catch {
            throw XCTSkip(
                """
                Could not spawn dtu-server at \(binary.path).
                Rebuild: `cd \(Self.xmtpDtuServerDir.path) && cargo build --release -p dtu-server`.
                Underlying: \(error)
                """
            )
        }
        self.dtuClient = dtuClient

        let health = try await dtuClient.health()
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.service, "dtu-server")

        let universe = try await dtuClient.createUniverse(
            id: "u_stage5_smoke",
            seedTimeNs: 1_700_000_000_000_000_000
        )
        self.universe = universe

        // MARK: Factory + two actors
        let factory = DTUMessagingClientFactory(universe: universe)
        let alice = try await factory.attachClient(
            userAlias: "alice",
            inboxAlias: "alice-main",
            installationAlias: "alice-phone"
        )
        let bob = try await factory.attachClient(
            userAlias: "bob",
            inboxAlias: "bob-main",
            installationAlias: "bob-phone"
        )

        XCTAssertEqual(alice.inboxId, "alice-main")
        XCTAssertEqual(alice.installationId, "alice-phone")
        XCTAssertEqual(bob.inboxId, "bob-main")
        XCTAssertEqual(bob.installationId, "bob-phone")

        // MARK: Drive through MessagingClient — create group
        //
        // Note the assertion form: we read `group.id` back via the
        // abstraction, not the raw DTU universe. If this line runs
        // without throwing, the adapter successfully mapped
        // `MessagingConversations.newGroup(...)` onto DTU's
        // `create_group` action with the abstraction's call shape.
        let group = try await alice.conversations.newGroup(
            withInboxIds: ["alice-main", "bob-main"],
            name: "stage 5 smoke",
            imageUrl: "",
            description: ""
        )
        // The factory mints aliases starting at `dtu-g-1` per
        // DTUMessagingConversations' monotonic counter.
        XCTAssertEqual(group.id, "dtu-g-1")

        // Members: DTU's list_members returns alice-main + bob-main
        // plus any creator inbox. Assert the pair is present.
        let members = try await group.members()
        let inboxIds = Set(members.map(\.inboxId))
        XCTAssertTrue(inboxIds.contains("alice-main"), "group should include alice")
        XCTAssertTrue(inboxIds.contains("bob-main"), "group should include bob")

        // MARK: Send a text message via MessagingConversationCore
        //
        // We build a `MessagingEncodedContent` of the canonical text
        // content type — that's what the abstraction's send path
        // expects. The DTU adapter's unpacker translates it into the
        // DTU wire `ContentPayload.text(...)`.
        let encoded = MessagingEncodedContent(
            type: .text,
            parameters: [:],
            content: "hello from alice".data(using: .utf8)!,
            fallback: nil,
            compression: nil
        )
        let prepared = try await group.sendOptimistic(
            encodedContent: encoded,
            options: nil
        )
        XCTAssertEqual(prepared.conversationId, group.id)
        XCTAssertFalse(prepared.messageId.isEmpty)

        // MARK: Bob syncs + lists — validates cross-installation sync
        //
        // Without this `sync()`, bob's client still knows about alice's
        // group only insofar as the universe state allows. The
        // abstraction's `MessagingConversations.sync()` maps onto DTU's
        // `sync` action tagged with bob's actor alias.
        try await bob.conversations.sync()

        let bobsGroups = try await bob.conversations.listGroups(
            query: MessagingConversationQuery()
        )
        let bobsGroupIds = bobsGroups.map(\.id)
        XCTAssertTrue(
            bobsGroupIds.contains(group.id),
            "bob should see alice's group after sync; got \(bobsGroupIds)"
        )

        // MARK: List messages — the payoff
        //
        // This is the main assertion: drives the full pipe (send →
        // sync → list) entirely through `MessagingClient` /
        // `MessagingGroup` / `MessagingMessage`, without talking to
        // `DTUUniverse` directly. If this passes, the abstraction
        // can be backed by DTU end-to-end.
        guard let bobsViewOfGroup = bobsGroups.first(where: { $0.id == group.id }) else {
            XCTFail("bob's group list missing alice's group")
            return
        }
        let messages = try await bobsViewOfGroup.messages(
            query: MessagingMessageQuery()
        )
        let textMessages = messages.filter {
            $0.encodedContent.type.authorityID == "xmtp.org"
                && $0.encodedContent.type.typeID == "text"
        }
        XCTAssertFalse(textMessages.isEmpty, "bob should see alice's message")

        let decoded = textMessages.compactMap { msg in
            String(data: msg.encodedContent.content, encoding: .utf8)
        }
        XCTAssertTrue(
            decoded.contains("hello from alice"),
            "bob should decode alice's message text; got \(decoded)"
        )

        // Explicit cleanup — tearDown handles the failure case; this
        // path ensures the universe/subprocess come down in the happy
        // path before the next test starts.
        await universe.destroy()
        self.universe = nil
        await dtuClient.terminate()
        self.dtuClient = nil
        #endif
    }

    // MARK: - Helpers

    /// Resolve the `dtu-server` binary with the same discovery chain
    /// DTUPilot uses: `DTU_SERVER_BIN` env override first, workspace-
    /// relative release build second. On miss, skip with a runnable
    /// `cargo build` command.
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

    /// Workspace-relative path anchored against THIS source file's
    /// location so `swift test` behaves the same whether invoked from
    /// the package root or a parent shell.
    ///
    /// Path shape:
    ///   .../xmtplabs/convos-ios-task-D/ConvosCoreDTU/Tests/ConvosCoreDTUTests/DTUMessagingClientSmokeTests.swift
    ///   -> .../xmtplabs/xmtp-dtu/server/
    private static var xmtpDtuServerDir: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let workspaceParent = thisFile
            .deletingLastPathComponent() // ConvosCoreDTUTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ConvosCoreDTU/
            .deletingLastPathComponent() // convos-ios-task-D/
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
}
