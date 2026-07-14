import CryptoKit
import Foundation
import Security
@preconcurrency import XMTPiOS

/// The payload carried by the URL-safe slug in a `https://<domain>/pair/<slug>`
/// pairing invite. Signed by the initiator's signing key so a joiner can:
///   1. Verify the slug actually came from someone holding the initiator's key.
///   2. Recover the initiator's address and inbox id to know which inbox to
///      DM the pairing join request to.
///   3. Reject expired or replayed slugs (singleUse + expiresAt).
public struct PairingInvite: Codable, Sendable, Equatable {
    public let schemaVersion: UInt32
    public let initiatorInboxId: String
    public let initiatorAddress: String
    public let nonce: Data
    public let issuedAt: Int64
    public let expiresAt: Int64
    public let signature: Data

    public init(
        schemaVersion: UInt32 = 1,
        initiatorInboxId: String,
        initiatorAddress: String,
        nonce: Data,
        issuedAt: Int64,
        expiresAt: Int64,
        signature: Data
    ) {
        self.schemaVersion = schemaVersion
        self.initiatorInboxId = initiatorInboxId
        self.initiatorAddress = initiatorAddress
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    /// Bytes that get signed by the initiator's private key. Order is fixed.
    public static func signingPayload(
        initiatorInboxId: String,
        initiatorAddress: String,
        nonce: Data,
        issuedAt: Int64,
        expiresAt: Int64
    ) -> Data {
        var payload = Data()
        payload.append(Data("convos-pair-invite-v1\n".utf8))
        payload.append(initiatorInboxId.data(using: .utf8) ?? Data())
        payload.append(0x0A)
        payload.append(initiatorAddress.lowercased().data(using: .utf8) ?? Data())
        payload.append(0x0A)
        payload.append(nonce)
        payload.append(0x0A)
        var issued = issuedAt.littleEndian
        payload.append(Data(bytes: &issued, count: MemoryLayout<Int64>.size))
        var expires = expiresAt.littleEndian
        payload.append(Data(bytes: &expires, count: MemoryLayout<Int64>.size))
        return payload
    }
}

public enum PairingInviteError: Error, LocalizedError, Sendable {
    case invalidSlug
    case unsupportedSchemaVersion(UInt32)
    case expired
    case signatureInvalid
    case nonceInvalid
    case nonceGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSlug:
            return "Could not decode pairing invite"
        case let .unsupportedSchemaVersion(version):
            return "Unsupported invite schema version: \(version)"
        case .expired:
            return "Pairing invite has expired"
        case .signatureInvalid:
            return "Pairing invite signature is invalid"
        case .nonceInvalid:
            return "Pairing invite nonce is invalid"
        case .nonceGenerationFailed:
            return "Could not generate pairing invite nonce"
        }
    }
}

public extension PairingInvite {
    /// URL-safe base64 encoding (no padding) of the JSON-encoded invite.
    func toURLSafeSlug() throws -> String {
        let data = try JSONEncoder().encode(self)
        return Self.base64URLEncode(data)
    }

    static func fromURLSafeSlug(_ slug: String) throws -> PairingInvite {
        guard let data = base64URLDecode(slug) else {
            throw PairingInviteError.invalidSlug
        }
        let invite: PairingInvite
        do {
            invite = try JSONDecoder().decode(PairingInvite.self, from: data)
        } catch {
            throw PairingInviteError.invalidSlug
        }
        guard invite.schemaVersion == 1 else {
            throw PairingInviteError.unsupportedSchemaVersion(invite.schemaVersion)
        }
        guard invite.nonce.count >= 16 else {
            throw PairingInviteError.nonceInvalid
        }
        let now = Int64(Date().timeIntervalSince1970)
        guard invite.expiresAt > now else {
            throw PairingInviteError.expired
        }
        try invite.verifySignature()
        return invite
    }

    /// Creates a fully-signed invite for the given identity - the same
    /// payload the initiator's QR flow encodes into a slug. Also used to
    /// mint an invite on behalf of a device whose identity was found in
    /// the iCloud-synced keychain backup: holding that backup's private
    /// key carries the same authority the QR flow proves, so
    /// `fromURLSafeSlug`'s signature check passes and the joiner's
    /// identity-share validation anchors to the expected address.
    static func signed(
        initiatorInboxId: String,
        privateKey: PrivateKey,
        expiresAt: Date
    ) async throws -> PairingInvite {
        var nonce = Data(count: 16)
        let nonceStatus: OSStatus = nonce.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecUnknownFormat }
            return SecRandomCopyBytes(kSecRandomDefault, 16, baseAddress)
        }
        guard nonceStatus == errSecSuccess else {
            throw PairingInviteError.nonceGenerationFailed
        }
        let issuedAt = Int64(Date().timeIntervalSince1970)
        let expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        let address = privateKey.walletAddress
        let payload = signingPayload(
            initiatorInboxId: initiatorInboxId,
            initiatorAddress: address,
            nonce: nonce,
            issuedAt: issuedAt,
            expiresAt: expiresAtUnix
        )
        let signature = try await privateKey.sign(payload.toHexString())
        return PairingInvite(
            initiatorInboxId: initiatorInboxId,
            initiatorAddress: address,
            nonce: nonce,
            issuedAt: issuedAt,
            expiresAt: expiresAtUnix,
            signature: signature.rawData
        )
    }

    /// Recovers the signing address from `signature` over the canonical
    /// signing payload (matches `LivePairingService.signInviteSlug`'s call
    /// to `PrivateKey.sign(payload.toHexString())`) and checks that it
    /// equals `initiatorAddress`.
    ///
    /// Without this, a slug substituted in transit (intercepted clipboard,
    /// tampered AirDrop, malicious universal-link relay) could point the
    /// joiner at an attacker's inbox while still computing a matching
    /// emoji fingerprint on both sides — the fingerprint hashes
    /// `(joinerInboxId, initiatorInboxIdFromSlug, pin)`, so an attacker
    /// who chose the slug also chose the inboxId both sides hash, and the
    /// user wouldn't catch the swap visually.
    func verifySignature() throws {
        let payload = Self.signingPayload(
            initiatorInboxId: initiatorInboxId,
            initiatorAddress: initiatorAddress,
            nonce: nonce,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let recovered: String
        do {
            recovered = try EthereumSignatureRecovery.recoverAddress(
                message: payload.toHexString(),
                signature: signature
            )
        } catch {
            throw PairingInviteError.signatureInvalid
        }
        guard recovered.lowercased() == initiatorAddress.lowercased() else {
            throw PairingInviteError.signatureInvalid
        }
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ slug: String) -> Data? {
        var padded = slug
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded)
    }
}
