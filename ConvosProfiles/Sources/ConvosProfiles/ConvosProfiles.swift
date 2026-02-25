// ConvosProfiles - Profile management for XMTP conversations
//
// This module provides APIs for managing per-conversation profiles
// in XMTP groups, using the shared types from ConvosAppData.
//
// ## Re-exported Types (from ConvosAppData)
//
// - `ConversationCustomMetadata`: Container for all custom metadata
// - `ConversationProfile`: Per-conversation member profile
// - `EncryptedImageRef`: Reference to an encrypted image
//
// ## Usage
//
// ```swift
// import ConvosProfiles
// import XMTPiOS
//
// // Parse profiles from group appData
// let appDataString = try group.appData()
// let metadata = ConversationCustomMetadata.parseAppData(appDataString)
//
// // Find a specific profile
// let profile = metadata.findProfile(inboxId: targetInboxId)
//
// // Update a profile
// var updatedMetadata = metadata
// updatedMetadata.upsertProfile(newProfile)
// let encoded = try updatedMetadata.toCompactString()
// try await group.updateAppData(appData: encoded)
// ```

// Re-export ConvosAppData types so consumers only need to import ConvosProfiles
@_exported import ConvosAppData
@_exported import XMTPiOS
