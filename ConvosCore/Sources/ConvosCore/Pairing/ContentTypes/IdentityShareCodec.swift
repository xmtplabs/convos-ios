import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeIdentityShare = ContentTypeID(
    authorityID: "convos.org",
    typeID: "identity_share",
    versionMajor: 1,
    versionMinor: 0
)

/// Payload transferred from initiator to joiner during a device pairing
/// handshake. Carries exactly the identity material that needs to live
/// on both devices: the secp256k1 signing key. Everything else
/// (databaseKey, clientId, libxmtp installation) is regenerated on the
/// joiner. The receiving device must validate that the address recovered
/// from `privateKeyData` matches the address it expected from the
/// `SignedInvite` slug before persisting anything.
public struct IdentityShareContent: Codable, Sendable, Equatable {
    public let schemaVersion: UInt32
    public let privateKeyData: Data
    public let inboxId: String
    public let issuedAt: Int64
    public let initiatorDeviceName: String?
    /// The initiator's profile display name (from `DBMyProfile.name`). The
    /// joiner uses this to seed its own `DBMyProfile` so the user doesn't
    /// get sent through the in-conversation onboarding name prompt again.
    public let displayName: String?
    /// The initiator's profile photo asset URL (from
    /// `DBMyProfile.imageAssetIdentifier`). The joiner writes this into
    /// its own `DBMyProfile.imageAssetIdentifier` so subsequent UI loads
    /// can pull the image lazily; we don't ship the raw bytes here to
    /// keep the DM small.
    public let imageAssetIdentifier: String?

    public init(
        schemaVersion: UInt32 = 1,
        privateKeyData: Data,
        inboxId: String,
        issuedAt: Int64 = Int64(Date().timeIntervalSince1970),
        initiatorDeviceName: String? = nil,
        displayName: String? = nil,
        imageAssetIdentifier: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.privateKeyData = privateKeyData
        self.inboxId = inboxId
        self.issuedAt = issuedAt
        self.initiatorDeviceName = initiatorDeviceName
        self.displayName = displayName
        self.imageAssetIdentifier = imageAssetIdentifier
    }
}

public enum IdentityShareCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat
    case unsupportedSchemaVersion(UInt32)
    case invalidPrivateKeyLength(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "IdentityShare content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for IdentityShare"
        case let .unsupportedSchemaVersion(version):
            return "Unsupported IdentityShare schema version: \(version)"
        case let .invalidPrivateKeyLength(length):
            return "Invalid private key length: \(length) bytes (expected 32)"
        }
    }
}

public struct IdentityShareCodec: ContentCodec {
    public typealias T = IdentityShareContent

    public var contentType: ContentTypeID = ContentTypeIdentityShare

    public init() {}

    public func encode(content: IdentityShareContent) throws -> EncodedContent {
        guard content.privateKeyData.count == 32 else {
            throw IdentityShareCodecError.invalidPrivateKeyLength(content.privateKeyData.count)
        }
        var encoded = EncodedContent()
        encoded.type = ContentTypeIdentityShare
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> IdentityShareContent {
        guard !content.content.isEmpty else {
            throw IdentityShareCodecError.emptyContent
        }
        let decoded: IdentityShareContent
        do {
            decoded = try JSONDecoder().decode(IdentityShareContent.self, from: content.content)
        } catch {
            throw IdentityShareCodecError.invalidJSONFormat
        }
        guard decoded.schemaVersion == 1 else {
            throw IdentityShareCodecError.unsupportedSchemaVersion(decoded.schemaVersion)
        }
        guard decoded.privateKeyData.count == 32 else {
            throw IdentityShareCodecError.invalidPrivateKeyLength(decoded.privateKeyData.count)
        }
        return decoded
    }

    public func fallback(content: IdentityShareContent) throws -> String? {
        nil
    }

    public func shouldPush(content: IdentityShareContent) throws -> Bool {
        false
    }
}
