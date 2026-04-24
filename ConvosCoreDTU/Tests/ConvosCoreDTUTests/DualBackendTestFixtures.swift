@testable import ConvosCore
@testable import ConvosCoreDTU
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

    public var clientA: ClientHandle?
    public var clientB: ClientHandle?
    public var clientC: ClientHandle?

    public init(backend: Backend = .selected, aliasPrefix: String = "actor") {
        self.backend = backend
        self.environment = .tests
        self.identityStore = MockKeychainIdentityStore()
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
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
        try await identityStore.deleteAll()
        try databaseManager.erase()
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

    private func createDTUClient(clientId: String) async throws -> ClientHandle {
        let universe = try await Self.sharedDTUUniverse()
        let userAlias = "\(aliasBase)-user-\(nextAliasIndex)"
        let inboxAlias = "\(aliasBase)-inbox-\(nextAliasIndex)"
        let installationAlias = "\(aliasBase)-inst-\(nextAliasIndex)"

        let factory = DTUMessagingClientFactory(universe: universe)
        let dtuClient = try await factory.attachClient(
            userAlias: userAlias,
            inboxAlias: inboxAlias,
            installationAlias: installationAlias
        )

        return ClientHandle(
            client: dtuClient,
            clientId: clientId,
            inboxAlias: inboxAlias,
            installationAlias: installationAlias
        )
    }

    // MARK: - Shared DTU-server lifecycle

    /// Shared `dtu-server` subprocess + universe for the entire test run.
    ///
    /// Per the POC brief: one server per run, not per test. Spawning
    /// dtu-server takes ~30ms; the test run would burn time spinning
    /// it up per-fixture. The universe is reused across every test
    /// (aliases are uniquified per-fixture via `aliasBase`).
    ///
    /// The shared handle is torn down by `tearDownSharedDTUIfNeeded`,
    /// which test classes should call from their final `+tearDown` (or
    /// leave in place for the process to clean up; the server is a
    /// subprocess that dies with us).
    public static func sharedDTUUniverse() async throws -> DTUUniverse {
        #if !os(macOS)
        throw XCTSkip("DTU backend requires macOS: DTUClient.spawn uses Process, which iOS lacks.")
        #else
        try await DTUServerHandle.shared.universe()
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
/// Process-wide shared handle for the dtu-server subprocess + its
/// universe. Synchronized via a Mutex so concurrent-fixture setup
/// (parallel XCTest cases) doesn't race the spawn.
///
/// Uses a class with `NSLock` rather than an `actor` because
/// `DTUClient` is a non-Sendable `final class`; an actor would refuse
/// to hand it back to nonisolated XCTest call sites. The lock
/// protects only the initialization handshake — the underlying
/// `DTUClient` is already internally thread-safe.
///
/// Lifecycle:
///   - First `universe()` call spawns `dtu-server` and creates a
///     universe seeded at the canonical test time.
///   - Subsequent calls reuse the same handle.
///   - `teardown()` destroys the universe and terminates the server.
///     Idempotent.
final class DTUServerHandle: @unchecked Sendable {
    static let shared = DTUServerHandle()

    private let lock = NSLock()
    private var client: DTUClient?
    private var cachedUniverse: DTUUniverse?
    private var universeCounter: Int = 0

    func universe() async throws -> DTUUniverse {
        // Fast path: return cached universe if already set.
        if let existing = readCachedUniverse() {
            return existing
        }
        // Initialize inline. If two callers race here they'll both
        // attempt to spawn; the second caller will observe the first's
        // client via the lock and no-op the second spawn. Separate
        // `ensureClient()` handles that.
        let spawned = try await ensureClient()
        let id: String = lock.withLock {
            universeCounter += 1
            return "u_dualbackend_\(universeCounter)"
        }
        let universe = try await spawned.createUniverse(
            id: id,
            seedTimeNs: 1_700_000_000_000_000_000
        )
        lock.withLock {
            if cachedUniverse == nil {
                cachedUniverse = universe
            }
        }
        // Return the canonical cached instance to avoid handing out
        // two different universe handles if a second caller raced us.
        return readCachedUniverse() ?? universe
    }

    func teardown() async {
        let (universeToDestroy, clientToTerminate): (DTUUniverse?, DTUClient?) = lock.withLock {
            let u = cachedUniverse
            let c = client
            cachedUniverse = nil
            client = nil
            return (u, c)
        }
        if let universeToDestroy {
            await universeToDestroy.destroy()
        }
        if let clientToTerminate {
            await clientToTerminate.terminate()
        }
    }

    private func readCachedUniverse() -> DTUUniverse? {
        lock.withLock { cachedUniverse }
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
