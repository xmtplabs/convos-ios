import CSecp256k1
import Foundation
import SwiftProtobuf

/// Handles signing and verification of invite payloads using secp256k1 ECDSA with recovery
public enum InviteSigner {
    // MARK: - Signing

    /// Sign an invite payload with a private key
    /// - Parameters:
    ///   - payload: The invite payload to sign
    ///   - privateKey: 32-byte secp256k1 private key
    /// - Returns: 65-byte signature (64 bytes + 1 byte recovery ID)
    public static func sign(payload: InvitePayload, privateKey: Data) throws -> Data {
        guard privateKey.count == 32 else {
            throw InviteSignatureError.invalidPrivateKey
        }

        guard let ctx = secp256k1_context_create(
            UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)
        ) else {
            throw InviteSignatureError.invalidContext
        }

        defer {
            secp256k1_context_destroy(ctx)
        }

        let messageHash = try payload.serializedData().sha256Hash()

        let signaturePtr = UnsafeMutablePointer<secp256k1_ecdsa_recoverable_signature>.allocate(capacity: 1)
        defer {
            signaturePtr.deallocate()
        }

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
            throw InviteSignatureError.signatureFailure
        }

        let outputPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer {
            outputPtr.deallocate()
        }

        var recid: Int32 = 0
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(
            ctx, outputPtr, &recid, signaturePtr
        ) == 1 else {
            throw InviteSignatureError.encodingFailure
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

    // MARK: - Verification

    /// Verify a signed invite against an expected public key
    /// - Parameters:
    ///   - signedInvite: The signed invite to verify
    ///   - expectedPublicKey: The expected signer's public key (33 or 65 bytes)
    /// - Returns: true if the signature is valid and matches the expected key
    public static func verify(signedInvite: SignedInvite, expectedPublicKey: Data) throws -> Bool {
        let recoveredPublicKey = try recoverPublicKey(from: signedInvite)

        if recoveredPublicKey.count == expectedPublicKey.count {
            return recoveredPublicKey.constantTimeEquals(expectedPublicKey)
        } else {
            let normalizedRecovered = try recoveredPublicKey.normalizePublicKey()
            let normalizedExpected = try expectedPublicKey.normalizePublicKey()
            return normalizedRecovered.constantTimeEquals(normalizedExpected)
        }
    }

    /// Recover the signer's public key from a signed invite
    /// - Parameter signedInvite: The signed invite
    /// - Returns: The recovered public key (65 bytes, uncompressed)
    public static func recoverPublicKey(from signedInvite: SignedInvite) throws -> Data {
        guard signedInvite.signature.count == 65 else {
            throw InviteSignatureError.invalidSignature
        }

        guard let ctx = secp256k1_context_create(
            UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)
        ) else {
            throw InviteSignatureError.invalidContext
        }

        defer {
            secp256k1_context_destroy(ctx)
        }

        let messageHash = signedInvite.payload.sha256Hash()
        let signatureData = signedInvite.signature.prefix(64)
        let recid = Int32(signedInvite.signature[64])

        guard recid >= 0 && recid <= 3 else {
            throw InviteSignatureError.invalidSignature
        }

        var recoverableSignature = secp256k1_ecdsa_recoverable_signature()

        let parseResult = signatureData.withUnsafeBytes { sigBuffer -> Int32 in
            guard let signaturePtr = sigBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return secp256k1_ecdsa_recoverable_signature_parse_compact(
                ctx, &recoverableSignature, signaturePtr, recid
            )
        }

        guard parseResult == 1 else {
            throw InviteSignatureError.invalidSignature
        }

        var pubkey = secp256k1_pubkey()

        let recoverResult = messageHash.withUnsafeBytes { msgBuffer -> Int32 in
            guard let msgPtr = msgBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return secp256k1_ecdsa_recover(ctx, &pubkey, &recoverableSignature, msgPtr)
        }

        guard recoverResult == 1 else {
            throw InviteSignatureError.verificationFailure
        }

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
            throw InviteSignatureError.verificationFailure
        }

        return Data(bytes: outputPtr, count: outputLen)
    }
}

// MARK: - InvitePayload Signing Extension

extension InvitePayload {
    /// Sign this payload with a private key
    /// - Parameter privateKey: 32-byte secp256k1 private key
    /// - Returns: 65-byte signature
    public func sign(with privateKey: Data) throws -> Data {
        try InviteSigner.sign(payload: self, privateKey: privateKey)
    }
}

// MARK: - SignedInvite Verification Extension

extension SignedInvite {
    /// Verify this invite against an expected public key
    /// - Parameter expectedPublicKey: The expected signer's public key
    /// - Returns: true if valid
    public func verify(with expectedPublicKey: Data) throws -> Bool {
        try InviteSigner.verify(signedInvite: self, expectedPublicKey: expectedPublicKey)
    }

    /// Recover the signer's public key from this invite
    /// - Returns: The recovered public key (65 bytes, uncompressed)
    public func recoverSignerPublicKey() throws -> Data {
        try InviteSigner.recoverPublicKey(from: self)
    }
}
