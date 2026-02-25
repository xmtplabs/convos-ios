// ConvosProfiles - Full profile system with XMTP SDK integration
//
// This module provides high-level APIs for managing per-conversation
// profiles in XMTP groups, built on top of ConvosProfilesCore.
//
// ## Components
//
// - `ProfileCoordinator`: High-level API for profile management
// - Profile storage in XMTP group appData
//
// ## Usage
//
// ```swift
// import ConvosProfiles
// import XMTPiOS
//
// // Get profiles from a group
// let profiles = try ProfileStorage.getProfiles(from: group)
//
// // Update my profile
// try await ProfileStorage.updateProfile(
//     inboxId: myInboxId,
//     name: "Alice",
//     imageUrl: "https://example.com/avatar.jpg",
//     in: group
// )
// ```

@_exported import ConvosProfilesCore
@_exported import XMTPiOS
