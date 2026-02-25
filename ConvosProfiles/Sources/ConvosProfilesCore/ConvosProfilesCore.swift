// ConvosProfilesCore - Core types for per-conversation profiles
//
// This module provides the foundational types for XMTP per-conversation profiles,
// with no dependency on the XMTP SDK. Use this if you need:
// - Custom XMTP integration
// - Testing without XMTP
// - Cross-platform compatibility
//
// ## Core Components
//
// - `ConversationProfile`: Profile data stored in XMTP group metadata
// - `EncryptedImageRef`: Reference to an encrypted profile image
// - Profile collection helpers for managing arrays of profiles
//
// ## Usage
//
// ```swift
// import ConvosProfilesCore
//
// // Create a profile
// var profile = ConversationProfile(
//     inboxIdString: "abc123...",
//     name: "Alice",
//     imageUrl: "https://example.com/avatar.jpg"
// )
//
// // Or with encrypted image
// var encryptedRef = EncryptedImageRef()
// encryptedRef.url = "https://s3.example.com/encrypted.bin"
// encryptedRef.salt = saltData
// encryptedRef.nonce = nonceData
//
// profile = ConversationProfile(
//     inboxIdString: "abc123...",
//     name: "Alice",
//     encryptedImageRef: encryptedRef
// )
//
// // Manage profile collections
// var profiles: [ConversationProfile] = []
// profiles.upsert(profile)
// let found = profiles.find(inboxId: "abc123...")
// profiles.remove(inboxId: "abc123...")
// ```

// Types are defined in Proto/conversation_profile.pb.swift:
// - ConversationProfile
// - EncryptedImageRef
