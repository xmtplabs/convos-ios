# ConvosAppData

A Swift package providing shared protobuf types and serialization helpers for XMTP group `appData` storage. This is the foundation layer used by [ConvosInvites](../ConvosInvites/) and [ConvosProfiles](../ConvosProfiles/).

## Overview

XMTP groups have an 8KB `appData` field for custom metadata. ConvosAppData defines the protobuf schema and serialization for this field, enabling multiple features (invites, profiles, expiration) to share the same metadata container.

## Features

- 📋 **Protobuf types** for conversation metadata, profiles, and encrypted image references
- 🗜️ **DEFLATE compression** with automatic size optimization
- 🔗 **Base64URL encoding** for URL-safe serialization
- 👤 **Profile helpers** for managing per-conversation member profiles
- 🛡️ **Decompression bomb protection** with configurable size limits

## Installation

Add ConvosAppData to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../ConvosAppData"),
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ConvosAppData", package: "ConvosAppData"),
    ]
)
```

## Types

### ConversationCustomMetadata

The top-level container stored in XMTP's `appData` field:

| Field | Type | Used By | Purpose |
|-------|------|---------|---------|
| `tag` | `String` | Invites | Invite verification tag |
| `profiles` | `[ConversationProfile]` | Profiles | Member profiles |
| `expiresAtUnix` | `Int64` | Explode | Conversation expiration timestamp |
| `imageEncryptionKey` | `Data` | Profiles | 32-byte AES-256 key for image encryption |
| `encryptedGroupImage` | `EncryptedImageRef` | Profiles | Encrypted group avatar reference |

### ConversationProfile

Per-conversation member identity:

```swift
var inboxIdString: String           // Hex-encoded XMTP inbox ID
var name: String?                   // Display name
var image: String?                  // Legacy image URL
var encryptedImage: EncryptedImageRef?  // Encrypted image reference
var effectiveImageUrl: String?      // Best available image URL (encrypted preferred)
```

### EncryptedImageRef

Reference to an encrypted image stored externally:

```swift
var url: String      // URL to encrypted ciphertext (e.g., S3)
var salt: Data       // 32-byte HKDF salt
var nonce: Data      // 12-byte AES-GCM nonce
var isValid: Bool    // Validates component sizes
```

## Serialization

```swift
import ConvosAppData

// Encode metadata for XMTP appData (with automatic compression)
let encoded = try metadata.toCompactString()

// Decode from XMTP appData (with automatic decompression)
let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

// Parse with graceful fallback (returns empty metadata if invalid)
let metadata = ConversationCustomMetadata.parseAppData(group.appData())

// Check 8KB limit
let size = try metadata.toCompactString().utf8.count
guard size <= ConversationCustomMetadata.appDataByteLimit else {
    throw AppDataError.appDataLimitExceeded(currentSize: size, limit: 8192)
}
```

### Base64URL Encoding

```swift
// Encode
let encoded = data.base64URLEncoded()  // URL-safe, no padding

// Decode
let decoded = try encodedString.base64URLDecoded()
```

### DEFLATE Compression

```swift
// Compress only if result is smaller
let compressed = data.compressedIfSmaller()

// Decompress with size limit (prevents decompression bombs)
let decompressed = data.decompressedWithSize(maxSize: 10 * 1024 * 1024)
```

## Profile Management

Helpers on `ConversationCustomMetadata` and `[ConversationProfile]`:

```swift
var metadata = ConversationCustomMetadata.parseAppData(appDataString)

// Find a profile by inbox ID
let profile = metadata.findProfile(inboxId: "abc123...")

// Add or update a profile
var newProfile = ConversationProfile()
newProfile.name = "Alice"
newProfile.inboxID = Data(hexString: inboxId)!
metadata.upsertProfile(newProfile)

// Remove a profile
metadata.removeProfile(inboxId: "abc123...")

// Array-level helpers
var profiles = metadata.profiles
profiles.upsert(newProfile)
profiles.remove(inboxId: "abc123...")
let found = profiles.find(inboxId: "abc123...")
```

## Testing

```bash
cd ConvosAppData
swift test
```

21 tests covering serialization, compression, profile helpers, and edge cases.

## License

MIT License - See LICENSE file for details.
