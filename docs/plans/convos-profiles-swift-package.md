# ConvosProfiles Swift Package Design

> **Status**: Phase 2 Complete  
> **Created**: 2025-02-25  
> **Updated**: 2026-02-26  
> **Stacked on**: convos-invites-package

## Overview

Extract the Convos per-conversation profile system into a reusable Swift package (`ConvosProfiles`) that any XMTP iOS app can adopt.

## Current Architecture

### ConvosAppData (Shared Foundation)

The shared protobuf types are now in `ConvosAppData`:

```
ConvosAppData/
├── ConversationCustomMetadata   # Container for all metadata
├── ConversationProfile          # Profile with inboxId, name, image
├── EncryptedImageRef            # Encrypted image reference
├── Serialization helpers        # Base64URL, DEFLATE compression
└── Profile collection helpers   # upsert, find, remove
```

### ConvosProfiles (This Package)

Image encryption and profile loading utilities:

```
ConvosProfiles/
├── ConvosProfiles/
│   ├── Crypto/ImageEncryption.swift       # AES-256-GCM image encryption/decryption
│   └── Crypto/EncryptedImageLoader.swift  # Encrypted image loading protocol
└── ConvosProfilesCore/
    ├── ProfileHelpers.swift               # Re-exported from ConvosAppData
    └── Proto/conversation_profile.pb.swift
```

### Dependency Graph

```
ConvosAppData (shared types)
       ↑
ConvosProfiles (re-exports + future features)
       ↑
ConvosCore (app-specific logic)
```

## Future Direction

### Phase 3: Profile Content Type (Future)

Similar to how ConvosInvites handles invite join requests via a custom content type, ConvosProfiles will handle profile distribution:

**Current approach (appData):**
- Profiles stored in XMTP group's `appData` field
- All members can read, only admins can write
- Limited by 8KB appData size

**Future approach (content type):**
- Define a "profile welcome" content type
- When adding members, send a welcome message containing group profiles
- ProfileCoordinator processes incoming profile messages
- Scales better for large groups

```swift
// Future API (similar to InviteCoordinator)
public actor ProfileCoordinator {
    /// Process incoming profile welcome messages
    func processMessage(_ message: XMTPiOS.DecodedMessage) async throws -> ProfileUpdate?
    
    /// Send profiles when adding a member
    func sendWelcomeProfiles(
        to newMember: String,
        in group: XMTPiOS.Group,
        profiles: [ConversationProfile]
    ) async throws
}
```

## Completed Work

### Phase 1: Core Types ✅

1. Created `ConvosAppData` package with shared protobuf types
2. Created `ConvosProfiles` that re-exports ConvosAppData
3. Migrated ConvosCore to import from ConvosAppData
4. Removed ~1,250 lines of duplicated code from ConvosCore

### Phase 2: Image Encryption ✅

1. Moved AES-256-GCM image encryption/decryption to ConvosProfiles
2. Added `EncryptedImageLoader` protocol for encrypted image loading
3. 25 tests covering encryption, decryption, key derivation, and edge cases

### Test Coverage

| Package | Tests |
|---------|-------|
| ConvosAppData | 21 |
| ConvosProfiles | 25 |
| ConvosInvites | 120 |
| ConvosCore | 323 |
| **Total** | **489** |

## API Reference

### Types (from ConvosAppData)

```swift
// Profile with per-conversation identity
ConversationProfile
  .inboxIdString: String           // Hex-encoded XMTP inbox ID
  .name: String?                   // Display name
  .image: String?                  // Legacy image URL
  .encryptedImage: EncryptedImageRef?  // Encrypted image
  .effectiveImageUrl: String?      // Best available image URL

// Encrypted image reference
EncryptedImageRef
  .url: String                     // S3 URL to ciphertext
  .salt: Data                      // 32-byte HKDF salt
  .nonce: Data                     // 12-byte AES-GCM nonce
  .isValid: Bool                   // Validates component sizes

// Metadata container
ConversationCustomMetadata
  .tag: String                     // Invite verification tag
  .profiles: [ConversationProfile] // Member profiles
  .expiresAtUnix: Int64?           // Expiration timestamp
  .imageEncryptionKey: Data?       // 32-byte AES key
  .encryptedGroupImage: EncryptedImageRef?
```

### Serialization (from ConvosAppData)

```swift
// Encode metadata for XMTP appData
let encoded = try metadata.toCompactString()

// Decode from XMTP appData
let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

// Parse with graceful fallback
let metadata = ConversationCustomMetadata.parseAppData(group.appData())
```

### Profile Management (from ConvosAppData)

```swift
// On ConversationCustomMetadata
metadata.upsertProfile(profile)
metadata.removeProfile(inboxId: "...")
metadata.findProfile(inboxId: "...")

// On [ConversationProfile]
profiles.upsert(profile)
profiles.remove(inboxId: "...")
profiles.find(inboxId: "...")
```

## Related Documents

- [ADR 005: Profile Storage](../adr/005-profile-storage-in-conversation-metadata.md)
- [ConvosInvites Package](./convos-invites-swift-package.md)
- [Extensions Architecture](./convos-extensions-architecture.md)
