import Foundation
@preconcurrency import XMTPiOS

/// Signs SIWE messages with an XMTP-managed Ethereum private key.
///
/// `libxmtp`'s `PrivateKey.sign(_:)` applies the EIP-191 "personal sign"
/// prefix internally and returns a 65-byte `r || s || v` recoverable
/// signature. The underlying libsecp256k1 emits `v ∈ {0, 1}`, but the
/// backend's SIWE verification path (`ethers.verifyMessage`) expects
/// Ethereum-standard `v ∈ {27, 28}`. We normalize before hex-encoding so
/// the backend can recover the correct address — without this step,
/// signatures look mathematically correct but the backend's recovery
/// returns the wrong address and rejects the request with `401 Invalid
/// SIWE` (the nonce is burned). See `SIWESignerTests` for the canary
/// roundtrip that guards this invariant.
public enum SIWESigner {
    /// Sign `message` and return the 65-byte signature as `0x`-prefixed
    /// hex (130 hex chars after the prefix).
    public static func sign(message: String, with privateKey: PrivateKey) async throws -> String {
        let signed = try await privateKey.sign(message)
        return hexEncode(normalize(signed.rawData))
    }

    /// Sign `message` and return the raw 65-byte signature with the
    /// recovery byte normalized to Ethereum's `v ∈ {27, 28}`. Exposed for
    /// tests that need to inspect or recover from the signature bytes.
    public static func signRaw(message: String, with privateKey: PrivateKey) async throws -> Data {
        let signed = try await privateKey.sign(message)
        return normalize(signed.rawData)
    }

    /// Normalize the recovery byte. Accepts `v ∈ {0, 1}` and shifts to
    /// `{27, 28}`; values already in `{27, 28}` are left alone.
    public static func normalize(_ signature: Data) -> Data {
        guard signature.count == 65 else { return signature }
        var bytes = signature
        if bytes[64] < 27 {
            bytes[64] = bytes[64] &+ 27
        }
        return bytes
    }

    private static func hexEncode(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Capability the API client needs to perform a SIWE auth round-trip
/// without leaking `KeychainIdentity` or libxmtp types into the protocol
/// surface. Callers construct this from the loaded identity and inject it
/// into the API client; the API client treats it as an opaque "what's the
/// address and sign this string" capability so the 401 re-auth path can
/// reissue without falling back to legacy device-only auth.
public struct BackendAuthSigningContext: Sendable {
    public let address: String
    /// Signs the message and returns the 65-byte `r || s || v` signature
    /// with `v` already normalized to `{27, 28}`.
    public let sign: @Sendable (_ message: String) async throws -> Data

    public init(
        address: String,
        sign: @escaping @Sendable (_ message: String) async throws -> Data
    ) {
        self.address = address
        self.sign = sign
    }

    /// Build a signing context backed by an XMTP `PrivateKey`. The closure
    /// retains the key for the lifetime of the context.
    public static func make(from privateKey: PrivateKey) -> BackendAuthSigningContext {
        let address = privateKey.identity.identifier
        return BackendAuthSigningContext(
            address: address,
            sign: { message in
                try await SIWESigner.signRaw(message: message, with: privateKey)
            }
        )
    }
}
