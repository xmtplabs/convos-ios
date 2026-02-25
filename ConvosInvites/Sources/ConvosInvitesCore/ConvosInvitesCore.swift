// ConvosInvitesCore - Core cryptographic primitives for XMTP invite tokens
//
// This module provides the cryptographic foundation for XMTP invite tokens,
// with no dependency on the XMTP SDK. Use this if you need:
// - Custom XMTP integration
// - Testing without XMTP
// - Cross-platform compatibility (the crypto is standard)
//
// ## Core Components
//
// - `InviteToken`: Encrypt/decrypt conversation IDs using ChaCha20-Poly1305
// - `InviteSigner`: Sign/verify invite payloads using secp256k1 ECDSA
// - `InviteEncoder`: URL-safe Base64 encoding with DEFLATE compression
// - `SignedInvite`: Protobuf message combining payload and signature
//
// ## Usage
//
// ```swift
// import ConvosInvitesCore
//
// // Create an invite token
// let tokenBytes = try InviteToken.encrypt(
//     conversationId: groupId,
//     creatorInboxId: myInboxId,
//     privateKey: myPrivateKey
// )
//
// // Build and sign the payload
// var payload = InvitePayload()
// payload.tag = inviteTag
// payload.conversationToken = tokenBytes
// payload.creatorInboxID = Data(hexString: myInboxId)!
//
// let signature = try payload.sign(with: myPrivateKey)
//
// var signedInvite = SignedInvite()
// try signedInvite.setPayload(payload)
// signedInvite.signature = signature
//
// // Encode to shareable URL
// let slug = try signedInvite.toURLSafeSlug()
// ```

// Types are defined in Core/Proto/invite.pb.swift:
// - InvitePayload
// - SignedInvite
