@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosInvites
import ConvosMessagingProtocols
import ConvosProfiles
import Foundation
import GRDB
import XMTPDTU
@preconcurrency import XMTPiOS

/// Stage 6e Phase C: backend-aware bridge for the migrated
/// state-machine / lifecycle / consumption tests.
///
/// Originally a Stage 6f shim that hard-coded XMTPiOS-only client
/// construction (and skipped on the DTU lane via
/// `LegacyFixtureBackendGuard`). With Stage 6e Phase A having flipped
/// `MessagingClientFactory.{create,build}Client` to return
/// `any MessagingClient`, the legacy tests can now exercise either
/// backend. `LegacyTestFixtures` mirrors the dual-backend pattern
/// already established in `DualBackendTestFixtures`:
///
///  - `xmtpiOS` mode: `Client.create` against the same Docker-backed
///    XMTP node `TestFixtures` already pointed at (`XMTP_NODE_ADDRESS`).
///    Returns the underlying `XMTPiOSMessagingClient` so InboxStateMachine
///    can authorize through it without touching the network twice.
///
///  - `dtu` mode: spawns a per-fixture `DTUUniverse` on the shared
///    `dtu-server` subprocess and bootstraps a `DTUMessagingClient`
///    via `DTUMessagingClientFactory.attachClient`. Tests that drive
///    the production InboxStateMachine through a registration flow
///    must inject `messagingClientFactory` (provided here) so the
///    state machine reaches the DTU backend.
///
/// Backend selection is via `CONVOS_MESSAGING_BACKEND=xmtpiOS|dtu`
/// (default xmtpiOS) — same env-var convention as
/// `DualBackendTestFixtures`.
final class LegacyTestFixtures {
    enum Backend: String {
        case xmtpiOS
        case dtu

        static var selected: Backend {
            guard let raw = ProcessInfo.processInfo.environment["CONVOS_MESSAGING_BACKEND"],
                  let backend = Backend(rawValue: raw) else {
                return .xmtpiOS
            }
            return backend
        }
    }

    let backend: Backend
    let environment: AppEnvironment
    let identityStore: MockKeychainIdentityStore
    let keychainService: MockKeychainService
    let databaseManager: MockDatabaseManager

    var clientA: (any MessagingClient)?
    var clientB: (any MessagingClient)?
    var clientC: (any MessagingClient)?

    var clientIdA: String?
    var clientIdB: String?
    var clientIdC: String?

    /// DTU universe owned by this fixture (per-fixture isolation, mirrors
    /// `DualBackendTestFixtures.dtuUniverse`). XMTPiOS mode leaves this nil.
    private var dtuUniverse: DTUUniverse?
    private let aliasBase: String
    private var nextAliasIndex: Int = 0

