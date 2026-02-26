# ConvosProfiles

A Swift package for managing per-conversation profiles and encrypted images in XMTP group conversations. Built on [ConvosAppData](../ConvosAppData/) for shared protobuf types.

## Overview

ConvosProfiles provides:

- **Image encryption** using AES-256-GCM with HKDF-derived keys for storing conversation avatars securely
- **Encrypted image loading** protocol for integrating with your app's image pipeline
- **Profile types** (re-exported from ConvosAppData) for per-conversation member identities

Each conversation has its own encryption key stored in the group's `appData`, so images are only decryptable by group members.

## Features

- 🔐 **AES-256-GCM** image encryption with per-conversation keys
- 🔑 **HKDF-SHA256** key derivation with unique salt and nonce per image
- 📦 **EncryptedImageRef** type for storing encrypted image metadata alongside the ciphertext URL
- 👤 **ConversationProfile** with support for encrypted avatars
- 🖼️ **EncryptedImageLoader** protocol for pluggable image loading

## Installation

Add ConvosProfiles to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../ConvosProfiles"),
]
```

### Products

| Product | Description | Use Case |
|---------|-------------|----------|
| `ConvosProfiles` | Full package with image encryption | Production apps |
| `ConvosProfilesCore` | Core types only (re-exports ConvosAppData) | Lightweight usage |

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ConvosProfiles", package: "ConvosProfiles"),
    ]
)
```

## Quick Start

### Encrypting an Image

```swift
import ConvosProfiles

// 1. Generate a group key (once per conversation, store in appData)
let groupKey = try ImageEncryption.generateGroupKey()

// 2. Encrypt an image
let result = try ImageEncryption.encrypt(imageData: jpegData, groupKey: groupKey)
// result.ciphertext  → upload to storage (e.g., S3)
// result.salt        → 32 bytes, store in EncryptedImageRef
// result.nonce       → 12 bytes, store in EncryptedImageRef

// 3. Create an EncryptedImageRef
var ref = EncryptedImageRef()
ref.url = "https://storage.example.com/encrypted/abc123"
ref.salt = result.salt
ref.nonce = result.nonce
```

### Decrypting an Image

```swift
import ConvosProfiles

// 1. Retrieve the group key and encrypted image ref from appData
let metadata = ConversationCustomMetadata.parseAppData(try group.appData())
guard let groupKey = metadata.imageEncryptionKey,
      let ref = someProfile.encryptedImage else { return }

// 2. Download the ciphertext from the URL
let ciphertext = try await downloadData(from: ref.url)

// 3. Decrypt
let imageData = try ImageEncryption.decrypt(
    ciphertext: ciphertext,
    groupKey: groupKey,
    salt: ref.salt,
    nonce: ref.nonce
)
```

### Managing Profiles

```swift
import ConvosProfiles  // Re-exports ConvosAppData types

// Parse profiles from group appData
var metadata = ConversationCustomMetadata.parseAppData(try group.appData())

// Find a member's profile
let profile = metadata.findProfile(inboxId: memberInboxId)
print(profile?.name ?? "Anonymous")

// Update your profile
var myProfile = ConversationProfile()
myProfile.name = "Alice"
myProfile.inboxID = Data(hexString: myInboxId)!
myProfile.encryptedImage = ref  // From encryption step above
metadata.upsertProfile(myProfile)

// Write back to group
try await group.updateAppData(appData: metadata.toCompactString())
```

## API Reference

### ImageEncryption

AES-256-GCM encryption with HKDF-derived keys for image data.

```swift
/// Generate a random 32-byte group key
static func generateGroupKey() throws -> Data

/// Encrypt image data
static func encrypt(
    imageData: Data,
    groupKey: Data
) throws -> EncryptionResult
// Returns: ciphertext, salt (32 bytes), nonce (12 bytes)

/// Decrypt image data
static func decrypt(
    ciphertext: Data,
    groupKey: Data,
    salt: Data,
    nonce: Data
) throws -> Data
```

### EncryptedImageLoader

Protocol for integrating encrypted image loading with your app's image pipeline:

```swift
protocol EncryptedImageLoader {
    func loadEncryptedImage(
        url: URL,
        groupKey: Data,
        salt: Data,
        nonce: Data
    ) async throws -> Data
}
```

### Re-exported Types (from ConvosAppData)

All ConvosAppData types are available when importing ConvosProfiles:

- `ConversationCustomMetadata` — metadata container
- `ConversationProfile` — member profile with name, image, encrypted image
- `EncryptedImageRef` — encrypted image reference (URL, salt, nonce)
- Serialization helpers (Base64URL, DEFLATE compression)
- Profile collection helpers (upsert, find, remove)

## Security Considerations

### Key Management

- Each conversation has a unique 32-byte `imageEncryptionKey` stored in `appData`
- Only group members can read `appData`, so only members can decrypt images
- Keys are generated using `SecRandomCopyBytes` via CryptoKit

### Per-Image Uniqueness

- Each encrypted image has a unique 32-byte salt and 12-byte nonce
- HKDF-SHA256 derives a unique encryption key per image from the group key + salt
- This ensures identical images produce different ciphertexts

### Image Rotation

When updating an image, generate new salt and nonce. The group key can remain the same unless you want to revoke access to all previous images.

## Testing

```bash
cd ConvosProfiles
swift test
```

25 tests covering encryption, decryption, key generation, invalid inputs, and edge cases.

## License

MIT License - See LICENSE file for details.
