# ADR 005: Profile Storage in Conversation Metadata

## Status

Accepted

## Context

Convos uses a per-conversation identity model where each conversation has its own XMTP inbox (see ADR 002). To support user profiles (display names and avatars) in this model, we need a solution that:

- Works without a centralized profile server
- Maintains privacy isolation between conversations
- Allows users to have different profiles per conversation
- Supports optional profile sharing (users can remain anonymous)
- Works within XMTP's infrastructure constraints
- Provides good UX for users who want to reuse profiles

## Decision

We implemented **profile storage in XMTP conversation metadata** using the group's `appData` field. Each conversation stores member profiles in a compressed protobuf format, enabling serverless profile sharing while maintaining complete conversation isolation. A complementary **Quickname** feature provides local-only profile presets that users can quickly apply to new conversations without compromising privacy.

### 1. XMTP Custom Metadata Storage

Member profiles are stored directly in XMTP's group metadata using a custom protobuf schema.

**Protobuf Schema:**

```protobuf
message ConversationCustomMetadata {
    string tag = 1;                           // Invite verification tag (see ADR 001)
    repeated ConversationProfile profiles = 2; // Member profiles array
    optional sfixed64 expiresAtUnix = 3;      // Expiration timestamp (see ADR 004)
}

message ConversationProfile {
    bytes inboxId = 1;      // XMTP inbox ID as raw bytes (32 bytes)
    optional string name = 2;
    optional string image = 3;  // URL to uploaded avatar image
}
```

**Storage Format:**

```
Profile Data → ConversationProfile Protobuf →
ConversationCustomMetadata Array →
Protobuf Serialize →
DEFLATE Compress (if >100 bytes) →
Base64URL Encode →
XMTP appData (max 8KB)
```

**Key Design Decisions:**

1. **Binary Inbox IDs**: Stored as 32 raw bytes instead of 64-character hex strings, saving ~32 bytes per member
2. **URL-Based Avatars**: Store image URLs (80-100 chars) rather than image data to stay within 8KB limit
3. **DEFLATE Compression**: Applied when serialized data exceeds 100 bytes, achieving 20-40% size reduction
4. **Base64URL Encoding**: Safe storage in the string-based `appData` field

**Capacity:**

Based on testing:
- Each profile: ~142 bytes uncompressed (inbox ID + 25 char name + 80 char URL + overhead)
- With compression: 150+ profiles fit within 8KB limit
- Typical conversation (5-10 members): <1KB of metadata

**Location:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/proto/conversation_custom_metadata.proto`, `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`

### 2. Per-Conversation Profiles

Each user can have a different profile in each conversation, enforced by the database schema.

**Database Model:**

```swift
struct DBMemberProfile {
    let conversationId: String  // Part of composite primary key
    let inboxId: String         // Part of composite primary key
    let name: String?
    let avatar: String?         // URL to uploaded image
}
```

The composite primary key `(conversationId, inboxId)` ensures:
- Each user has exactly one profile per conversation
- No global identity exists across conversations
- Profiles are completely isolated from each other

**Example:**

A user might be:
- "Alice Smith" with a professional headshot in their work group
- "CryptoFan99" with an anonymous avatar in a hobby group
- "Mom" with a family photo in a family chat

These three profiles share nothing except that they're controlled by the same person's device. No external observer can link them.

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBMemberProfile.swift`

### 3. Quickname: Local Profile Presets

Quickname solves the UX problem of repeatedly entering profile information without compromising the privacy model.

**How It Works:**

1. User creates a "Quickname" profile locally (display name + optional avatar)
2. When joining/creating a new conversation, the app prompts: "Tap to chat as [Quickname]"
3. If tapped within countdown, Quickname profile is copied to the new conversation's per-conversation profile
4. User can modify the per-conversation profile independently afterward

**Storage:**

Quickname data is stored **locally only** and never transmitted:

- **UserDefaults**: Display name and randomizer settings as JSON (`QuicknameSettings` key)
- **Local filesystem**: Profile image as JPEG at `<Documents>/default-profile-image.jpg`
- **No cloud sync**: Quickname is device-specific

**Privacy Guarantee:**

