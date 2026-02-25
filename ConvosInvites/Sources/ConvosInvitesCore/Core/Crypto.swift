import CryptoKit
import CSecp256k1
import Foundation

/// Cryptographic utilities for invite operations
extension Data {
    /// Normalizes a public key to compressed format for comparison
    func normalizePublicKey() throws -> Data {
        guard let ctx = secp256k1_context_create(
            UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)
        ) else {
            throw InviteSignatureError.invalidContext
        }

        defer {
            secp256k1_context_destroy(ctx)
        }

        var pubkey = secp256k1_pubkey()

        let parseResult = self.withUnsafeBytes { buffer -> Int32 in
            guard let publicKeyPtr = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return secp256k1_ec_pubkey_parse(ctx, &pubkey, publicKeyPtr, self.count)
        }

        guard parseResult == 1 else {
            throw InviteSignatureError.invalidPublicKey
        }

        let outputPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 33)
        defer {
            outputPtr.deallocate()
        }

        var outputLen = 33
        guard secp256k1_ec_pubkey_serialize(
            ctx, outputPtr, &outputLen, &pubkey,
            UInt32(SECP256K1_EC_COMPRESSED)
        ) == 1 else {
            throw InviteSignatureError.invalidPublicKey
        }

        return Data(bytes: outputPtr, count: outputLen)
    }

    /// Computes SHA256 hash of this data
    func sha256Hash() -> Data {
        let hash = SHA256.hash(data: self)
        return Data(hash)
    }

    /// Constant-time comparison to prevent timing attacks
    func constantTimeEquals(_ other: Data) -> Bool {
        guard self.count == other.count else {
            return false
        }

        var result: UInt8 = 0
        for i in 0..<self.count {
            result |= self[i] ^ other[i]
        }

        return result == 0
    }

    /// Initialize Data from a hex string
    public init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Convert data to hex string
    func toHexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
