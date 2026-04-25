import Foundation

// MARK: - Identifier typealiases

/// Stable type alias for an inbox's opaque identifier.
///
/// Mirrors libxmtp's `InboxId` but owned by Convos so that the DTU adapter
/// can produce compatible IDs without importing XMTPiOS.
public typealias MessagingInboxID = String

/// Stable type alias for an installation's opaque identifier.
public typealias MessagingInstallationID = String

// MARK: - Identity

/// The authentication kind that backs a `MessagingIdentity`.
///
/// Convos only passes `.ethereum` today (see audit §1.1). Adding
/// `.passkey` up front keeps the enum aligned with the libxmtp shape.
public enum MessagingIdentityKind: String, Hashable, Sendable, Codable {
    case ethereum
    case passkey
}

/// A Convos-owned mirror of `XMTPiOS.PublicIdentity`.
///
/// `identifier` is expected to be lowercased for the ethereum kind
/// (matching the convention used throughout ConvosCore).
public struct MessagingIdentity: Hashable, Sendable, Codable {
    public let kind: MessagingIdentityKind
    public let identifier: String

    public init(kind: MessagingIdentityKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

// MARK: - Signer

/// The signing surface expected of a wallet backing a `MessagingClient`.
///
/// Mirrors `XMTPiOS.SigningKey` but strips the FFI-specific shape:
/// Convos already passes these fields through today, so the rename
/// is a straight swap.
public enum MessagingSignerType: String, Hashable, Sendable, Codable {
    case eoa
    case smartContractWallet
}

/// Abstract signer. Both the current keychain-backed `PrivateKey` and
/// any future smart-contract-wallet signer conform to this.
public protocol MessagingSigner: Sendable {
    var identity: MessagingIdentity { get }
    var type: MessagingSignerType { get }
    var chainId: Int64? { get }
    var blockNumber: Int64? { get }

    /// Produces a raw signature over the challenge bytes.
    ///
    /// The adapter wraps this back into whatever native `SignedData`-style
    /// container the SDK requires.
    func sign(_ message: String) async throws -> Data
}

// MARK: - Installation / inbox state

/// A single installation record inside a `MessagingInbox`.
public struct MessagingInstallation: Hashable, Sendable, Codable {
    public let id: MessagingInstallationID
    public let createdAt: Date?

    public init(id: MessagingInstallationID, createdAt: Date?) {
        self.id = id
        self.createdAt = createdAt
    }
}

/// The observable state of a Convos inbox.
///
/// Exposes the multi-installation surface from day one so the UI layer
/// in Stage 6+ can bind to `installations` without the abstraction
/// having to change shape again.
public struct MessagingInbox: Hashable, Sendable, Codable {
    public let inboxId: MessagingInboxID
    public let identities: [MessagingIdentity]
    public let installations: [MessagingInstallation]
    public let recoveryIdentity: MessagingIdentity

    public init(
        inboxId: MessagingInboxID,
        identities: [MessagingIdentity],
        installations: [MessagingInstallation],
        recoveryIdentity: MessagingIdentity
    ) {
        self.inboxId = inboxId
        self.identities = identities
        self.installations = installations
        self.recoveryIdentity = recoveryIdentity
    }
}
