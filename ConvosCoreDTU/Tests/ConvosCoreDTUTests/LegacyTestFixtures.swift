@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosInvites
import ConvosProfiles
import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// Stage 6f shim: bridges the legacy `TestFixtures` from
/// `ConvosCore/Tests/ConvosCoreTests/TestHelpers.swift` into the
/// `ConvosCoreDTUTests` target so the migrated state-machine /
/// lifecycle / consumption tests can keep their original API.
///
/// This DOES talk to XMTPiOS directly (legacy `Client.create`) — the
/// migrated tests still drive `XMTPClientProvider` because Stage 6's
/// state-machine prod code rewrite has not landed in this run. On the
/// DTU lane these tests skip cleanly via `guardXMTPiOSBackend`; on
/// the XMTPiOS lane they speak to the same Docker-backed XMTP node
/// that `TestFixtures` already pointed at (`XMTP_NODE_ADDRESS`).
///
/// This file intentionally duplicates the surface of the legacy
/// `TestFixtures` so the migrated tests stay diff-minimal.
final class LegacyTestFixtures {
    let environment: AppEnvironment
    let identityStore: MockKeychainIdentityStore
    let keychainService: MockKeychainService
    let databaseManager: MockDatabaseManager

    var clientA: (any XMTPClientProvider)?
    var clientB: (any XMTPClientProvider)?
    var clientC: (any XMTPClientProvider)?

    var clientIdA: String?
    var clientIdB: String?
    var clientIdC: String?

    init() {
        self.environment = .tests
        self.identityStore = MockKeychainIdentityStore()
        self.keychainService = MockKeychainService()
        self.databaseManager = MockDatabaseManager.makeTestDatabase()

        ConvosLog.configure(environment: .tests)

        DeviceInfo.resetForTesting()
        DeviceInfo.configure(MockDeviceInfoProvider())
        PushNotificationRegistrar.resetForTesting()
        PushNotificationRegistrar.configure(MockPushNotificationRegistrarProvider())

        if let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
            XMTPEnvironment.customLocalAddress = endpoint
        }
    }

    /// Creates a real XMTPiOS-backed client (legacy
    /// `XMTPClientProvider`). Mirrors the legacy `TestFixtures.createClient`
    /// — duplicated here so migrated tests preserve exact behavior.
    func createClient() async throws -> (
        client: any XMTPClientProvider,
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
        let client = try await Client.create(account: signingKey, options: clientOptions)
        _ = try await identityStore.save(inboxId: client.inboxId, clientId: clientId, keys: keys)
        return (client, clientId, keys)
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
    }
}

// MARK: - Backend guard

/// Helper for migrated tests that still rely on the legacy
/// `XMTPClientProvider` surface and a Docker-backed XMTP node.
/// On the DTU lane, calling `shouldSkipDTU()` returns true so the
/// test body should early-return cleanly without asserting failure.
///
/// Modeled on `guardXMTPiOSBackend` in
/// `ProfileMessageIntegrationTests.swift`, but adapted for
/// swift-testing's `@Test` macro (no XCTSkip equivalent — instead
/// the test body returns early after an explanatory log).
enum LegacyFixtureBackendGuard {
    /// Returns true when the test should skip because the DTU
    /// backend is selected.
    static var shouldSkipDTU: Bool {
        if let raw = ProcessInfo.processInfo.environment["CONVOS_MESSAGING_BACKEND"],
           raw == "dtu" {
            return true
        }
        return false
    }

    /// Returns true when the test should run, false when it should
    /// skip (DTU lane or missing XMTP_NODE_ADDRESS). Logs the reason.
    /// Side effect: when running, sets `XMTPEnvironment.customLocalAddress`
    /// from `XMTP_NODE_ADDRESS` so the legacy `Client.create` path
    /// hits the same Docker node `TestFixtures` used.
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
}
