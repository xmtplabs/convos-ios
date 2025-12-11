import CryptoKit
import CSecp256k1
import Foundation
import SwiftProtobuf

/// Extensions for cryptographically signed conversation invites
///
/// Convos uses a secure invite system based on secp256k1 signatures:
///
/// **Invite Creation Flow:**
/// 1. Creator generates an invite containing: conversation token (encrypted conversation ID),
///    invite tag, metadata (name, image, description), and optional expiry
/// 2. Creator signs the invite payload with their private key
/// 3. Invite is compressed with DEFLATE and encoded to a URL-safe base64 string
///
/// **Join Request Flow:**
/// 1. Joiner receives invite code (QR, link, airdrop, etc.)
/// 2. Joiner sends the invite code as a text message in a DM to the creator
/// 3. Creator's app validates signature and decrypts conversation token
/// 4. If valid, creator adds joiner to the conversation
///
/// **Security Properties:**
/// - Only the creator can decrypt the conversation ID (via encrypted token)
/// - Signature proves the invite was created by conversation owner
/// - Public key can be recovered from signature for verification
/// - Invites can have expiration dates and single-use flags
/// - Invalid invites result in blocked DMs to prevent spam
///
/// **Encoding Optimizations:**
/// - DEFLATE compression reduces payload size by 20-40%
/// - Binary fields (conversation token, inbox ID) stored as raw bytes
/// - Unix timestamps (sfixed64) instead of protobuf Timestamp messages
/// - Overall ~35-50% size reduction compared to unoptimized encoding
extension SignedInvite {
    /// Deserialized payload for accessing invite data
    /// The stored `payload` property is `Data` to preserve the exact bytes that were signed.
    /// This ensures signatures remain valid even if the protobuf schema changes.
    /// Use this property when you need to access fields like `.tag`, `.conversationToken`, etc.
    public var invitePayload: InvitePayload {
        do {
            return try InvitePayload(serializedBytes: self.payload)
        } catch {
            // If deserialization fails, return empty payload
            // This should not happen in normal operation
            return InvitePayload()
        }
    }

    public var expiresAt: Date? {
        invitePayload.expiresAtUnixIfPresent
    }

    public var hasExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    public var conversationHasExpired: Bool {
        guard let conversationExpiresAt else { return false }
        return Date() > conversationExpiresAt
    }

    public var name: String? {
        invitePayload.nameIfPresent
    }

    public var description_p: String? {
        invitePayload.descriptionIfPresent
    }

    public var imageURL: String? {
        invitePayload.imageURLIfPresent
    }

    public var conversationExpiresAt: Date? {
        invitePayload.conversationExpiresAtUnixIfPresent
    }

    public var expiresAfterUse: Bool {
        invitePayload.expiresAfterUse
    }

    /// Set the payload from an InvitePayload
    /// This serializes the InvitePayload to bytes and stores them to preserve the exact bytes that were signed.
    public mutating func setPayload(_ payload: InvitePayload) throws {
        self.payload = try payload.serializedData()
    }

    public static func slug(
        for conversation: DBConversation,
        expiresAt: Date?,
        expiresAfterUse: Bool,
        privateKey: Data,
    ) throws -> String {
        let conversationTokenBytes = try InviteConversationToken.makeConversationTokenBytes(
            conversationId: conversation.id,
            creatorInboxId: conversation.inboxId,
            secp256k1PrivateKey: privateKey
        )
        var payload = InvitePayload()
        if let name = conversation.name {
            payload.name = name
        }
        if let description_p = conversation.description {
            payload.description_p = description_p
        }
        if let imageURL = conversation.imageURLString {
            payload.imageURL = imageURL
        }
        if let conversationExpiresAt = conversation.expiresAt {
            payload.conversationExpiresAtUnix = Int64(conversationExpiresAt.timeIntervalSince1970)
        }
        payload.expiresAfterUse = expiresAfterUse
        payload.tag = conversation.inviteTag
        payload.conversationToken = conversationTokenBytes

        // Convert hex-encoded inbox ID to raw bytes
        guard let inboxIdBytes = Data(hexString: conversation.inboxId), !inboxIdBytes.isEmpty else {
            throw EncodableSignatureError.invalidFormat
        }
        payload.creatorInboxID = inboxIdBytes

        if let expiresAt {
            payload.expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        }
        let signature = try payload.sign(with: privateKey)
        var signedInvite = SignedInvite()
        // Store the serialized payload bytes to preserve the exact bytes that were signed
        signedInvite.payload = try payload.serializedData()
        signedInvite.signature = signature
        return try signedInvite.toURLSafeSlug()
    }
}

