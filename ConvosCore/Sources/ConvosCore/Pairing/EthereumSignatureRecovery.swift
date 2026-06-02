import CryptoSwift
import CSecp256k1
import Foundation

/// Recovers the Ethereum address that signed an EIP-191 ("personal_sign")
/// message. Used by [[PairingInvite]] to verify that a slug's claimed
/// `initiatorAddress` actually matches the key that signed the payload.
///
/// The signing path is `XMTPiOS.PrivateKey.sign(_:)` which internally
/// hashes via `keccak256("\\x19Ethereum Signed Message:\\n<len>" + msg)`
/// and produces a 65-byte recoverable signature (r||s||v). This file
/// inverts that.
enum EthereumSignatureRecovery {
    enum Error: Swift.Error {
        case invalidSignatureLength
        case invalidRecoveryId
        case parseFailure
        case recoveryFailure
        case serializationFailure
    }

    /// Returns the recovered address as a lowercased 0x-prefixed hex string,
    /// or throws if the signature is malformed / no valid public key recovers.
    static func recoverAddress(message: String, signature: Data) throws -> String {
        let digest = personalSignDigest(message: message)
        let pubkey = try recoverPublicKey(digest: digest, signature: signature)
        return address(fromUncompressedPubkey: pubkey)
    }

    /// EIP-191 `personal_sign` digest. Matches the input that
    /// `XMTPiOS.PrivateKey.sign(_:)` produces internally via
    /// `KeyUtilx.ethHash(_:)`.
    private static func personalSignDigest(message: String) -> Data {
        let utf8 = Array(message.utf8)
        let prefix = "\u{19}Ethereum Signed Message:\n\(utf8.count)"
        var bytes: [UInt8] = Array(prefix.utf8)
        bytes.append(contentsOf: utf8)
        return Data(SHA3(variant: .keccak256).calculate(for: bytes))
    }

    private static func recoverPublicKey(digest: Data, signature: Data) throws -> [UInt8] {
        guard signature.count == 65 else { throw Error.invalidSignatureLength }
        // libxmtp emits v in {0, 1}, but conventional Ethereum signatures
        // use v in {27, 28} (or {chainId * 2 + 35, ...} for EIP-155).
        // Accept either form.
        let rawV = Int(signature[64])
        let recoveryId: Int32
        switch rawV {
        case 0, 1:
            recoveryId = Int32(rawV)
        case 27, 28:
            recoveryId = Int32(rawV - 27)
        default:
            throw Error.invalidRecoveryId
        }

        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_VERIFY)) else {
            throw Error.parseFailure
        }
        defer { secp256k1_context_destroy(context) }

        var recoverableSig = secp256k1_ecdsa_recoverable_signature()
        let parseResult: Int32 = signature.prefix(64).withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return secp256k1_ecdsa_recoverable_signature_parse_compact(
                context,
                &recoverableSig,
                base,
                recoveryId
            )
        }
        guard parseResult == 1 else { throw Error.parseFailure }

        var pubkey = secp256k1_pubkey()
        let recoverResult: Int32 = digest.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return secp256k1_ecdsa_recover(context, &pubkey, &recoverableSig, base)
        }
        guard recoverResult == 1 else { throw Error.recoveryFailure }

        var serialized = [UInt8](repeating: 0, count: 65)
        var outLen = 65
        let serializeResult = secp256k1_ec_pubkey_serialize(
            context,
            &serialized,
            &outLen,
            &pubkey,
            UInt32(SECP256K1_EC_UNCOMPRESSED)
        )
        guard serializeResult == 1, outLen == 65, serialized[0] == 0x04 else {
            throw Error.serializationFailure
        }
        return serialized
    }

    /// Address = last 20 bytes of `keccak256(pubkey[1:65])`, lowercased and
    /// 0x-prefixed. Drops the leading 0x04 SEC1 prefix byte before hashing.
    private static func address(fromUncompressedPubkey pubkey: [UInt8]) -> String {
        let payload = Array(pubkey.dropFirst())
        let hash = SHA3(variant: .keccak256).calculate(for: payload)
        let last20 = hash.suffix(20)
        return "0x" + last20.map { String(format: "%02x", $0) }.joined()
    }
}
