# Encrypted Profile Pictures and Group Images

## Summary

Encrypt user profile pictures (PFPs) and group images so only group members can decrypt them. Uses the **lean approach** recommended by Nick: a single AES-256 encryption key per group, with per-image salt/nonce stored in metadata.

### Trade-offs Accepted
- **No key rotation**: Kicked members retain the old key but lose access to new image metadata (URL/salt/nonce)
- **Group key in metadata**: Stored in XMTP's encrypted group storage, accessible only to current members

## Scope

- **Both** profile pictures AND group images encrypted
- **S3 storage** (existing infrastructure)
- **Shared group key** (lean approach)

## Architecture

```
Encryption Flow:
  plaintext image → compress → encrypt(AES-256-GCM) → upload ciphertext to S3
                                    ↑
                    derived from: groupKey + random salt + random nonce

Storage (in group metadata):
  - imageEncryptionKey: 32-byte AES key (once per group)
  - Per image: { url, salt, nonce }

Decryption Flow:
  fetch ciphertext → decrypt(groupKey, salt, nonce) → display
                              ↓
              AES-GCM auth tag verifies integrity
```

## Implementation Steps

### Phase 1: Protobuf Schema Update

**File**: `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/proto/conversation_custom_metadata.proto`

Add encrypted image reference type and group key:

```protobuf
message EncryptedImageRef {
    string url = 1;      // S3 URL to encrypted ciphertext
    bytes salt = 2;      // 32-byte HKDF salt
    bytes nonce = 3;     // 12-byte AES-GCM nonce
    // No digest needed - AES-GCM auth tag provides integrity
}

message ConversationProfile {
    bytes inboxId = 1;
    optional string name = 2;
    optional string image = 3;                    // Legacy (backward compat)
    optional EncryptedImageRef encryptedImage = 4; // New encrypted ref
}

message ConversationCustomMetadata {
    string tag = 1;
    repeated ConversationProfile profiles = 2;
    optional sfixed64 expiresAtUnix = 3;
    optional bytes imageEncryptionKey = 4;        // 32-byte group key
    optional EncryptedImageRef encryptedGroupImage = 5;
}
```

### Size Impact

**Stored once per group:**
- `imageEncryptionKey`: 32 bytes

**Per-image overhead** (in addition to URL):

| Field | Size | Why unique per image |
|-------|------|---------------------|
| `salt` | 32 bytes | Different derived key per image via HKDF |
| `nonce` | 12 bytes | AES-GCM requires unique nonce per encryption |
| protobuf overhead | ~4 bytes | Field tags and length prefixes |

**Total per-image overhead**: ~48 bytes over plain URL

The salt ensures each image gets a different derived key via `HKDF(groupKey, salt)`, so compromising one image's ciphertext doesn't help decrypt others.

**Example capacity** (within 8KB limit):
- 10-member group with 10 encrypted PFPs + 1 group image = ~528 bytes additional overhead

### Phase 2: Core Encryption Module

**New file**: `ConvosCore/Sources/ConvosCore/Crypto/ImageEncryption.swift`

- `generateGroupKey() -> Data` - 32-byte random key
- `encrypt(imageData:groupKey:) -> EncryptedPayload` - AES-256-GCM with HKDF
- `decrypt(ciphertext:groupKey:salt:nonce:) -> Data` - decrypt (AES-GCM auth tag verifies integrity)

Key derivation: `HKDF-SHA256(groupKey, salt, "ConvosImageV1", 32)`

### Phase 3: Group Key Management

**Modify**: `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`

Add:
- `imageEncryptionKey: Data?` - retrieve key from metadata
- `ensureImageEncryptionKey() async throws` - generate if missing (idempotent)

Call `ensureImageEncryptionKey()` in `StreamProcessor.swift` when creator sets up group (alongside `ensureInviteTag()`).

### Phase 4: Encrypted Upload Flow

**Modify**: `ConvosCore/Sources/ConvosCore/Storage/Writers/MyProfileWriter.swift`

```swift
func update(avatar:conversationId:) {
    // 1. Get group and ensure encryption key exists
    let groupKey = try await group.ensureImageEncryptionKey()

    // 2. Compress image
    let imageData = ImageCacheContainer.shared.resizeCacheAndGetData(...)

    // 3. Encrypt
    let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

    // 4. Upload ciphertext
    let url = try await apiClient.uploadAttachment(
        data: encrypted.ciphertext,
        filename: "ep-\(UUID()).enc",  // encrypted profile
        contentType: "application/octet-stream"
    )

    // 5. Store encrypted ref in metadata
    let encryptedRef = EncryptedImageRef(url, salt, nonce)
    let profile = profile.with(encryptedImage: encryptedRef)
    try await group.updateProfile(profile)

    // 6. Cache decrypted image locally
    ImageCacheContainer.shared.setImage(image, for: url)
}
```

**Modify**: `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift`

Similar changes for `updateImage(_:for:)` - encrypt group avatar.

### Phase 5: Encrypted Download Flow

**Modify**: `Convos/Shared Views/AvatarView.swift`