    init(backend: Backend = .selected) {
        self.backend = backend
        self.environment = .tests
        self.identityStore = MockKeychainIdentityStore()
        self.keychainService = MockKeychainService()
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
        self.aliasBase = "legacy-\(UUID().uuidString.prefix(8))"

        ConvosLog.configure(environment: .tests)

        DeviceInfo.resetForTesting()
        DeviceInfo.configure(MockDeviceInfoProvider())
        PushNotificationRegistrar.resetForTesting()
        PushNotificationRegistrar.configure(MockPushNotificationRegistrarProvider())

        if backend == .xmtpiOS,
           let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
            XMTPEnvironment.customLocalAddress = endpoint
        }
    }

    /// Factory the migrated state-machine tests must inject into
    /// `InboxStateMachine` so the state machine reaches the right
    /// backend. XMTPiOS mode returns the production shared factory;
    /// DTU mode returns a `DTUMessagingClientFactoryAdapter` bound to
    /// this fixture's universe.
    func messagingClientFactory() async throws -> any MessagingClientFactory {
        switch backend {
        case .xmtpiOS:
            return XMTPiOSMessagingClientFactory.shared
        case .dtu:
            let universe = try await ensureDTUUniverse()
            return DTUMessagingClientFactoryAdapter(universe: universe)
        }
    }

    /// Builds an `UnusedConversationCache` wired to this fixture's
    /// backend. Tests that go through `consumeOrCreateMessagingService`
    /// use this so the cache's internal `AuthorizeInboxOperation`
    /// reaches the right `MessagingClientFactory` (XMTPiOS by default,
    /// DTU when `CONVOS_MESSAGING_BACKEND=dtu`).
    func unusedConversationCache(
        keychainService: any KeychainServiceProtocol = MockKeychainService(),
        platformProviders: PlatformProviders = .mock,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        apiClient: (any ConvosAPIClientProtocol)? = nil
    ) async throws -> UnusedConversationCache {
        let factory = try await messagingClientFactory()
        return UnusedConversationCache(
            keychainService: keychainService,
            identityStore: identityStore,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient,
            messagingClientFactory: factory
        )
    }

    /// Creates a real backend-backed client, wrapped in `any MessagingClient`.
    /// XMTPiOS path mirrors the legacy `TestFixtures.createClient`; DTU
    /// path mirrors `DualBackendTestFixtures.createDTUClient`.
    func createClient() async throws -> (
        client: any MessagingClient,
        clientId: String,
        keys: KeychainIdentityKeys
    ) {
        switch backend {
        case .xmtpiOS:
            return try await createXMTPiOSClient()
        case .dtu:
            return try await createDTUClient()
        }
    }

    func createTestClients() async throws {
        let (a, aId, _) = try await createClient()
        let (b, bId, _) = try await createClient()
        let (c, cId, _) = try await createClient()

        clientA = a
        clientB = b
        clientC = c
        clientIdA = aId
        clientIdB = bId
        clientIdC = cId
    }

    func cleanup() async throws {
        if let client = clientA {
            try? client.deleteLocalDatabase()
        }
        if let client = clientB {
            try? client.deleteLocalDatabase()
        }
        if let client = clientC {
            try? client.deleteLocalDatabase()
        }

        try await identityStore.deleteAll()
        try databaseManager.erase()

        if let universe = dtuUniverse {
            await universe.destroy()
            dtuUniverse = nil
        }
    }

    // MARK: - XMTPiOS path

    private func createXMTPiOSClient() async throws -> (
        client: any MessagingClient,
        clientId: String,
        keys: KeychainIdentityKeys
    ) {
        let keys = try await identityStore.generateKeys()
        let clientId = ClientId.generate().value

        let isSecure: Bool
        if let envSecure = ProcessInfo.processInfo.environment["XMTP_IS_SECURE"] {
            isSecure = envSecure.lowercased() == "true" || envSecure == "1"
        } else {
            isSecure = false
        }

        let clientOptions = ClientOptions(
            api: .init(
                env: .local,
                isSecure: isSecure,
                appVersion: "convos-tests/1.0.0"
            ),
            codecs: [
                TextCodec(),
                ReplyCodec(),
                ReactionV2Codec(),
                ReactionCodec(),
                AttachmentCodec(),
                RemoteAttachmentCodec(),
                GroupUpdatedCodec(),
                ExplodeSettingsCodec(),
                InviteJoinErrorCodec(),
                ProfileUpdateCodec(),
                ProfileSnapshotCodec(),
                JoinRequestCodec(),
                TypingIndicatorCodec()
            ],
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory
        )

        // Stage 4f wraps the signer behind `MessagingSigner`; the legacy
        // path here needs the native XMTPiOS `SigningKey` so we wrap
        // through `XMTPiOSSigningKeyAdapter` like the factory does.
        let signingKey = XMTPiOSSigningKeyAdapter(keys.signingKey)
        let xmtpClient = try await Client.create(account: signingKey, options: clientOptions)
        let messagingClient: any MessagingClient = XMTPiOSMessagingClient(xmtpClient: xmtpClient)
        _ = try await identityStore.save(inboxId: messagingClient.inboxId, clientId: clientId, keys: keys)
        return (messagingClient, clientId, keys)
    }

    // MARK: - DTU path

    private func createDTUClient() async throws -> (
        client: any MessagingClient,
        clientId: String,
        keys: KeychainIdentityKeys
    ) {
        let universe = try await ensureDTUUniverse()
        nextAliasIndex += 1
        let userAlias = "\(aliasBase)-user-\(nextAliasIndex)"
        let inboxAlias = "\(aliasBase)-inbox-\(nextAliasIndex)"
        let installationAlias = "\(aliasBase)-inst-\(nextAliasIndex)"

        let factory = DTUMessagingClientFactory(universe: universe)
        let dtuClient = try await factory.attachClient(
            userAlias: userAlias,
            inboxAlias: inboxAlias,
            installationAlias: installationAlias
        )

        // Mirror DualBackendTestFixtures: persist a real KeychainIdentityKeys
        // so InviteWriter / identity lookups can resolve. DTU's signer flow
        // is alias-based, but the keys are required for any code path that
        // signs invite slugs.
        let keys = try await identityStore.generateKeys()
        let clientId = ClientId.generate().value
        _ = try await identityStore.save(inboxId: dtuClient.inboxId, clientId: clientId, keys: keys)

        return (dtuClient, clientId, keys)
    }

    /// Returns the fixture-scoped DTU universe, creating it on first call.
    /// Mirrors `DualBackendTestFixtures.ensureDTUUniverse`.
    private func ensureDTUUniverse() async throws -> DTUUniverse {
        if let existing = dtuUniverse {
            return existing
        }
        let created = try await DualBackendTestFixtures.createDTUUniverse(nonce: aliasBase)
        dtuUniverse = created
        return created
    }
}

// MARK: - DTU MessagingClientFactory adapter

