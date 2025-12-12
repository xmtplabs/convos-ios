import CryptoKit
import CSecp256k1
import Foundation

// MARK: - Data + InviteCrypto

/// Cryptographic utilities for invite signature operations
extension Data {
    /// Normalizes a public key to compressed format for comparison
    func normalizePublicKey() throws -> Data {
        guard let ctx = secp256k1_context_create(
            UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)
        ) else {
            throw EncodableSignatureError.invalidContext
        }

        defer {
            secp256k1_context_destroy(ctx)
        }

        // Parse the public key
        var pubkey = secp256k1_pubkey()

        // Use withUnsafeBytes to ensure pointer lifetime is valid during C API call
        let parseResult = self.withUnsafeBytes { buffer -> Int32 in
            guard let publicKeyPtr = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return secp256k1_ec_pubkey_parse(ctx, &pubkey, publicKeyPtr, self.count)
        }

        guard parseResult == 1 else {
            throw EncodableSignatureError.invalidPublicKey
        }

        // Serialize to compressed format
        let outputPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 33)
        defer {
            outputPtr.deallocate()
        }

        var outputLen = 33
        guard secp256k1_ec_pubkey_serialize(
            ctx, outputPtr, &outputLen, &pubkey,
            UInt32(SECP256K1_EC_COMPRESSED)
        ) == 1 else {
            throw EncodableSignatureError.invalidPublicKey
        }

        return Data(bytes: outputPtr, count: outputLen)
    }

    /// Computes SHA256 hash of this data
    func sha256Hash() -> Data {
        let hash = SHA256.hash(data: self)
        return Data(hash)
    }

    /// Constant-time comparison to prevent timing attacks
    /// - Parameter other: The data to compare against
    /// - Returns: true if the data are equal, false otherwise
    /// - Note: Always compares all bytes regardless of when a mismatch is found
    func constantTimeEquals(_ other: Data) -> Bool {
        // early exit if lengths don't match - this is safe to leak
        guard self.count == other.count else {
            return false
        }

        // compare all bytes in constant time
        var result: UInt8 = 0
        for i in 0..<self.count {
            result |= self[i] ^ other[i]
        }

        return result == 0
    }
}
