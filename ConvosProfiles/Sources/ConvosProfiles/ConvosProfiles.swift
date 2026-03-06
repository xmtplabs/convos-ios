// ConvosProfiles - Profile management for XMTP conversations
//
// This module provides APIs for managing per-conversation profiles
// in XMTP groups using message-based storage.
//
// ## Profile Messages
//
// Profiles are stored as XMTP group messages (not appData), using two content types:
//
// - `ProfileUpdateCodec`: Sent by a member when they change their own profile
// - `ProfileSnapshotCodec`: Sent when adding members, contains all current profiles
//
// ```swift
// import ConvosProfiles
//
// // Register codecs with XMTP client
// let client = try await Client.create(
//     account: account,
//     options: .init(codecs: [ProfileUpdateCodec(), ProfileSnapshotCodec()])
// )
//
// // Send a profile update
// let update = ProfileUpdate(name: "Alice", encryptedImage: imageRef)
// let encoded = try ProfileUpdateCodec().encode(content: update)
// try await group.send(encodedContent: encoded)
//
// // Send a snapshot after adding a member
// try await ProfileSnapshotBuilder.sendSnapshot(group: group, memberInboxIds: allMemberIds)
// ```
//
// ## Image Encryption
//
// ```swift
// // Generate a group key (store in ConversationCustomMetadata.imageEncryptionKey)
// let groupKey = try ImageEncryption.generateGroupKey()
//
// // Encrypt an image
// let payload = try ImageEncryption.encrypt(imageData: jpegData, groupKey: groupKey)
// // Upload payload.ciphertext, store salt/nonce in EncryptedProfileImageRef
//
// // Decrypt an image
// let params = EncryptedImageParams(encryptedRef: ref, groupKey: groupKey)
// let imageData = try await EncryptedImageLoader.loadAndDecrypt(params: params)
// ```
//
// ## Re-exported Types (from ConvosAppData)
//
// - `ConversationCustomMetadata`: Container for group-level metadata (tag, keys, expiration)
// - `ConversationProfile`: Legacy profile type (for backward compatibility with appData)
// - `EncryptedImageRef`: Shared encrypted image reference type

@_exported import ConvosAppData