extension InvitePayload {
    /// Creator's inbox ID converted from raw bytes to hex string
    public var creatorInboxIdString: String {
        creatorInboxID.hexEncodedString()
    }

    public var expiresAtUnixIfPresent: Date? {
        guard hasExpiresAtUnix else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiresAtUnix))
    }

    public var conversationExpiresAtUnixIfPresent: Date? {
        guard hasConversationExpiresAtUnix else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(conversationExpiresAtUnix))
    }

    public var nameIfPresent: String? {
        guard hasName else { return nil }
        return name
    }

    public var descriptionIfPresent: String? {
        guard hasDescription_p else { return nil }
        return description_p
    }

    public var imageURLIfPresent: String? {
        guard hasImageURL else { return nil }
        return imageURL
    }
}

// MARK: - Signing

enum EncodableSignatureError: Error, Equatable {
    case invalidContext
    case signatureFailure
    case encodingFailure
    case invalidSignature
    case invalidPublicKey
    case invalidPrivateKey
    case verificationFailure
    case invalidFormat
}

extension InvitePayload {
    func sign(with privateKey: Data) throws -> Data {
        // Validate private key length to prevent out-of-bounds reads
        guard privateKey.count == 32 else {
            throw EncodableSignatureError.invalidPrivateKey
        }

        guard let ctx = secp256k1_context_create(
            UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)
        ) else {
            throw EncodableSignatureError.invalidContext
        }

        defer {
            secp256k1_context_destroy(ctx)
        }

        // Hash the message using SHA256
        let messageHash = try serializedData().sha256Hash()

        let signaturePtr = UnsafeMutablePointer<secp256k1_ecdsa_recoverable_signature>.allocate(capacity: 1)
        defer {
            signaturePtr.deallocate()
        }

        // Use withUnsafeBytes to ensure pointer lifetime is valid during C API call
        let result = messageHash.withUnsafeBytes { msgBuffer -> Int32 in
            guard let msg = msgBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return privateKey.withUnsafeBytes { keyBuffer -> Int32 in
                guard let privateKeyPtr = keyBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return secp256k1_ecdsa_sign_recoverable(
                    ctx, signaturePtr, msg, privateKeyPtr, nil, nil
                )
            }
        }

        guard result == 1 else {
            throw EncodableSignatureError.signatureFailure
        }

        let outputPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer {
            outputPtr.deallocate()
        }

        var recid: Int32 = 0
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(
            ctx, outputPtr, &recid, signaturePtr
        ) == 1 else {
            throw EncodableSignatureError.encodingFailure
        }

        // Combine signature and recovery ID
        let outputWithRecidPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 65)
        defer {
            outputWithRecidPtr.deallocate()
        }

        outputWithRecidPtr.update(from: outputPtr, count: 64)
        outputWithRecidPtr.advanced(by: 64).pointee = UInt8(recid)

        return Data(bytes: outputWithRecidPtr, count: 65)
    }
}

// MARK: - URL-safe Base64 encoding

extension SignedInvite {
    /// Maximum allowed decompressed size to prevent decompression bombs
    private static let maxDecompressedSize: UInt32 = 1 * 1024 * 1024

    /// Encode to URL-safe base64 string with optional DEFLATE compression
    /// 
    /// Additionally, inserts `*` separator characters every 300 characters to work around
    /// an iMessage URL parsing limitation that breaks long Base64 strings.
    /// See: https://www.patrickweaver.net/blog/imessage-mystery////
    public func toURLSafeSlug() throws -> String {
        let protobufData = try self.serializedData()
        let data = protobufData.compressedIfSmaller() ?? protobufData
        return data
            .base64URLEncoded()
            .insertingSeparator("*", every: 300)
    }

    /// Decode from URL-safe base64 string, automatically decompressing if needed
    /// Removes `*` separator characters that were inserted for iMessage compatibility.
    public static func fromURLSafeSlug(_ slug: String) throws -> SignedInvite {
        let data = try slug
            .replacingOccurrences(of: "*", with: "")
            .base64URLDecoded()

        let protobufData: Data
        // validate compression marker value explicitly
        if let firstByte = data.first, firstByte == Data.compressionMarker {
            let dataWithoutMarker = data.dropFirst()
            guard let decompressed = dataWithoutMarker.decompressedWithSize(maxSize: maxDecompressedSize) else {
                throw EncodableSignatureError.invalidFormat
            }
            protobufData = decompressed
        } else {
            protobufData = data
        }

        return try SignedInvite(serializedBytes: protobufData)
    }

