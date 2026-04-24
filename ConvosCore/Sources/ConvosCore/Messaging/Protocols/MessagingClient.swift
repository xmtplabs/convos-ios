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
