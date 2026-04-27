@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosMessagingProtocols
import Foundation
import XCTest
import XMTPDTU
@preconcurrency import XMTPiOS

/// Test fixtures that speak the Convos-owned `MessagingClient` surface
/// across both supported backends:
///
///  - `xmtpiOS` (default): goes through `XMTPiOSMessagingClient.create(...)`
///    against the same Docker-backed XMTP node that the existing
///    `TestFixtures` in `ConvosCore/Tests/ConvosCoreTests/TestHelpers.swift`
///    points to.
///  - `dtu`: goes through `DTUMessagingClientFactory.attachClient(...)`
///    attached to a **shared** dtu-server subprocess + universe that are
///    stood up once per XCTest run.
///
/// Backend is selected at runtime by the `CONVOS_MESSAGING_BACKEND`
/// environment variable (values: `xmtpiOS` | `dtu`; default `xmtpiOS`).
/// That preserves backwards compat with existing Docker-backed CI while
/// unlocking a parallel DTU pass.
///
/// Callers work against the `any MessagingClient` surface — NOT the
/// legacy `any XMTPClientProvider` surface that `TestFixtures` exposes.
/// The two surfaces are both supported by Convos today; migrating an
/// existing test from `XMTPClientProvider` → `MessagingClient` is the
/// step that enables the DTU pass.
///
/// macOS-only (DTU spawn path uses `Process`); the DTU branch skips
/// gracefully on iOS to match `DTUMessagingClientSmokeTests`.
public final class DualBackendTestFixtures {
    // MARK: - Backend selection

    public enum Backend: String, Sendable {
        case xmtpiOS
        case dtu

        /// Env-var switch: `CONVOS_MESSAGING_BACKEND=xmtpiOS|dtu`.
        /// Default is `.xmtpiOS` so existing Docker-backed runs
        /// (including the 59-test baseline in `ci/run-tests.sh --unit`
        /// sibling packages) are unaffected.
        public static var selected: Backend {
            guard let raw = ProcessInfo.processInfo.environment["CONVOS_MESSAGING_BACKEND"],
                  let backend = Backend(rawValue: raw) else {
                return .xmtpiOS
            }
            return backend
        }
    }

    // MARK: - Shared per-run state

    /// Handle to a `MessagingClient` plus the identity material that
    /// produced it. Mirrors `TestFixtures.createClient`'s tuple return.
    public struct ClientHandle: Sendable {
        public let client: any MessagingClient
        public let clientId: String
        public let inboxAlias: String
        public let installationAlias: String

        public init(
            client: any MessagingClient,
            clientId: String,
            inboxAlias: String,
            installationAlias: String
        ) {
            self.client = client
            self.clientId = clientId
            self.inboxAlias = inboxAlias
            self.installationAlias = installationAlias
        }
    }

    // MARK: - Instance state

    public let backend: Backend
    public let environment: AppEnvironment
    public let identityStore: MockKeychainIdentityStore
    public let databaseManager: MockDatabaseManager

    /// DTU-only counter for per-fixture alias assignment. XMTPiOS path
    /// doesn't use aliases; it generates real keys.
    private var nextAliasIndex: Int = 0
    private let aliasBase: String

    /// When `true`, DTU inbox aliases are generated as hex-only strings
    /// (e.g. `deadbeef0011…`) instead of the readable `name-inbox-N`
    /// form. Required for tests that feed the alias into
    /// `ConversationProfile(inboxIdString:)` / `DBMemberProfile.conversationProfile`,
    /// which reject non-hex inbox IDs via `.invalidInboxIdHex`
    /// (see `ConvosAppData.ProfileHelpers.init?(inboxIdString:)`).
    /// Default `false` keeps existing tests legible. The XMTPiOS path
    /// ignores this flag — its inbox IDs are already real hex.
    private let aliasesHexEncoded: Bool

    public var clientA: ClientHandle?
    public var clientB: ClientHandle?
    public var clientC: ClientHandle?