```swift
func loadImage() async {
    // Check cache first
    if let cached = await ImageCache.shared.imageAsync(for: object) {
        return cached
    }

    // Detect encrypted vs legacy
    if let encryptedRef = getEncryptedImageRef() {
        // Fetch ciphertext from S3
        let ciphertext = try await URLSession.shared.data(from: URL(string: encryptedRef.url)!)

        // Get group key
        let groupKey = try await getGroupEncryptionKey()

        // Decrypt and verify
        let plaintext = try ImageEncryption.decrypt(
            ciphertext: ciphertext,
            groupKey: groupKey,
            salt: encryptedRef.salt,
            nonce: encryptedRef.nonce
        )

        // Cache and display
        let image = UIImage(data: plaintext)
        ImageCache.shared.setImage(image, for: encryptedRef.url)
    } else {
        // Legacy unencrypted path (backward compat)
        await loadLegacyImage()
    }
}
```

### Phase 6: Backward Compatibility

- Old groups without `imageEncryptionKey` continue using unencrypted images
- Old clients reading new metadata see `nil` for `encryptedImage` field (graceful degradation)
- When group creator updates any image, key is auto-generated
- `image` field (legacy) kept for old clients; new clients prefer `encryptedImage`

## Files to Modify

| File | Change |
|------|--------|
| `conversation_custom_metadata.proto` | Add EncryptedImageRef, imageEncryptionKey, encryptedGroupImage |
| `conversation_custom_metadata.pb.swift` | Regenerate from proto |
| **NEW** `ImageEncryption.swift` | Core encrypt/decrypt logic |
| `XMTPGroup+CustomMetadata.swift` | Add key generation/retrieval |
| `StreamProcessor.swift` | Call ensureImageEncryptionKey on group create |
| `MyProfileWriter.swift` | Encrypt profile images before upload |
| `ConversationMetadataWriter.swift` | Encrypt group images before upload |
| `AvatarView.swift` | Decrypt images on load |
| `DBMemberProfile.swift` | Add encryptedImage property mapping |
| `ConversationProfile+Helpers.swift` | Add encrypted image helpers |

## Verification

1. **Unit tests**: `ImageEncryption` round-trip encrypt/decrypt
2. **Integration test**: Upload encrypted PFP, verify another member can decrypt
3. **Backward compat test**: Old unencrypted images still load
4. **Size test**: Verify metadata stays within 8KB for typical group sizes
5. **Manual test**: Build app, create group, set PFP, verify image loads for other members

## Security Considerations

### Do We Need a Digest?

**Nick's lean approach**: Store only `URL, salt, nonce` - no digest.

**Analysis**: AES-GCM is **authenticated encryption** - the 16-byte auth tag is appended to ciphertext and verifies integrity during decryption.

**Threat scenario:**
```
Attacker replaces S3 blob → User fetches → Decrypts with stored key/salt/nonce → FAILS
                                                                                 ↑
                                                           Auth tag won't match
```

**Conclusion**: Digest is **redundant** because:
- AES-GCM already verifies integrity via auth tag
- Attacker can't create valid ciphertext without knowing key + salt + nonce
- If blob is swapped/corrupted, decryption fails automatically

**Decision: TBD** - Leaning toward **no digest** (saves 32 bytes per image)

| With digest | Without digest (lean) |
|-------------|----------------------|
| ~80 bytes/image overhead | ~48 bytes/image overhead |
| Redundant integrity check | AES-GCM auth tag sufficient |
| Nick's "rigorous" approach | Nick's recommended approach |

### Key Rotation Analysis

**Question**: Should we rotate the encryption key when a member is removed?

#### What Rotation Would Require

When a member is removed:
1. Generate new `imageEncryptionKey`
2. Re-encrypt ALL existing images with new key
3. Re-upload all images to new S3 URLs
4. Update all `EncryptedImageRef` entries in metadata

#### Pros of Rotation

| Pro | Benefit |
|-----|---------|
| Forward secrecy | Kicked member can't decrypt future images |
| Stronger security | Kicked member can't decrypt ANY images (past or future) |

#### Cons of Rotation

| Con | Impact |
|-----|--------|
| Expensive operation | Must re-encrypt & re-upload ALL images (N members × PFPs + group image) |
| Race conditions | What if member uploads image during rotation? |
| Metadata bloat | Each rotation = new URLs for all images |
| Network cost | Re-upload potentially dozens of images |
| Complexity | Significant implementation overhead |
| **Already mitigated** | Kicked member loses access to metadata (URL/salt/nonce) anyway |

#### Nick's Key Insight

> "Without rotation, someone who was kicked out would have the encryption key for future user's PFPs and future group images. **But, they wouldn't have access to the URL, salt, or nonce.** They would have to download every asset in your S3 bucket and then try every possible nonce against each one... which quickly gets to be an impractical number of operations."

#### Security Model (Lean Approach)

```
Encryption key  → provides confidentiality
Metadata access → provides authorization (URL + salt + nonce)
XMTP            → controls metadata access on member removal
```

A kicked member has the old key but:
- Can't read new metadata (XMTP removes access)
- Doesn't know new image URLs
- Doesn't have salt/nonce for new images
- Would need to brute-force every S3 object × every possible nonce (infeasible)

#### Preferred: No Key Rotation (v1)

Stick with the lean approach for v1. The security trade-off is acceptable because metadata access control (via XMTP) provides effective authorization.

**Future enhancement path** (if needed):
- v1: No rotation (lean, ship fast)
- v2: Optional rotation for high-security groups

## Decisions

1. **Migration strategy**: Only encrypt new uploads (no migration of existing images)

2. **URL storage**: Upload encrypted blob to S3 same as now, store full URL in group metadata

3. **Same encryption for all images**: Both profile pictures (per member) AND group photo use the same `imageEncryptionKey` and `EncryptedImageRef` structure - just stored in different metadata fields

4. **No key rotation**: Rely on XMTP metadata access control rather than key rotation when members are removed
