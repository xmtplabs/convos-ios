// ConvosAppData - Shared types for XMTP group appData storage
//
// This module provides the protobuf types stored in XMTP's Group.appData field,
// shared across Convos feature packages (Invites, Profiles, Explode).
//
// ## Types
//
// - `ConversationCustomMetadata`: Container for all custom metadata
// - `ConversationProfile`: Per-conversation member profile
// - `EncryptedImageRef`: Reference to an encrypted image
//
// ## Fields in ConversationCustomMetadata
//
// | Field | Used By | Purpose |
// |-------|---------|---------|
// | `tag` | Invites | Invite verification tag |
// | `profiles` | Profiles | Array of member profiles |
// | `expiresAtUnix` | Explode | Conversation expiration timestamp |
// | `imageEncryptionKey` | Profiles | AES-256 key for image encryption |
// | `encryptedGroupImage` | Profiles | Encrypted group avatar |
//
// ## Serialization
//
// ```swift
// // Encode to compact string (with compression)
// let encoded = try metadata.toCompactString()
//
// // Decode from string
// let decoded = try ConversationCustomMetadata.fromCompactString(encoded)
//
// // Parse from XMTP appData (handles empty/invalid gracefully)
// let metadata = ConversationCustomMetadata.parseAppData(group.appData())
// ```

// Re-export all types
@_exported import struct Foundation.Data