    public init(
        backend: Backend = .selected,
        aliasPrefix: String = "actor",
        aliasesHexEncoded: Bool = false
    ) {
        self.backend = backend
        self.environment = .tests
        self.identityStore = MockKeychainIdentityStore()
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
        self.aliasesHexEncoded = aliasesHexEncoded
        // DTU actor aliases must be unique across tests to keep the
        // shared universe state clean. Fold a fixture-scoped nonce in
        // on top of the caller-provided prefix.
        let nonce = UUID().uuidString.prefix(8)
        self.aliasBase = "\(aliasPrefix)-\(nonce)"

        // Match TestFixtures' one-time setup so any shared ConvosCore
        // state (logging, mock singletons) is configured consistently.
        ConvosLog.configure(environment: .tests)
        DeviceInfo.resetForTesting()
        DeviceInfo.configure(MockDeviceInfoProvider())
        PushNotificationRegistrar.resetForTesting()
        PushNotificationRegistrar.configure(MockPushNotificationRegistrarProvider())

        // XMTPiOS backend respects XMTP_NODE_ADDRESS for the Docker
        // endpoint; mirror `TestHelpers.swift`'s side effect to keep
        // legacy tests and this fixture on the same node.
        if backend == .xmtpiOS,
           let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
            XMTPEnvironment.customLocalAddress = endpoint
        }
    }

    // MARK: - Client creation

    public func createClient() async throws -> ClientHandle {
        nextAliasIndex += 1
        let clientId = ClientId.generate().value

        switch backend {
        case .xmtpiOS:
            return try await createXMTPiOSClient(clientId: clientId)
        case .dtu:
            return try await createDTUClient(clientId: clientId)
        }
    }

    public func createTestClients() async throws {
        clientA = try await createClient()
        clientB = try await createClient()
        clientC = try await createClient()
    }

    public func cleanup() async throws {
        // XMTPiOS clients own a local libxmtp DB; delete to avoid
        // leaking state across tests (parallels `TestFixtures.cleanup`).
        for handle in [clientA, clientB, clientC].compactMap({ $0 }) {
            try? handle.client.deleteLocalDatabase()
        }
        try await identityStore.delete()
        try databaseManager.erase()

        // Destroy this fixture's DTU universe so the shared server
        // doesn't accumulate state across tests. The subprocess stays
        // up for the next fixture.
        if let universe = dtuUniverse {
            await universe.destroy()
            dtuUniverse = nil
        }
    }

    // MARK: - XMTPiOS path

    private func createXMTPiOSClient(clientId: String) async throws -> ClientHandle {
        let keys = try await identityStore.generateKeys()

        let isSecure: Bool
        if let envSecure = ProcessInfo.processInfo.environment["XMTP_IS_SECURE"] {
            isSecure = envSecure.lowercased() == "true" || envSecure == "1"
        } else {
            isSecure = false
        }

        let config = MessagingClientConfig(
            apiEnv: .local,
            customLocalAddress: ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"],
            isSecure: isSecure,
            appVersion: "convos-tests/1.0.0",
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            deviceSyncEnabled: false,
            codecs: []
        )

        let client: any MessagingClient = try await XMTPiOSMessagingClient.create(
            signer: keys.signingKey,
            config: config
        )

        // Persist identity in the mock store so ConversationWriter-style
        // lookups (when/if later tests wire them) resolve.
        _ = try await identityStore.save(
            inboxId: client.inboxId,
            clientId: clientId,
            keys: keys
        )

        return ClientHandle(
            client: client,
            clientId: clientId,
            inboxAlias: client.inboxId,
            installationAlias: client.installationId
        )
    }

    // MARK: - DTU path

    /// Per-fixture universe. Each `DualBackendTestFixtures` instance
    /// gets its own universe on the shared dtu-server so that
    /// `DTUMessagingConversations`'s per-client `dtu-g-N` counter
    /// can't collide across tests (the counter is reset for each new
    /// `DTUMessagingClient`, but conversation aliases within a
    /// universe are unique — two tests both asking for `dtu-g-1`
    /// would hit "alias already in use"). Lazily initialized on the
    /// first DTU `createClient()` call.
    private var dtuUniverse: DTUUniverse?

    private func createDTUClient(clientId: String) async throws -> ClientHandle {
        let universe = try await ensureDTUUniverse()
        let userAlias = "\(aliasBase)-user-\(nextAliasIndex)"
        let inboxAlias = makeInboxAlias(index: nextAliasIndex)
        let installationAlias = "\(aliasBase)-inst-\(nextAliasIndex)"

        let factory = DTUMessagingClientFactory(universe: universe)
        let dtuClient = try await factory.attachClient(
            userAlias: userAlias,
            inboxAlias: inboxAlias,
            installationAlias: installationAlias
        )

        // Persist the DTU identity in the mock keychain store so
        // `InviteWriter.generate(...)` (and any other
        // `identityStore.identity(for:)` lookup keyed by this inbox
        // alias) can resolve. The XMTPiOS path does this above in
        // `createXMTPiOSClient`; without the mirror here,
        // `ConversationWriter.store` falls into a degraded path on
        // the DTU lane because `InviteWriter` throws `identityNotFound`
        // and the writer swallows the error (Phase 2 batch 4 gap 3).
        //
        // `KeychainIdentityKeys.generate()` produces a real secp256k1
        // private key — required because `InviteWriter.generate(...)`
        // signs the invite slug with it via
        // `SignedInvite.slug(..., privateKey:)`.
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(
            inboxId: dtuClient.inboxId,
            clientId: clientId,
            keys: keys
        )

        return ClientHandle(
            client: dtuClient,
            clientId: clientId,
            inboxAlias: inboxAlias,
            installationAlias: installationAlias
        )
    }

    /// Build a DTU inbox alias. When `aliasesHexEncoded == true`, the
    /// alias is a stable hex string derived from the fixture nonce +
    /// index so that consumers that pipe the alias through
    /// `ConversationProfile(inboxIdString:)` (which requires hex — see
    /// `ConvosAppData.ProfileHelpers`) don't trip `.invalidInboxIdHex`.
    /// Default (plain) aliases remain human-readable for assertion
    /// legibility on every other test.
    private func makeInboxAlias(index: Int) -> String {
        if aliasesHexEncoded {
            return Self.deriveHexInboxAlias(aliasBase: aliasBase, index: index)
        }
        return "\(aliasBase)-inbox-\(index)"
    }

    /// Derive a deterministic hex alias from the fixture's alias base +
    /// per-client index. We hex-encode the UTF-8 bytes of the source
    /// string, which both (a) guarantees all chars are in `[0-9a-f]`
    /// and (b) preserves uniqueness across fixtures because the source
    /// itself is already unique. Length is right-padded to 64 hex chars
    /// (32 bytes) so DTU aliases look similar in shape to real libxmtp
    /// inbox IDs even under this test-only code path.
    private static func deriveHexInboxAlias(aliasBase: String, index: Int) -> String {
        let source = "\(aliasBase)-inbox-\(index)"
        let bytes = Array(source.utf8.prefix(32))
        var hex = bytes.map { String(format: "%02x", $0) }.joined()
        // Right-pad short sources so every alias is the same length,
        // and so distinct `index` values deterministically diverge in
        // the tail even when the prefix is very short.
        while hex.count < 64 {
            hex += String(format: "%02x", (index + hex.count) & 0xff)
        }
        return hex
    }

    /// Returns the fixture-scoped DTU universe, creating it on first
    /// call. The dtu-server subprocess is shared (fast spawn reuse);
    /// the universe is NOT shared (isolates `dtu-g-N` counters and
    /// actor aliases per test).
    private func ensureDTUUniverse() async throws -> DTUUniverse {
        if let existing = dtuUniverse {
            return existing
        }
        let created = try await Self.createDTUUniverse(nonce: aliasBase)
        dtuUniverse = created
        return created
    }

    // MARK: - Shared DTU-server lifecycle

    /// Shared `dtu-server` subprocess for the entire test run.
    /// One server per run (fast reuse of the ~30ms spawn); universes
    /// are per-fixture so `dtu-g-N` conversation-alias counters can't
    /// collide across tests.
    ///
    /// The server is torn down by `tearDownSharedDTUIfNeeded`, which
    /// test classes should call from their final `+tearDown` (or
    /// leave in place — the subprocess dies with us).
    static func createDTUUniverse(nonce: String) async throws -> DTUUniverse {
        #if !os(macOS)
        throw XCTSkip("DTU backend requires macOS: DTUClient.spawn uses Process, which iOS lacks.")
        #else
        return try await DTUServerHandle.shared.createUniverse(nonce: nonce)
        #endif
    }

    public static func tearDownSharedDTUIfNeeded() async {
        #if os(macOS)
        await DTUServerHandle.shared.teardown()
        #endif
    }

    // MARK: - Binary discovery

    #if os(macOS)
    static func resolveDTUBinary() throws -> URL {
        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo.environment["DTU_SERVER_BIN"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath)
            guard fm.isExecutableFile(atPath: url.path) else {
                throw XCTSkip(
                    "DTU_SERVER_BIN=\(envPath) is not executable. "
                    + "Build with `cargo build --release -p dtu-server` under "
                    + xmtpDtuServerDir.path
                )
            }
            return url
        }
        let fallback = defaultBinaryURL
        guard fm.isExecutableFile(atPath: fallback.path) else {
            throw XCTSkip(
                """
                dtu-server binary not found at \(fallback.path).
                Build it with:
                    cd \(xmtpDtuServerDir.path) && cargo build --release -p dtu-server
                Or set DTU_SERVER_BIN to an absolute path.
                """
            )
        }
        return fallback
    }

    /// Mirrors `DTUMessagingClientSmokeTests`: this file lives at
    /// `.../xmtplabs/convos-ios-task-D/ConvosCoreDTU/Tests/ConvosCoreDTUTests/DualBackendTestFixtures.swift`
    /// → workspace parent is 5 `..` up, then `xmtp-dtu/server/`.
    private static var xmtpDtuServerDir: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // ConvosCoreDTUTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ConvosCoreDTU/
            .deletingLastPathComponent() // convos-ios-task-D/
            .deletingLastPathComponent() // xmtplabs/
            .appendingPathComponent("xmtp-dtu")
            .appendingPathComponent("server")
    }

    private static var defaultBinaryURL: URL {
        xmtpDtuServerDir
            .appendingPathComponent("target")
            .appendingPathComponent("release")
            .appendingPathComponent("dtu-server")
    }
    #endif
}