When you use a Quickname in a conversation:
1. The display name and avatar are copied to that conversation's XMTP metadata
2. Other members see your profile for that conversation
3. They have **no way to know** you used a Quickname vs. manually entering the same information
4. Nothing on the network indicates profile reuse

**Location:** `Convos/Profile/QuicknameSettings.swift`, `Convos/Profile/QuicknameSettingsViewModel.swift`

### 4. Profile Photo Storage

Profile photos use a hybrid approach: images are uploaded to cloud storage, and only URLs are stored in metadata.

**Upload Flow:**

1. **Resize and Compress**: Images resized to max dimension and compressed to JPEG at 0.8 quality
2. **Upload to S3**: Uploaded via Convos API to S3-compatible storage with `public-read` ACL
3. **Store URL**: Only the URL (80-100 characters) is stored in XMTP metadata

**Image Caching:**

Three-tier cache ensures performance:
- **Memory**: NSCache with 600 item / 300MB limit
- **Disk**: 500MB limit with LRU eviction
- **Network**: Fetched from URL if not cached

Images are cached using SHA256-based filenames for automatic deduplication.

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Writers/MyProfileWriter.swift`, `ConvosCore/Sources/ConvosCore/Image Cache/ImageCache.swift`

### 5. Profile Update Flow

**Setting Your Profile:**

```
User updates name/avatar in UI
    ↓
MyProfileWriter.updateProfile()
    ↓
1. Upload avatar to S3 (if changed)
2. Get current XMTP metadata
3. Upsert profile in metadata array
4. Compress and encode metadata
5. Validate size < 8KB
6. Push to XMTP: group.updateAppData()
    ↓
XMTP syncs to all members
```

**Receiving Profile Updates:**

```
XMTP syncs group metadata
    ↓
ConversationWriter.syncConversation()
    ↓
1. Parse appData as ConversationCustomMetadata
2. Extract memberProfiles array
3. Save to DBMemberProfile table
    ↓
UI observes DBMemberProfile changes
    ↓
Display updated profile
```

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Writers/MyProfileWriter.swift`, `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationWriter.swift`

### 6. Privacy Model

The architecture ensures **no linkability** across conversations:

**Privacy Properties:**

1. **Different XMTP Identities**: Each conversation uses a separate XMTP inbox (ADR 002), so even identical profiles have different cryptographic identities

2. **No Central Profile Server**: No backend service stores or correlates profiles across conversations

3. **Local-Only Quickname**: Profile reuse happens entirely on-device; other participants can't detect it

4. **Scoped Storage**: Profiles stored in `appData` are scoped to the specific XMTP group

5. **Optional Profiles**: Users can participate anonymously (no name/avatar set)

**What's Shared:**

