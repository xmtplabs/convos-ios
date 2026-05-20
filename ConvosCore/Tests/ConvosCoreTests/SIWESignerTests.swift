@testable import ConvosCore
import CryptoSwift
import CSecp256k1
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Canary tests that the SIWE signer produces a 65-byte `r || s || v`
/// signature with Ethereum-standard `v ∈ {27, 28}` and that the signature
/// round-trips through the same recovery path the backend uses
/// (`ethers.verifyMessage`). If the v-byte normalization is wrong or the
/// EIP-191 prefixing drifts, recovery produces the wrong address and these
/// tests fail — before the backend ever sees a request.
@Suite("SIWESigner canary")
struct SIWESignerTests {
    @Test("v-byte normalize maps {0,1} to {27,28} and leaves {27,28} alone")
    func normalizeVByte() {
        var sig = Data(repeating: 0x42, count: 64) + Data([0])
        let normalized0 = SIWESigner.normalize(sig)
        #expect(normalized0.count == 65)
        #expect(normalized0[64] == 27)

        sig[64] = 1
        #expect(SIWESigner.normalize(sig)[64] == 28)

        sig[64] = 27
        #expect(SIWESigner.normalize(sig)[64] == 27)

        sig[64] = 28
        #expect(SIWESigner.normalize(sig)[64] == 28)
    }

    @Test("Sign-then-recover roundtrip: recovered address equals wallet address")
    func signAndRecoverRoundtrip() async throws {
        // Fixed key so the test is deterministic.
        let privateKeyData = Data(repeating: 0x11, count: 32)
        let privateKey = try PrivateKey(privateKeyData)
        let expectedAddress = privateKey.identity.identifier.lowercased()

        // Canary signs the realistic format the backend validates,
        // including the Resources block with the per-device URI. If
        // we ever drift on Resources, this test catches it before the
        // backend's recovery rejects the signature on the wire.
        let message = """
        convos.app wants you to sign in with your Ethereum account:
        \(expectedAddress)

        Sign in to Convos

        URI: https://convos.app
        Version: 1
        Chain ID: 1
        Nonce: deadbeef00deadbeef00deadbeef00deadbeef00deadbeef00deadbeef00aabb
        Issued At: 2026-05-11T12:00:00.000Z
        Expiration Time: 2026-05-11T12:05:00.000Z
        Resources:
        - convos://device/5A2B3C4D-EFAB-1234-5678-90ABCDEF1234
        """

        let signature = try await SIWESigner.signRaw(message: message, with: privateKey)
        #expect(signature.count == 65)
        #expect(signature[64] == 27 || signature[64] == 28)

        let digest = eip191Hash(message)
        let recoveredAddress = try recoverAddress(messageHash: digest, signature: signature)
        #expect(recoveredAddress == expectedAddress)
    }

    @Test("Hex-encoded signature is 0x + 130 hex chars")
    func hexEncodingShape() async throws {
        let privateKey = try PrivateKey(Data(repeating: 0x22, count: 32))
        let hex = try await SIWESigner.sign(message: "anything", with: privateKey)
        #expect(hex.hasPrefix("0x"))
        #expect(hex.count == 2 + 130)
        let recoveryHex = String(hex.suffix(2))
        let recoveryByte = UInt8(recoveryHex, radix: 16)
        #expect(recoveryByte == 27 || recoveryByte == 28)
    }
}

// MARK: - EIP-191 + secp256k1 recovery helpers (test-only)

private func eip191Hash(_ message: String) -> Data {
    let messageData = Data(message.utf8)
    let prefix = "\u{19}Ethereum Signed Message:\n\(messageData.count)"
    let prefixed = Data(prefix.utf8) + messageData
    let digest = SHA3(variant: .keccak256).calculate(for: Array(prefixed))
    return Data(digest)
}

private struct RecoveryError: Error, CustomStringConvertible {
    let stage: String
    var description: String { "secp256k1 recovery failed at \(stage)" }
}

private func recoverAddress(messageHash: Data, signature: Data) throws -> String {
    guard messageHash.count == 32 else { throw RecoveryError(stage: "bad_hash_length") }
    guard signature.count == 65 else { throw RecoveryError(stage: "bad_sig_length") }

    guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)) else {
        throw RecoveryError(stage: "context_create")
    }
    defer { secp256k1_context_destroy(ctx) }

    // Map v ∈ {27, 28} → recid ∈ {0, 1} the way ethers does.
    let recid = Int32(signature[64]) - 27
    guard recid == 0 || recid == 1 else {
        throw RecoveryError(stage: "recid_out_of_range_\(signature[64])")
    }

    let compactSig = signature.prefix(64)
    var recoverableSig = secp256k1_ecdsa_recoverable_signature()
    let parseOK = compactSig.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
        guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &recoverableSig, base, recid)
    }
    guard parseOK == 1 else { throw RecoveryError(stage: "parse_compact") }

    var pubkey = secp256k1_pubkey()
    let recoverOK = messageHash.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
        guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return secp256k1_ecdsa_recover(ctx, &pubkey, &recoverableSig, base)
    }
    guard recoverOK == 1 else { throw RecoveryError(stage: "ecdsa_recover") }

    var serialized = [UInt8](repeating: 0, count: 65)
    var serializedLen = 65
    let serializeOK = secp256k1_ec_pubkey_serialize(
        ctx, &serialized, &serializedLen, &pubkey, UInt32(SECP256K1_EC_UNCOMPRESSED)
    )
    guard serializeOK == 1, serializedLen == 65 else { throw RecoveryError(stage: "pubkey_serialize") }

    // Uncompressed pubkey is `04 || X(32) || Y(32)`. The Ethereum address is
    // the rightmost 20 bytes of keccak256 over `X || Y`.
    let xy = Array(serialized[1..<65])
    let hash = SHA3(variant: .keccak256).calculate(for: xy)
    let addressBytes = hash.suffix(20)
    let hex = addressBytes.map { String(format: "%02x", $0) }.joined()
    return "0x" + hex
}