    /// Decode from either the full URL string or the invite code string
    public static func fromInviteCode(_ code: String) throws -> SignedInvite {
        // Trim whitespace and newlines from input to handle padded URLs
        let trimmedInput = code.trimmingCharacters(in: .whitespacesAndNewlines)

        let extractedCode: String
        if let url = URL(string: trimmedInput),
           let codeFromURL = url.convosInviteCode {
            // Use the URL extension which handles both v2 query params and app scheme
            extractedCode = codeFromURL
        } else {
            // If URL parsing fails, treat the input as a raw invite code
            extractedCode = trimmedInput
        }

        // Trim again in case the extracted code has whitespace
        let finalCode = extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return try fromURLSafeSlug(finalCode)
    }
}

// MARK: - Signature Validation

extension SignedInvite {
    func verify(with expectedPublicKey: Data) throws -> Bool {
        // Recover the public key from the signature using this data as the message
        let recoveredPublicKey = try recoverSignerPublicKey()

        // Compare the recovered key with the expected key
        // If the expected key is uncompressed (65 bytes) and recovered is compressed (33 bytes),
        // or vice versa, we need to handle the comparison properly
        if recoveredPublicKey.count == expectedPublicKey.count {
            return recoveredPublicKey.constantTimeEquals(expectedPublicKey)
        } else {
            // Convert both to the same format for comparison
            let normalizedRecovered = try recoveredPublicKey.normalizePublicKey()
            let normalizedExpected = try expectedPublicKey.normalizePublicKey()
            return normalizedRecovered.constantTimeEquals(normalizedExpected)
        }
    }

    public func recoverSignerPublicKey() throws -> Data {
        guard signature.count == 65 else {
            throw EncodableSignatureError.invalidSignature
        }

        guard let ctx = secp256k1_context_create(
            UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)
        ) else {
            throw EncodableSignatureError.invalidContext
        }

        defer {
            secp256k1_context_destroy(ctx)
        }

        // Hash the message using the stored payload bytes directly
        // This ensures we use the exact bytes that were signed, not a re-serialization
        // Access the stored Data property directly (not the computed property)
        let payloadBytes = self.payload  // This accesses the stored Data property
        let messageHash = payloadBytes.sha256Hash()

        // Extract signature and recovery ID from the signature parameter
        let signatureData = signature.prefix(64)
        let recid = Int32(signature[64])

        // Validate recovery ID is in valid range (0-3)
        guard recid >= 0 && recid <= 3 else {
            throw EncodableSignatureError.invalidSignature
        }

        // Parse the recoverable signature
        var recoverableSignature = secp256k1_ecdsa_recoverable_signature()

        // Use withUnsafeBytes to ensure pointer lifetime is valid during C API call
        let parseResult = signatureData.withUnsafeBytes { sigBuffer -> Int32 in
            guard let signaturePtr = sigBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return secp256k1_ecdsa_recoverable_signature_parse_compact(
                ctx, &recoverableSignature, signaturePtr, recid
            )
        }

        guard parseResult == 1 else {
            throw EncodableSignatureError.invalidSignature
        }

        // Recover the public key
        var pubkey = secp256k1_pubkey()

        let recoverResult = messageHash.withUnsafeBytes { msgBuffer -> Int32 in
            guard let msgPtr = msgBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return secp256k1_ecdsa_recover(ctx, &pubkey, &recoverableSignature, msgPtr)
        }

        guard recoverResult == 1 else {
            throw EncodableSignatureError.verificationFailure
        }

        // Serialize the public key (uncompressed format)
        let outputPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 65)
        defer { outputPtr.deallocate() }

        var outputLen = 65
        guard secp256k1_ec_pubkey_serialize(
            ctx,
            outputPtr,
            &outputLen,
            &pubkey,
            UInt32(SECP256K1_EC_UNCOMPRESSED)
        ) == 1 else {
            throw EncodableSignatureError.verificationFailure
        }

        return Data(bytes: outputPtr, count: outputLen)
    }
}

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
