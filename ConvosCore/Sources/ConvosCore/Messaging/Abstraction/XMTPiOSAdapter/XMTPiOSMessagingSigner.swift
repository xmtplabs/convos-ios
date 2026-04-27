import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// Adapter that presents a `MessagingSigner` as an XMTPiOS `SigningKey`.
/// This is the only place in the codebase that constructs an XMTPiOS
/// `SignedData` struct.
///
/// Used by `XMTPiOSMessagingClient.create(...)` and revocation flows
/// that receive a `MessagingSigner` from call sites and need to hand
/// XMTPiOS a native `SigningKey`.
///
/// Wraps the Convos signer's async `sign(_:)` — which returns raw
/// signature bytes (`Data`) — into a `SignedData` carrier. For non-
/// passkey signers (the production path today) the `publicKey`,
/// `authenticatorData`, and `clientDataJson` fields are nil; the
/// XMTPiOS side only populates them for passkey auth.
struct XMTPiOSSigningKeyAdapter: XMTPiOS.SigningKey {
    let messagingSigner: any MessagingSigner

    init(_ messagingSigner: any MessagingSigner) {
        self.messagingSigner = messagingSigner
    }

    var identity: XMTPiOS.PublicIdentity {
        messagingSigner.identity.xmtpPublicIdentity
    }

    var type: XMTPiOS.SignerType {
        switch messagingSigner.type {
        case .eoa: return .EOA
        case .smartContractWallet: return .SCW
        }
    }

    var chainId: Int64? { messagingSigner.chainId }
    var blockNumber: Int64? { messagingSigner.blockNumber }

    func sign(_ message: String) async throws -> XMTPiOS.SignedData {
        let rawSignature = try await messagingSigner.sign(message)
        return XMTPiOS.SignedData(rawData: rawSignature)
    }
}

/// Reverse adapter: presents an XMTPiOS `SigningKey` as a Convos
/// `MessagingSigner`.
///
/// Lets keychain-backed signers (`PrivateKey`) and any third-party
/// `SigningKey` conformer flow into APIs that take `any MessagingSigner`
/// (e.g. `MessagingClient.create`). The factory unwraps with the
/// forward `XMTPiOSSigningKeyAdapter` when it needs a native
/// `SigningKey` again.
public struct XMTPiOSMessagingSignerAdapter: MessagingSigner {
    public let xmtpSigningKey: any XMTPiOS.SigningKey

    public init(_ xmtpSigningKey: any XMTPiOS.SigningKey) {
        self.xmtpSigningKey = xmtpSigningKey
    }

    public var identity: MessagingIdentity {
        MessagingIdentity(xmtpSigningKey.identity)
    }

    public var type: MessagingSignerType {
        switch xmtpSigningKey.type {
        case .EOA: return .eoa
        case .SCW: return .smartContractWallet
        }
    }

    public var chainId: Int64? { xmtpSigningKey.chainId }
    public var blockNumber: Int64? { xmtpSigningKey.blockNumber }

    public func sign(_ message: String) async throws -> Data {
        let signed = try await xmtpSigningKey.sign(message)
        return signed.rawData
    }
}

public extension XMTPiOS.SigningKey {
    /// Convenience wrapper to flow an XMTPiOS `SigningKey` into any API
    /// that takes `any MessagingSigner`.
    var asMessagingSigner: any MessagingSigner {
        XMTPiOSMessagingSignerAdapter(self)
    }
}