/// Test-only adapter that lets the production `InboxStateMachine`
/// (which takes `any MessagingClientFactory`) reach a DTU backend.
///
/// `MessagingClientFactory` carries XMTPiOS-typed parameters
/// (`[any ContentCodec]`, `ClientOptions.Api`) for legacy compatibility
/// with `SleepingInboxMessageChecker`-style static ops. On the DTU
/// lane we ignore those — DTU doesn't model codecs the same way and
/// has no static `apiOptions` equivalent. The adapter delegates to
/// `DTUMessagingClientFactory.attachClient(...)` which already handles
/// the universe + actor bootstrap.
///
/// The signer's identity `identifier` is used as the DTU alias triple
/// (user / inbox / installation) — same convention as
/// `DTUMessagingClientFactory.createClient(signer:config:)`. Caller
/// (InboxStateMachine) picks up the resulting `inboxId` from the
/// returned `any MessagingClient` to persist in the keychain.
final class DTUMessagingClientFactoryAdapter: MessagingClientFactory {
    let universe: DTUUniverse

    init(universe: DTUUniverse) {
        self.universe = universe
    }

    func createClient(
        signer: any MessagingSigner,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any MessagingClient {
        // DTU's universe-bootstrap is alias-based; derive a stable
        // alias from the signer's identity identifier so that build()
        // and create() with the same signer resolve to the same actor.
        let alias = signer.identity.identifier
        let factory = DTUMessagingClientFactory(universe: universe)
        return try await factory.attachClient(
            userAlias: alias,
            inboxAlias: alias,
            installationAlias: alias
        )
    }

    func buildClient(
        inboxId: String,
        identity: MessagingIdentity,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any MessagingClient {
        // DTU's universe is the source of truth — there's no on-disk
        // libxmtp DB to rehydrate from. "Build" just attaches without
        // a fresh bootstrap so we don't double-create user aliases.
        let alias = inboxId.isEmpty ? identity.identifier : inboxId
        let factory = DTUMessagingClientFactory(universe: universe)
        return try await factory.attachClient(
            userAlias: alias,
            inboxAlias: alias,
            installationAlias: alias,
            bootstrap: false
        )
    }

    func apiOptions(config: MessagingClientConfig) -> ClientOptions.Api {
        // DTU has no static `apiOptions` equivalent. Return a default
        // `Api` shape so callers that read it for logging-only purposes
        // (`SleepingInboxMessageChecker`) don't trap. No-one on the DTU
        // lane should be calling this — it's a `MessagingClientFactory`
        // protocol requirement that legacy callers still rely on.
        ClientOptions.Api(
            env: .local,
            isSecure: config.isSecure,
            appVersion: config.appVersion ?? "convos-dtu-tests/1.0.0"
        )
    }
}

// MARK: - Backend guard

/// Helper for migrated tests that originally gated on the legacy
/// `XMTPClientProvider` surface. After Stage 6e Phase C, the
/// state-machine / consumption tests use `LegacyTestFixtures` in
/// backend-aware mode (XMTPiOS or DTU). Tests that *still* require
/// real Docker XMTP + XMTPiOS-only flows (e.g. invite group creation,
/// `Client`-cast group ops) keep using `shouldRun(reason:)` — that
/// path still skips on DTU.
///
/// Tests that have been migrated off the XMTPiOS-only surface should
/// use `shouldRunDualBackend(reason:)`, which permits both backends
/// (provided XMTP_NODE_ADDRESS is set when running XMTPiOS).
enum LegacyFixtureBackendGuard {
    static var shouldSkipDTU: Bool {
        if let raw = ProcessInfo.processInfo.environment["CONVOS_MESSAGING_BACKEND"],
           raw == "dtu" {
            return true
        }
        return false
    }

    /// Returns true when the test should run, false when it should
    /// skip (DTU lane or missing XMTP_NODE_ADDRESS). XMTPiOS-only
    /// tests should keep using this guard.
    @discardableResult
    static func shouldRun(reason: String) -> Bool {
        if shouldSkipDTU {
            print("[dtu skip] \(reason)")
            return false
        }
        guard let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] else {
            print("[xmtpiOS skip] XMTP_NODE_ADDRESS is unset; cannot run \(reason)")
            return false
        }
        XMTPEnvironment.customLocalAddress = endpoint
        return true
    }

    /// Returns true when the test should run on EITHER backend.
    /// Stage 6e Phase C: tests that exercise the `MessagingClient`
    /// abstraction surface (no XMTPiOS-only casts) can use this guard
    /// to enable the DTU lane. XMTPiOS still needs `XMTP_NODE_ADDRESS`.
    @discardableResult
    static func shouldRunDualBackend(reason: String) -> Bool {
        let backend = LegacyTestFixtures.Backend.selected
        switch backend {
        case .dtu:
            return true
        case .xmtpiOS:
            guard let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] else {
                print("[xmtpiOS skip] XMTP_NODE_ADDRESS is unset; cannot run \(reason)")
                return false
            }
            XMTPEnvironment.customLocalAddress = endpoint
            return true
        }
    }
}
