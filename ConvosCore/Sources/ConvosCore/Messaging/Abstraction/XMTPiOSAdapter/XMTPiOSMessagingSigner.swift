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
