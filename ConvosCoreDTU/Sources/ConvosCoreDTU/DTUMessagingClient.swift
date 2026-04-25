import ConvosCore
import ConvosMessagingProtocols
import Foundation
import XMTPDTU

/// DTU-backed implementation of `MessagingClient`.
///
/// Wraps a `DTUUniverse` + (actor, inbox) alias pair and composes the
/// four sub-surface adapters (`conversations`, `consent`, `deviceSync`,
/// `installations`) around it. Every method forwards onto the DTU
/// universe via the shared `DTUMessagingClientContext`.
///
/// Unlike the XMTPiOS adapter, which builds itself from a config blob
/// pointing at a libxmtp server, `DTUMessagingClient` requires an
/// already-created `DTUUniverse` + actor bootstrap (create user +
/// inbox + installation) to exist. Two construction paths are provided:
///
///  1. `attach(universe:inboxAlias:installationAlias:)` — the preferred
///     API. Callers own the universe lifecycle and the bootstrap of the
///     actor aliases; the client just attaches to them. This is what
///     `DTUMessagingClientFactory` uses internally and what smoke tests
///     use directly.
///
///  2. `create(signer:config:)` / `build(identity:inboxId:config:)` —
///     the `MessagingClient` static constructors. These exist for
///     protocol conformance and take a best-effort path: they require a
///     process-wide default universe (see
///     `DTUMessagingClient.setDefaultUniverse(...)`) and derive the
///     actor alias from the signer / identity. Tests that exercise the
///     protocol surface through its generic entry points should set the
///     default universe before calling.
///
/// `@unchecked Sendable` matches the pattern used by the XMTPiOS
/// adapter. The DTU SDK's `DTUUniverse` is `@unchecked Sendable` on the
/// SDK side; this wrapper is reference-stable and only composes
/// already-Sendable sub-adapters.
public final class DTUMessagingClient: MessagingClient, @unchecked Sendable {
    let context: DTUMessagingClientContext

    public let conversations: any MessagingConversations
    public let consent: any MessagingConsent
    public let deviceSync: any MessagingDeviceSync
    public let installations: any MessagingInstallationsAPI

    // MARK: - Construction

    /// Primary entry point. Requires the caller to have already created
    /// the universe + bootstrapped the user / inbox / installation
    /// aliases via the `DTUUniverse.create*` control-plane actions.
    public init(
        universe: DTUUniverse,
        inboxAlias: String,
        installationAlias: String
    ) {
        let context = DTUMessagingClientContext(
            universe: universe,
            actor: installationAlias,
            inboxAlias: inboxAlias
        )
        self.context = context
        self.conversations = DTUMessagingConversations(context: context)
        self.consent = DTUMessagingConsent(context: context)
        self.deviceSync = DTUMessagingDeviceSync(context: context)
        self.installations = DTUMessagingInstallationsAPI(context: context)
    }

    /// Convenience initializer matching the naming convention callers
    /// reach for on other SDKs. Equivalent to the memberwise init.
    public static func attach(
        universe: DTUUniverse,
        inboxAlias: String,
        installationAlias: String
    ) -> DTUMessagingClient {
        DTUMessagingClient(
            universe: universe,
            inboxAlias: inboxAlias,
            installationAlias: installationAlias
        )
    }

    // MARK: - Identity accessors

    /// `inboxId` maps to the DTU inbox alias. Per the project's memory
    /// note, xmtp-dtu uses alias identifiers (`alice-main`) rather than
    /// libxmtp inbox IDs — the abstraction's `MessagingInboxID` is
    /// already a `String` typealias so no narrowing is needed.
    public var inboxId: MessagingInboxID { context.inboxAlias }
    public var installationId: MessagingInstallationID { context.actor }

    public var publicIdentity: MessagingIdentity {
        // DTU doesn't surface wallet identities on its wire types, so
        // we synthesize an `.ethereum`-kind identity from the inbox
        // alias. The abstraction's callers use `publicIdentity` for
        // display and comparison only (see
        // `InboxStateMachine.swift` usage); the alias is stable enough
        // for that contract.
        MessagingIdentity(kind: .ethereum, identifier: context.inboxAlias)
    }

    // MARK: - MessagingClient.create / build

    /// Process-wide default universe, set by tests or pilots before
    /// going through the generic `create` / `build` entry points.
    /// Access is serialized behind an `NSLock` — this is a test-support
    /// knob, not a production pattern.
    private static let defaultUniverseLock = NSLock()
    nonisolated(unsafe) private static var _defaultUniverse: DTUUniverse?

    /// Register a process-wide default universe. Clear with
    /// `setDefaultUniverse(nil)` after a test run completes. Smoke
    /// tests that build `DTUMessagingClient` via `attach(...)` don't
    /// need this; it's only consulted by the static `create` / `build`
    /// paths that exist for protocol conformance.
    public static func setDefaultUniverse(_ universe: DTUUniverse?) {
        defaultUniverseLock.lock()
        defer { defaultUniverseLock.unlock() }
        _defaultUniverse = universe
    }

    public static func currentDefaultUniverse() -> DTUUniverse? {
        defaultUniverseLock.lock()
        defer { defaultUniverseLock.unlock() }
        return _defaultUniverse
    }

