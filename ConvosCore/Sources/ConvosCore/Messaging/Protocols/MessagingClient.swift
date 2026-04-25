import Foundation

// MARK: - Environment / config

/// Deployment environment for the messaging backend.
public enum MessagingEnv: String, Hashable, Sendable, Codable {
    case local
    case dev
    case production
}

/// Per-client configuration.
///
/// Replaces the global mutable `XMTPEnvironment.customLocalAddress`
/// footgun (`InboxStateMachine.swift:328-334,1127-1135`, audit §2).
/// Every field lives here so running two clients side by side with
/// different endpoints becomes structurally possible — a prerequisite
/// for the future multi-inbox work (audit open question #2).
public struct MessagingClientConfig: Sendable {
    public var apiEnv: MessagingEnv

    /// Override for `.local` environments. Nil means "use the default
    /// for `apiEnv`". This replaces the global in XMTPEnvironment.
    public var customLocalAddress: String?

    public var isSecure: Bool
    public var appVersion: String?

    /// Raw bytes used to encrypt the on-disk libxmtp DB.
    public var dbEncryptionKey: Data

    /// Optional override for where the libxmtp DB is stored. Nil uses
    /// the SDK default.
    public var dbDirectory: String?

    /// Toggles device-sync. Convos currently sets `false`
    /// (`InboxStateMachine.swift:1119`); flipping this is the Stage 5+
    /// multi-installation gate.
    public var deviceSyncEnabled: Bool

    /// Codecs to register with the client at construction time.
    /// Adapter is responsible for actually installing them.
    public var codecs: [any MessagingCodec]

    public init(
        apiEnv: MessagingEnv,
        customLocalAddress: String? = nil,
        isSecure: Bool,
        appVersion: String? = nil,
        dbEncryptionKey: Data,
        dbDirectory: String? = nil,
        deviceSyncEnabled: Bool = false,
        codecs: [any MessagingCodec] = []
    ) {
        self.apiEnv = apiEnv
        self.customLocalAddress = customLocalAddress
        self.isSecure = isSecure
        self.appVersion = appVersion
        self.dbEncryptionKey = dbEncryptionKey
        self.dbDirectory = dbDirectory
        self.deviceSyncEnabled = deviceSyncEnabled
        self.codecs = codecs
    }
}

// MARK: - Client

/// Top-level messaging client.
///
/// Convos-owned mirror of `XMTPiOS.Client`. The five sub-surfaces
/// (`conversations`, `consent`, `deviceSync`, `installations`) keep
/// related operations grouped instead of exploding 40 methods onto a
/// single type, matching both the libxmtp grouping and the DTU design.
public protocol MessagingClient: AnyObject, Sendable {
    var inboxId: MessagingInboxID { get }
    var installationId: MessagingInstallationID { get }
    var publicIdentity: MessagingIdentity { get }

    var conversations: any MessagingConversations { get }
    var consent: any MessagingConsent { get }
    var deviceSync: any MessagingDeviceSync { get }
    var installations: any MessagingInstallationsAPI { get }

    // MARK: Construction

    /// Builds a brand-new client, signing the creation with the
    /// supplied `signer`. First-run flow.
    static func create(
        signer: any MessagingSigner,
        config: MessagingClientConfig
    ) async throws -> Self

    /// Rehydrates an existing client from the local DB.
    /// Does NOT hit the network unless the adapter needs to confirm
    /// inbox membership. If `inboxId` is nil, the adapter computes
    /// it from `identity`.
    static func build(
        identity: MessagingIdentity,
        inboxId: MessagingInboxID?,
        config: MessagingClientConfig
    ) async throws -> Self

    // MARK: Static ops (no client instance required)

    /// Used by `SleepingInboxMessageChecker` to poll for new messages
    /// without spinning up a full client.
    static func newestMessageMetadata(
        conversationIds: [String],
        config: MessagingClientConfig
    ) async throws -> [String: MessagingMessageMetadata]

    /// Bulk "can I send to these?" lookup, pre-client.
    static func canMessage(
        identities: [MessagingIdentity],
        config: MessagingClientConfig
    ) async throws -> [String: Bool]

