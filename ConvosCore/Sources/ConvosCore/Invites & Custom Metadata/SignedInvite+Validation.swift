import CSecp256k1
import Foundation
import SwiftProtobuf

// MARK: - SignedInvite + Validation

/// Signature validation extensions for SignedInvite
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