    public static func create(
        signer: any MessagingSigner,
        config: MessagingClientConfig
    ) async throws -> Self {
        guard let universe = Self.currentDefaultUniverse() else {
            throw DTUMessagingNotSupportedError(
                method: "MessagingClient.create",
                reason: "DTUMessagingClient requires a pre-configured universe. "
                    + "Call DTUMessagingClient.setDefaultUniverse(_:) before "
                    + "invoking create(signer:config:), or use attach(...)."
            )
        }
        let alias = signer.identity.identifier
        // Bootstrap user + inbox + installation aliases in the universe
        // on a best-effort basis. DTU's create actions throw
        // `userAlreadyExists` / `inboxAlreadyExists` / `installationAlreadyExists`
        // on duplicates — we swallow those so create() is idempotent
        // for identity aliases already present.
        try await bootstrapActor(
            universe: universe,
            userAlias: alias,
            inboxAlias: alias,
            installationAlias: alias
        )
        // `Self` resolves to `DTUMessagingClient` because the class is
        // `final`. The plain init returns the final type, which is the
        // same as `Self` here, so no cast is needed.
        return Self(
            universe: universe,
            inboxAlias: alias,
            installationAlias: alias
        )
    }

    public static func build(
        identity: MessagingIdentity,
        inboxId: MessagingInboxID?,
        config: MessagingClientConfig
    ) async throws -> Self {
        guard let universe = Self.currentDefaultUniverse() else {
            throw DTUMessagingNotSupportedError(
                method: "MessagingClient.build",
                reason: "DTUMessagingClient requires a pre-configured universe. "
                    + "Call DTUMessagingClient.setDefaultUniverse(_:) before "
                    + "invoking build(identity:inboxId:config:), or use attach(...)."
            )
        }
        let alias = inboxId ?? identity.identifier
        return Self(
            universe: universe,
            inboxAlias: alias,
            installationAlias: alias
        )
    }

    // MARK: - Static ops (no client instance required)

    public static func newestMessageMetadata(
        conversationIds: [String],
        config: MessagingClientConfig
    ) async throws -> [String: MessagingMessageMetadata] {
        // DTU's `newest_message_metadata` action is scoped to a
        // universe + actor; without either we can't dispatch. The
        // abstraction's contract here is "pre-client sleeping-inbox
        // check" — DTU has no sleeping-inbox concept.
        throw DTUMessagingNotSupportedError(
            method: "MessagingClient.newestMessageMetadata (static)",
            reason: "DTU engine requires a universe + actor; no static path exists"
        )
    }

    public static func canMessage(
        identities: [MessagingIdentity],
        config: MessagingClientConfig
    ) async throws -> [String: Bool] {
        // Same reason as newestMessageMetadata above.
        throw DTUMessagingNotSupportedError(
            method: "MessagingClient.canMessage (static)",
            reason: "DTU engine requires a universe + actor; no static path exists"
        )
    }

    // MARK: - Per-instance reachability

    public func canMessage(identity: MessagingIdentity) async throws -> Bool {
        // DTU's engine doesn't expose reachability by wallet identity.
        // Return `true` as a permissive default: every DTU participant
        // exists in the same universe, so "can we message them" is
        // structurally always true for aliases the engine knows about.
        true
    }

    public func canMessage(identities: [MessagingIdentity]) async throws -> [String: Bool] {
        var out: [String: Bool] = [:]
        for identity in identities {
            out[identity.identifier] = true
        }
        return out
    }

    public func inboxId(for identity: MessagingIdentity) async throws -> MessagingInboxID? {
        // DTU uses alias identifiers directly; inbox IDs equal wallet
        // identifiers in the adapter projection.
        identity.identifier
    }

    // MARK: - Signing / verification

    public func signWithInstallationKey(_ message: String) throws -> Data {
        throw DTUMessagingNotSupportedError(
            method: "MessagingClient.signWithInstallationKey",
            reason: "DTU engine does not model installation signing keys"
        )
    }

    public func verifySignature(_ message: String, signature: Data) throws -> Bool {
        throw DTUMessagingNotSupportedError(
            method: "MessagingClient.verifySignature",
            reason: "DTU engine does not model signature verification"
        )
    }

    public func verifySignature(
        _ message: String,
        signature: Data,
        installationId: MessagingInstallationID
    ) throws -> Bool {
        throw DTUMessagingNotSupportedError(
            method: "MessagingClient.verifySignature(installationId:)",
            reason: "DTU engine does not model signature verification"
        )
    }

    // MARK: - DB lifecycle

    public func deleteLocalDatabase() throws {
        // DTU has no persistent local DB — the universe is the only
        // store and is destroyed via `DTUUniverse.destroy()`. Treating
        // `deleteLocalDatabase` as a no-op matches callers' intent on
        // logout flows (Convos uses this to evict local MLS state).
    }

    public func reconnectLocalDatabase() async throws {
        // No local DB to reconnect to. No-op.
    }

    public func dropLocalDatabaseConnection() throws {
        // No local DB connection to drop. No-op.
    }
}

// MARK: - Bootstrap helper

/// Best-effort bootstrap of a user / inbox / installation alias triple
/// in a DTU universe. Idempotent: duplicate-alias errors from the engine
/// are treated as success so the same client can be reconstructed across
/// test steps.
func bootstrapActor(
    universe: DTUUniverse,
    userAlias: String,
    inboxAlias: String,
    installationAlias: String
) async throws {
    do {
        try await universe.createUser(id: userAlias)
    } catch DTUError.userAlreadyExists {
        // idempotent
    }
    do {
        try await universe.createInbox(inboxId: inboxAlias, userId: userAlias)
    } catch DTUError.inboxAlreadyExists {
        // idempotent
    }
    do {
        try await universe.createInstallation(
            installationId: installationAlias,
            inboxId: inboxAlias
        )
    } catch DTUError.installationAlreadyExists {
        // idempotent
    }
}
