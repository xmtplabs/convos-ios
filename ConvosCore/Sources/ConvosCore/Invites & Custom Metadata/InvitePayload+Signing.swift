import CSecp256k1
import Foundation
import SwiftProtobuf

// MARK: - InvitePayload + Signing

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
