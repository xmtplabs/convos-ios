import CryptoKit
import Foundation

/// Compact, encrypted conversation tokens that only the creator can decode.
///
/// ## Cryptographic Design
/// - **Key Derivation**: HKDF-SHA256(privateKey, salt="ConvosInviteV1", info="inbox:<inboxId>")
/// - **AEAD**: ChaCha20-Poly1305 with AAD = creatorInboxId (binds token to creator's identity)
///
/// ## Binary Format
/// ```
/// | version (1 byte) | nonce (12 bytes) | ciphertext (variable) | auth_tag (16 bytes) |
/// ```
///
/// The ciphertext decrypts to:
/// ```
/// | type_tag (1 byte) | payload (variable) |
/// ```
///
/// ### Payload Types
/// - `type_tag = 0x01`: UUID format (16 bytes)
/// - `type_tag = 0x02`: UTF-8 string with length prefix
public enum InviteToken {
    // MARK: - Format Constants

    /// Current format version
    public static let formatVersion: UInt8 = 1

    /// Salt for HKDF key derivation
    private static let salt: Data = Data("ConvosInviteV1".utf8)

    /// ChaCha20-Poly1305 constants
    private static let nonceLength: Int = 12
    private static let authTagLength: Int = 16

    /// Minimum valid token size (version + nonce + type_tag + auth_tag)
    public static let minEncodedSize: Int = 1 + nonceLength + 3 + authTagLength // 32 bytes

    /// Size of UUID-based tokens (fixed)
    public static let uuidCodeSize: Int = 1 + nonceLength + 16 + 1 + authTagLength // 46 bytes

    /// Maximum supported string length for conversation IDs
    public static let maxStringLength: Int = 65535 // 2-byte length field max

    // MARK: - Public API

    /// Generate an encrypted conversation token as raw bytes
    /// - Parameters:
    ///   - conversationId: Conversation ID (UUIDs are packed into 16 bytes)
    ///   - creatorInboxId: Creator's inbox ID (used in key derivation and AAD)
    ///   - privateKey: 32-byte secp256k1 private key
    /// - Returns: Encrypted token bytes
    public static func encrypt(
        conversationId: String,
        creatorInboxId: String,
        privateKey: Data
    ) throws -> Data {
        let key = try deriveKey(privateKey: privateKey, inboxId: creatorInboxId)

        // Pack plaintext as either UUID(16) or UTF-8 with a tiny tag
        let plaintext = try packConversationId(conversationId)

        // AAD binds this token to the specific creator identity
        let aad = Data(creatorInboxId.utf8)

        let sealed = try chachaSeal(plaintext: plaintext, key: key, aad: aad)

        // Prepend version to CryptoKit's combined (nonce|ciphertext|tag)
        var out = Data()
        out.append(formatVersion)
        out.append(sealed.combined)

        return out
    }

    /// Decrypt a conversation token from raw bytes
    /// - Parameters:
    ///   - tokenBytes: Encrypted token bytes
    ///   - creatorInboxId: Creator's inbox ID (must match token generation)
    ///   - privateKey: 32-byte secp256k1 private key (must match token generation)
    /// - Returns: Decrypted conversation ID
    public static func decrypt(
        tokenBytes: Data,
        creatorInboxId: String,
        privateKey: Data
    ) throws -> String {
        guard tokenBytes.count >= minEncodedSize else {
            throw InviteTokenError.invalidFormat("Code too short: \(tokenBytes.count) bytes, minimum \(minEncodedSize)")
        }

        guard let ver = tokenBytes.first else {
            throw InviteTokenError.missingVersion
        }
        guard ver == formatVersion else {
            throw InviteTokenError.unsupportedVersion(ver)
        }

        let combined = tokenBytes.dropFirst()
        let key = try deriveKey(privateKey: privateKey, inboxId: creatorInboxId)
        let aad = Data(creatorInboxId.utf8)

        let plaintext = try chachaOpen(combined: combined, key: key, aad: aad)
        return try unpackConversationId(plaintext)
    }

    // MARK: - Internals

    private static func deriveKey(privateKey: Data, inboxId: String) throws -> SymmetricKey {
        guard !privateKey.isEmpty else { throw InviteTokenError.badKeyMaterial }
        let info = Data(("inbox:" + inboxId).utf8)

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: privateKey),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private static func chachaSeal(plaintext: Data, key: SymmetricKey, aad: Data) throws -> ChaChaPoly.SealedBox {
        let nonce = ChaChaPoly.Nonce() // random 12 bytes
        return try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
    }

    private static func chachaOpen(combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw InviteTokenError.invalidFormat("Malformed encrypted data")
        }

        do {
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw InviteTokenError.cryptoOpenFailed
        }
    }

    // MARK: - ConversationId Packing

    private enum PlainTag: UInt8 { case uuid16 = 0x01, utf8 = 0x02 }

    private static func packConversationId(_ id: String) throws -> Data {
        guard !id.isEmpty else {
            throw InviteTokenError.emptyConversationId
        }

        var out = Data()
        if let uuid = UUID(uuidString: id) {
            out.append(PlainTag.uuid16.rawValue)
            var u = uuid.uuid
            withUnsafeBytes(of: &u) { out.append(contentsOf: $0) }
            return out
        } else {
            out.append(PlainTag.utf8.rawValue)
            let bytes = Data(id.utf8)

            guard bytes.count <= maxStringLength else {
                throw InviteTokenError.stringTooLong(bytes.count)
            }

            if bytes.count <= 255 {
                out.append(UInt8(bytes.count))
            } else {
                out.append(0)
                out.append(UInt8((bytes.count >> 8) & 0xff))
                out.append(UInt8(bytes.count & 0xff))
            }
            out.append(bytes)
            return out
        }
    }

    private static func unpackConversationId(_ data: Data) throws -> String {
        guard let tagByte = data.first, let tag = PlainTag(rawValue: tagByte) else {
            throw InviteTokenError.invalidFormat("Missing or invalid type tag")
        }
        var offset = 1
        switch tag {
        case .uuid16:
            guard data.count >= offset + 16 else {
                throw InviteTokenError.invalidFormat("UUID payload too short: need 16 bytes, have \(data.count - offset)")
            }
            let slice = data[offset ..< offset + 16]
            let uuid = slice.withUnsafeBytes { ptr -> UUID in
                let tup = ptr.bindMemory(to: UInt8.self)
                return UUID(uuid: (
                    tup[0], tup[1], tup[2], tup[3],
                    tup[4], tup[5], tup[6], tup[7],
                    tup[8], tup[9], tup[10], tup[11],
                    tup[12], tup[13], tup[14], tup[15]
                ))
            }
            return uuid.uuidString.lowercased()
        case .utf8:
            guard data.count > offset else {
                throw InviteTokenError.invalidFormat("String payload missing length byte")
            }
            let len1 = Int(data[offset]); offset += 1
            let length: Int
            if len1 > 0 {
                length = len1
            } else {
                guard data.count >= offset + 2 else {
                    throw InviteTokenError.invalidFormat("String payload missing 2-byte length")
                }
                length = (Int(data[offset]) << 8) | Int(data[offset + 1])
                offset += 2
            }

            guard length > 0 else {
                throw InviteTokenError.emptyConversationId
            }

            guard data.count >= offset + length else {
                throw InviteTokenError.invalidFormat("String payload truncated: need \(length) bytes, have \(data.count - offset)")
            }
            let bytes = data[offset ..< offset + length]
            guard let s = String(data: bytes, encoding: .utf8) else {
                throw InviteTokenError.invalidFormat("Invalid UTF-8 string data")
            }
            return s
        }
    }
}
