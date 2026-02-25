// XMTPInvites - Reusable invite system for XMTP apps
//
// This package provides cryptographic invite tokens for XMTP group conversations.
// It enables apps to create shareable invite links that:
// - Encrypt conversation IDs (only creator can derive the key)
// - Sign with creator's identity (prevents forgery)
// - Support optional expiration and single-use flags
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
// let inviteURL = URL(string: "https://convos.org/i/\(slug)")!
// ```

// Types are defined in Core/Proto/invite.pb.swift:
// - InvitePayload
// - SignedInvite
