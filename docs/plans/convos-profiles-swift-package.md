# ConvosProfiles Swift Package Design

> **Status**: In Progress  
> **Created**: 2025-02-25  
> **Stacked on**: convos-invites-package

## Overview

Extract the Convos per-conversation profile system into a reusable Swift package (`ConvosProfiles`) that any XMTP iOS app can adopt.

## Challenge: Shared Metadata

Unlike invites (which have their own protobuf), profiles share the `ConversationCustomMetadata` protobuf with:
- **Invites**: `tag` field
- **Profiles**: `profiles` array, `imageEncryptionKey`, `encryptedGroupImage`
- **Explode**: `expiresAtUnix` field

### Solution: Shared Metadata Package

Create a `ConvosMetadata` package containing the shared protobuf definitions, then have feature packages depend on it.

```
ConvosMetadata/              # Shared protobuf definitions
├── ConversationCustomMetadata
├── ConversationProfile
├── EncryptedImageRef

ConvosInvites/               # Invite system (already done)
├── InvitePayload, SignedInvite (own protobufs)
├── Uses ConversationCustomMetadata.tag via ConvosCore

ConvosProfiles/              # Profile system (this package)
├── depends on: ConvosMetadata
├── ProfileStorage - read/write profiles in XMTP metadata
├── ProfileHelpers - ConversationProfile extensions

ConvosExplode/               # Future: Expiration system  
├── depends on: ConvosMetadata
```

## Package Structure

```
ConvosProfiles/
├── Package.swift
├── Sources/
│   ├── ConvosProfilesCore/           # Core types, no XMTP dependency
│   │   ├── Proto/
│   │   │   └── conversation_profile.pb.swift
│   │   ├── ProfileHelpers.swift      # ConversationProfile extensions
│   │   └── EncryptedImageRef.swift   # Image ref helpers
│   │
│   └── ConvosProfiles/               # XMTP integration
│       ├── ProfileCoordinator.swift  # High-level API
│       ├── ProfileStorage.swift      # Read/write from XMTP appData
│       └── Models.swift              # ProfileUpdate, etc.
│
└── Tests/
    ├── ConvosProfilesCoreTests/
    └── ConvosProfilesTests/
```

## API Design

### Core Layer (No XMTP Dependency)

```swift
// MARK: - ConversationProfile Extensions

extension ConversationProfile {
    /// InboxId as hex string
    var inboxIdString: String
    
    /// Effective image URL (encrypted or legacy)
    var effectiveImageUrl: String?
    
    /// Initialize with hex inbox ID
    init?(inboxIdString: String, name: String?, imageUrl: String?)
    init?(inboxIdString: String, name: String?, encryptedImageRef: EncryptedImageRef)
}

// MARK: - EncryptedImageRef Extensions

extension EncryptedImageRef {
    var isValid: Bool
}

// MARK: - Profile Collection Helpers

extension Array where Element == ConversationProfile {
    mutating func upsert(_ profile: ConversationProfile)
    mutating func remove(inboxId: String) -> Bool
    func find(inboxId: String) -> ConversationProfile?
}
```

### XMTP Integration Layer

```swift
/// Coordinates profile storage in XMTP group metadata
public actor ProfileCoordinator {
    
    init(client: XMTPiOS.Client)
    
    /// Get profiles for a group
    func getProfiles(for group: XMTPiOS.Group) throws -> [ConversationProfile]
    
    /// Update my profile in a group
    func updateMyProfile(
        in group: XMTPiOS.Group,
        name: String?,
        imageUrl: String?
    ) async throws
    
    /// Update my profile with encrypted image
    func updateMyProfile(
        in group: XMTPiOS.Group,
        name: String?,
        encryptedImage: EncryptedImageRef
    ) async throws
    
    /// Remove a profile from a group
    func removeProfile(
        inboxId: String,
        from group: XMTPiOS.Group
    ) async throws
}
```

## Migration Path

### Phase 1: Extract Core Profile Types (This PR)

1. Create `ConvosProfiles` package
2. Copy `ConversationProfile` and `EncryptedImageRef` protobuf types
3. Move `ConversationProfile+Helpers.swift` logic
4. Add tests

### Phase 2: Extract Profile Storage

1. Create `ProfileCoordinator` for XMTP integration
2. Extract profile read/write from `XMTPGroup+CustomMetadata.swift`
3. Handle shared metadata format (profiles coexist with tag, expiresAt)

### Phase 3: Update ConvosCore

1. Add `ConvosProfiles` as dependency
2. Update imports to use package types
3. Remove extracted code

## Considerations

### Shared Metadata Encoding

The `ConversationCustomMetadata` protobuf contains fields for multiple features. When updating profiles:

1. Read existing metadata (preserves tag, expiresAt, etc.)
2. Update only the profiles array
3. Write back complete metadata

This ensures profile updates don't clobber invite tags or expiration settings.

### Image Encryption

Profile images can be encrypted using a per-group key stored in `imageEncryptionKey`. The package should:
- Support both legacy (unencrypted URL) and encrypted image refs
- Not handle actual encryption (leave to app layer)
- Provide helpers for working with `EncryptedImageRef`

## Dependencies

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf", from: "1.28.0"),
    .package(url: "https://github.com/xmtp/libxmtp", ...),  // For XMTP integration
]
```

## Related Files in ConvosCore

**Protobuf:**
- `conversation_custom_metadata.pb.swift` - Shared metadata definitions
- `proto/conversation_custom_metadata.proto` - Source proto file

**Profile Logic:**
- `ConversationProfile+Helpers.swift` - Profile extensions
- `ConversationCustomMetadata+Profiles.swift` - Metadata profile helpers

**XMTP Integration:**
- `XMTPGroup+CustomMetadata.swift` - Read/write metadata from XMTP

**Database (stays in ConvosCore):**
- `DBMemberProfile.swift` - Local profile storage
- `MyProfileWriter.swift` - Profile update logic
- `MyProfileRepository.swift` - Profile queries

## References

- [ADR 005: Profile Storage in Conversation Metadata](../adr/005-profile-storage-in-conversation-metadata.md)
- [ConvosInvites Package](./convos-invites-swift-package.md)