    // MARK: Per-instance reachability

    func canMessage(identity: MessagingIdentity) async throws -> Bool
    func canMessage(identities: [MessagingIdentity]) async throws -> [String: Bool]
    func inboxId(for identity: MessagingIdentity) async throws -> MessagingInboxID?

    // MARK: Signing / verification

    /// Signs a challenge with the current installation's key.
    func signWithInstallationKey(_ message: String) throws -> Data

    /// Verifies a signature was produced by *this* installation.
    func verifySignature(_ message: String, signature: Data) throws -> Bool

    /// Verifies a signature was produced by the specified installation.
    func verifySignature(
        _ message: String,
        signature: Data,
        installationId: MessagingInstallationID
    ) throws -> Bool

    // MARK: DB lifecycle

    func deleteLocalDatabase() throws
    func reconnectLocalDatabase() async throws
    func dropLocalDatabaseConnection() throws
}

// MARK: - Stage 6e Phase A bridge

public extension MessagingClient {
    /// Stage 6e Phase A bridge: lift this `MessagingClient` back down to
    /// the legacy `XMTPClientProvider` surface for callers that have
    /// not yet migrated. Phase C removes this accessor.
    ///
    /// The default implementation handles two cases that pass tests today:
    /// 1. `XMTPiOSMessagingClient` (the prod XMTPiOS-backed path) — return the
    ///    underlying `XMTPiOS.Client`.
    /// 2. The conformer is *also* an `XMTPClientProvider` directly —
    ///    return `self`. This case exists for the test mocks (e.g.
    ///    `TestableMockClient` in `SyncingManagerTests.swift`) that
    ///    historically conformed to `XMTPClientProvider` and now
    ///    additionally conform to `MessagingClient` for the public
    ///    SyncingManager surface.
    /// Non-XMTPiOS conformers (DTU) deliberately `preconditionFailure`
    /// here; Phase C retires the legacy provider entirely and the DTU
    /// integration tests are unskipped at that point.
    var legacyProvider: any XMTPClientProvider {
        if let xmtpiOS = self as? XMTPiOSMessagingClient {
            return xmtpiOS.xmtpClient
        }
        if let direct = self as? any XMTPClientProvider {
            return direct
        }
        preconditionFailure(
            "MessagingClient.legacyProvider is a Phase A bridge for XMTPiOS-backed clients (or test doubles that double-conform to XMTPClientProvider). Non-XMTPiOS clients should be migrated to the MessagingClient surface in Phase B/C."
        )
    }

    /// Stage 6e Phase A compatibility shim: pre-flip, callers reached
    /// for `inboxReady.client.messagingClient` to lift the legacy
    /// `XMTPClientProvider` into a `MessagingClient`. Post-flip,
    /// `inboxReady.client` already IS a `MessagingClient`; this
    /// accessor returns `self` so the existing call sites keep
    /// compiling without churn. Phase B removes both this shim and
    /// the call sites that route through it.
    var messagingClient: any MessagingClient { self }

    /// Stage 6e Phase A: routes the legacy `messagingConversation(with:)`
    /// helper (previously defined on `XMTPClientProvider` in
    /// `XMTPiOSConversationAdapter.swift`) through the abstraction's
    /// `conversations.find(conversationId:)` so that callers holding
    /// `inboxReady.client` as `any MessagingClient` keep compiling.
    /// Backend-agnostic — XMTPiOS and DTU both back `find`.
    func messagingConversation(
        with conversationId: String
    ) async throws -> MessagingConversation? {
        try await conversations.find(conversationId: conversationId)
    }

    /// Stage 6e Phase A: convenience for callers that need the
    /// `MessagingGroup` subtype directly. Returns `nil` for DMs.
    /// Mirrors the legacy `XMTPClientProvider.messagingGroup(with:)`.
    func messagingGroup(
        with conversationId: String
    ) async throws -> (any MessagingGroup)? {
        guard let conversation = try await messagingConversation(with: conversationId) else {
            return nil
        }
        if case .group(let group) = conversation {
            return group
        }
        return nil
    }
}