- Your profile in a specific conversation is visible to all members of that conversation
- Your avatar image URL is visible (but the hosting service doesn't know which conversations use it)

**What's NOT Shared:**

- Your profiles in other conversations
- The fact that you used Quickname
- Any connection between your profiles across conversations

**Location:** Design is inherent to the per-conversation storage model

### 7. Metadata Limits and Error Handling

**Hard Limit:** 8KB per XMTP group's `appData` field

**Capacity Planning:**

| Scenario | Estimated Size | Fits in 8KB? |
|----------|----------------|--------------|
| 10 members, full profiles | ~1.4 KB uncompressed, ~1 KB compressed | ✓ Yes |
| 50 members, full profiles | ~7.1 KB uncompressed, ~5 KB compressed | ✓ Yes |
| 150 members, full profiles | ~21.3 KB uncompressed, ~8 KB compressed | ✓ Just barely |
| 200+ members | Exceeds limit | ✗ No |

**Error Handling:**

If metadata exceeds 8KB:
```swift
throw ConversationCustomMetadataError.appDataLimitExceeded(
    currentSize: byteCount,
    limit: Self.appDataByteLimit
)
```

The app prevents the update and notifies the user.

**Decompression Bomb Protection:**

When reading compressed metadata:
- Maximum decompressed size: 10MB
- Maximum compression ratio: 100:1
- Prevents malicious metadata from consuming excessive memory

**Location:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`, `ConvosCore/Sources/ConvosCore/Utilities/Data+Compression.swift`

## Consequences

### Positive

- **No Profile Server**: Eliminates centralized infrastructure and associated privacy risks
- **Complete Privacy Isolation**: Profiles in different conversations cannot be linked
- **User Control**: Users choose their profile per-conversation
- **Serverless**: Profile sync handled entirely by XMTP infrastructure
- **Offline Capable**: Profiles stored in XMTP metadata work offline
- **Good UX**: Quickname makes profile reuse easy while preserving privacy
- **Efficient Storage**: Compression and binary encoding minimize metadata size
- **Anonymous Participation**: Profiles are optional, users can remain fully anonymous

### Negative

- **8KB Limit**: Very large conversations (200+ members) may hit metadata limits
- **No Global Identity**: Users must set up profiles per-conversation (mitigated by Quickname)
- **Avatar URL Dependency**: If image hosting goes down, avatars break
- **No Profile Sync**: Quickname settings don't sync across user's devices
- **Upload Complexity**: Requires image upload infrastructure (S3)
- **Metadata Parsing Overhead**: Protobuf decompression/parsing on every conversation sync

### Mitigations

1. **Compression**: DEFLATE compression keeps metadata under 8KB for realistic conversation sizes
2. **Quickname**: Provides convenient profile reuse without server-side correlation
3. **Error Handling**: Clear error messages if metadata limit is exceeded
4. **Decompression Limits**: Protection against compression bombs
5. **Image Caching**: Three-tier cache minimizes network requests for avatars

### Privacy vs. Convenience Trade-offs

| Approach | Privacy | Convenience |
|----------|---------|-------------|
| **Per-conversation profiles (chosen)** | Complete isolation, no linkability | Must set profile per conversation (Quickname helps) |
| Global profile server | Profiles linked across all conversations | Set once, use everywhere |
| No profiles | Maximum anonymity | No personalization |
| Blockchain-based DIDs | Decentralized but linkable | Complex UX, gas fees |

### Security Model

| Threat | Mitigation |
|--------|------------|
| Cross-conversation correlation via profiles | Different profiles per conversation, different XMTP identities |
| Profile server compromise | No profile server exists |
| Avatar URL tracking | User controls reuse; hosting service doesn't know conversation context |
| Quickname leakage | Stored locally only; never transmitted |
| Metadata snooping | XMTP provides E2EE for group metadata |
| Decompression attacks | Size and ratio limits prevent resource exhaustion |

## Related Files

**Protobuf Schema:**
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/proto/conversation_custom_metadata.proto` - Profile protobuf definition

**Core Implementation:**
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift` - XMTP metadata interface
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/ConversationCustomMetadata+Serialization.swift` - Compression/encoding
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/ConversationCustomMetadata+Profiles.swift` - Profile management

**Database:**
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBMemberProfile.swift` - Profile database model
- `ConvosCore/Sources/ConvosCore/Storage/Models/Profile.swift` - Domain model

**Writers/Repositories:**
- `ConvosCore/Sources/ConvosCore/Storage/Writers/MyProfileWriter.swift` - Profile updates
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationWriter.swift` - Profile sync
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/MyProfileRepository.swift` - Profile queries

**Quickname:**
- `Convos/Profile/QuicknameSettings.swift` - Local profile storage
- `Convos/Profile/QuicknameSettingsViewModel.swift` - Quickname UI logic

**Image Handling:**
- `ConvosCore/Sources/ConvosCore/Image Cache/ImageCache.swift` - Three-tier caching
- `ConvosCore/Sources/ConvosCore/Utilities/Data+Compression.swift` - DEFLATE compression

**Tests:**
- `ConvosCore/Tests/ConvosCoreTests/ConversationCustomMetadataTests.swift` - Capacity and encoding tests

## Related ADRs

- ADR 001: Invite System (also uses conversation custom metadata for invite tags)
- ADR 002: Per-Conversation Identity Model (explains why each conversation has a separate XMTP inbox)
- ADR 004: Explode Feature (also uses conversation custom metadata for expiration timestamps)

## References

- XMTP Group Metadata: https://xmtp.org/docs/build/group-chat#group-metadata
- Protocol Buffers: https://protobuf.dev
- DEFLATE Compression: RFC 1951
- Base64URL Encoding: RFC 4648 Section 5
