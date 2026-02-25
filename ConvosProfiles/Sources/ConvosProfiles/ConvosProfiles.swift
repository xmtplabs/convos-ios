// ConvosProfiles - Profile management for XMTP conversations
//
// This module provides APIs for managing per-conversation profiles
// in XMTP groups, including image encryption.
//
// ## Re-exported Types (from ConvosAppData)
//
// - `ConversationCustomMetadata`: Container for all custom metadata
// - `ConversationProfile`: Per-conversation member profile
// - `EncryptedImageRef`: Reference to an encrypted image
//
// ## Image Encryption
//
// ```swift
// import ConvosProfiles
//
// // Generate a group key (store in ConversationCustomMetadata.imageEncryptionKey)
// let groupKey = try ImageEncryption.generateGroupKey()
//
// // Encrypt an image
// let payload = try ImageEncryption.encrypt(imageData: jpegData, groupKey: groupKey)
// // Upload payload.ciphertext, store salt/nonce in EncryptedImageRef
//
// // Decrypt an image
// let params = EncryptedImageParams(encryptedRef: ref, groupKey: groupKey)
// let imageData = try await EncryptedImageLoader.loadAndDecrypt(params: params)
// ```
//
// ## Profile Management
//
// ```swift
// // Parse profiles from group appData
// let metadata = ConversationCustomMetadata.parseAppData(try group.appData())
//
// // Find/update profiles
// let profile = metadata.findProfile(inboxId: targetInboxId)
// metadata.upsertProfile(newProfile)
//
// // Write back to group
// try await group.updateAppData(appData: metadata.toCompactString())
// ```

@_exported import ConvosAppData