#if os(macOS)
/// Process-wide handle for the shared dtu-server subprocess. The
/// subprocess is spawned on first use and reused across every
/// DualBackendTestFixtures instance; each fixture then asks for its
/// own universe via `createUniverse(nonce:)`.
///
/// Uses a class with `NSLock` rather than an `actor` because
/// `DTUClient` is a non-Sendable `final class`; an actor would refuse
/// to hand it back to nonisolated XCTest call sites. The lock
/// protects only the initialization handshake — the underlying
/// `DTUClient` is already internally thread-safe.
final class DTUServerHandle: @unchecked Sendable {
    static let shared: DTUServerHandle = DTUServerHandle()

    private let lock: NSLock = NSLock()
    private var client: DTUClient?
    private var universeCounter: Int = 0

    /// Spawn-on-first-use. Creates a fresh universe named by the
    /// caller's nonce; each fixture gets its own universe so that
    /// DTU's per-client conversation-alias counter (`dtu-g-N`) can't
    /// collide across tests.
    func createUniverse(nonce: String) async throws -> DTUUniverse {
        let spawned = try await ensureClient()
        let id: String = lock.withLock {
            universeCounter += 1
            return "u_dualbackend_\(universeCounter)_\(nonce)"
        }
        return try await spawned.createUniverse(
            id: id,
            seedTimeNs: 1_700_000_000_000_000_000
        )
    }

    func teardown() async {
        let clientToTerminate: DTUClient? = lock.withLock {
            let c = client
            client = nil
            return c
        }
        if let clientToTerminate {
            await clientToTerminate.terminate()
        }
    }

    private func ensureClient() async throws -> DTUClient {
        if let existing = lock.withLock({ client }) {
            return existing
        }
        let binary = try DualBackendTestFixtures.resolveDTUBinary()
        let spawned: DTUClient
        do {
            spawned = try await DTUClient.spawn(binaryPath: binary)
        } catch {
            throw XCTSkip(
                """
                Could not spawn dtu-server at \(binary.path).
                Rebuild: `cd <xmtp-dtu>/server && cargo build --release -p dtu-server`.
                Underlying: \(error)
                """
            )
        }
        let health = try await spawned.health()
        guard health.status == "ok" else {
            throw XCTSkip("dtu-server health check failed: \(health.status)")
        }
        lock.withLock {
            if client == nil {
                client = spawned
            }
        }
        // Return whichever DTUClient won the race. In practice tests
        // don't race at init time; the guard is belt-and-braces.
        return lock.withLock { client } ?? spawned
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
