# ADR 005: Member Profile System

> **Status**: Accepted (revised 2026-03)
> **Supersedes**: Original ADR 005 (profile storage in appData)

## Context

Convos uses a per-conversation identity model where each conversation has its own XMTP inbox (see ADR 002). To support user profiles (display names and avatars) in this model, we need a solution that:

- Works without a centralized profile server
- Maintains privacy isolation between conversations
- Allows users to have different profiles per conversation
- Supports optional profile sharing (users can remain anonymous)
- Works within XMTP's infrastructure constraints
- Provides good UX for users who want to reuse profiles

The original design stored profiles in the group's `appData` field as compressed protobuf. The biggest problem was that appData is not permissioned — any member could overwrite any other member's profile. This became especially problematic with agents, which could inadvertently clobber human profiles during concurrent metadata writes. Beyond that, the approach caused write contention (concurrent profile and tag updates clobbering each other), wasted bandwidth (changing one name rebroadcast every profile), and coupled profiles with unrelated metadata (invite tags, encryption keys). The system was migrated to dedicated XMTP messages in 2026-03.

## Decision

Member profiles are stored and transmitted as **XMTP group messages** using two custom content types. A complementary **Quickname** feature provides local-only profile presets for convenient reuse across conversations.

### 1. Profile Messages

Two custom XMTP content types carry profile data:

**ProfileUpdate** (`convos.org/profile_update` v1.0) — sent by a member when they change their own profile. The sender's inbox ID is implicit from the XMTP message envelope, preventing spoofing. Sending a ProfileUpdate with no fields set clears the profile.

**ProfileSnapshot** (`convos.org/profile_snapshot` v1.0) — sent after adding members to a group. Contains all current member profiles so new joiners have everyone's data immediately, solving the MLS forward secrecy gap where older messages (including prior ProfileUpdates) may be undecryptable.

Both are silent (`shouldPush = false`), use protobuf encoding, and are not displayed in chat.

**Protobuf Schema** (`ConvosProfiles/Proto/profile_messages.proto`):

```protobuf
enum MemberKind {
    MEMBER_KIND_UNSPECIFIED = 0;
    MEMBER_KIND_AGENT = 1;
}

message MetadataValue {
    oneof value {
        string string_value = 1;
        double number_value = 2;
        bool bool_value = 3;
    }
}

message ProfileUpdate {
    optional string name = 1;
    optional EncryptedProfileImageRef encrypted_image = 2;
    MemberKind member_kind = 3;
    map<string, MetadataValue> metadata = 4;
}

message ProfileSnapshot {
    repeated MemberProfile profiles = 1;
}

message MemberProfile {
    bytes inbox_id = 1;  // hex-decoded bytes (32 bytes)
    optional string name = 2;
    optional EncryptedProfileImageRef encrypted_image = 3;
    MemberKind member_kind = 4;
    map<string, MetadataValue> metadata = 5;
}

message EncryptedProfileImageRef {
    string url = 1;   // URL to encrypted ciphertext
    bytes salt = 2;   // 32-byte HKDF salt
    bytes nonce = 3;  // 12-byte AES-GCM nonce
}
```

**Key Design Decisions:**

1. **Self-authored updates**: Only the member can send their own ProfileUpdate. The sender's inbox ID comes from the XMTP message, not the payload, preventing impersonation.
2. **Encrypted avatar references**: Images are encrypted with AES-256-GCM (see ADR 009). Only the `{url, salt, nonce}` tuple is stored in the message; the encryption key lives in the group's encrypted metadata.
3. **MemberKind enum**: Identifies agents vs regular members. Defaults to `UNSPECIFIED` for backward compatibility.
4. **Typed metadata**: Arbitrary key-value pairs with string, number (double), and boolean values. Carried in both ProfileUpdate and ProfileSnapshot.

### 2. Profile Resolution Precedence

When building the current profile for a member:

1. **Latest ProfileUpdate from that member** — highest priority, self-authored
2. **Most recent ProfileSnapshot containing that member** — fallback when no individual update exists
3. **appData profiles** — legacy fallback for backward compatibility with older clients
4. **No profile** — member has no name/avatar set

`ProfileSnapshotBuilder` scans up to 500 messages (descending) to resolve profiles for all current members, using this precedence.

### 3. When Snapshots Are Sent

ProfileSnapshots are sent at three points:

- **Group creation**: `StreamProcessor` sends a snapshot after discovering a new group, ensuring the creator's profile is available to future joiners.
- **Member added directly**: `ConversationMetadataWriter` sends a snapshot after `addMembers`, giving the new member all existing profiles.
- **Invite accepted**: `InviteJoinRequestsManager` sends a snapshot after processing a join request.

### 4. Profile Write Flow

```
User changes name/avatar in UI
    ↓
MyProfileWriter
    ↓
1. Upload encrypted avatar to S3 (if changed)
2. Save to GRDB (local DB)
3. Send ProfileUpdate message to group
4. Write to appData (best-effort, for backward compat)
    ↓
Other members receive ProfileUpdate via stream
    ↓
StreamProcessor.processProfileUpdate
    ↓
Upsert DBMemberProfile in GRDB
    ↓
UI observes GRDB changes
```

The appData write is best-effort — failures are logged but don't block the update. This maintains backward compatibility with older clients that still read from appData.

### 5. Profile Read Flow (Message-Primary)

`ConversationWriter` uses gap-fill semantics when syncing conversations:

- For each member, check if GRDB already has a profile with name or avatar data (from a ProfileUpdate or ProfileSnapshot message).
- If yes, skip — message-sourced data takes precedence.
- If no, fill the gap from appData profiles (legacy fallback).
- Remove profiles for members no longer in the group.

On initial sync, `ConversationWriter` also scans message history for ProfileUpdate and ProfileSnapshot messages to populate profiles for members who sent updates before the current client joined.

### 6. Per-Conversation Profiles

Each user can have a different profile in each conversation, enforced by the database schema.

**Database Model:**

```swift
struct DBMemberProfile {
    let conversationId: String    // Composite primary key
    let inboxId: String           // Composite primary key
    let name: String?
    let avatar: String?           // Encrypted image URL
    let avatarSalt: Data?         // 32-byte HKDF salt
    let avatarNonce: Data?        // 12-byte AES-GCM nonce
    let avatarKey: Data?          // Group encryption key (local only)
    let avatarLastRenewed: Date?
    let memberKind: DBMemberKind? // .agent or nil
    let metadata: ProfileMetadata? // [String: ProfileMetadataValue]
}
```

The `avatarKey` is populated from the conversation's `imageEncryptionKey` during profile writes — it's never transmitted in ProfileUpdate or ProfileSnapshot messages.

### 7. Quickname: Local Profile Presets

Quickname solves the UX problem of repeatedly entering profile information without compromising privacy.

1. User creates a Quickname profile locally (display name + optional avatar)
2. When joining/creating a new conversation, the app prompts: "Tap to chat as [Quickname]"
3. If accepted, the Quickname profile is copied to the new conversation's per-conversation profile
4. User can modify the per-conversation profile independently afterward

**Storage**: Quickname data is stored locally only (UserDefaults + filesystem) and never transmitted. Other participants cannot detect whether a profile was applied via Quickname or entered manually.

### 8. Profile Photo Storage

Profile photos use AES-256-GCM encryption (see ADR 009):

1. **Resize and compress**: Image resized and compressed to JPEG
2. **Encrypt**: AES-256-GCM with key derived from group `imageEncryptionKey` + per-image salt via HKDF
3. **Upload**: Encrypted ciphertext uploaded to S3
4. **Store reference**: `{url, salt, nonce}` stored in the ProfileUpdate message

Images are cached using a three-tier system (memory → disk → network) with SHA256-based filenames for deduplication.

### 9. Typed Metadata

Profiles carry arbitrary key-value metadata via `map<string, MetadataValue>`:

```swift
public enum ProfileMetadataValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

public typealias ProfileMetadata = [String: ProfileMetadataValue]
```

Metadata is stored as JSON in the `memberProfile` database table. It round-trips through ProfileUpdate and ProfileSnapshot messages. Use cases include agent credits, user preferences, and extensible profile fields without schema changes.

### 10. Join Request Content Type

A related content type carries profile data during the invite flow:

**JoinRequest** (`convos.org/join_request` v1.0) — sent as a DM to the conversation creator when joining via invite. Contains the invite slug (required), joiner's profile (optional: name, image URL, member kind), and extensible metadata (optional string map). Uses JSON encoding. The codec's `fallback` returns the invite slug as plain text for backward compatibility with older clients.

### 11. Push Notification Handling

Profile messages received via push notifications are processed silently in the Notification Service Extension. `MessagingService` intercepts ProfileUpdate and ProfileSnapshot content types, updates GRDB, and returns `droppedMessage` to suppress user notifications.

### 12. Migration Strategy

- **Phase 1 (complete)**: Dual-write — ProfileUpdate messages sent alongside appData writes
- **Phase 2 (complete)**: Message-primary reads — GRDB profiles are no longer overwritten from appData on sync; gap-fill only for members without message-sourced data
- **Phase 3 (future)**: Stop appData writes entirely after forced update or sufficient adoption

## Consequences

### Positive

- **No write contention**: Profile updates are independent messages, not read-modify-write on shared appData
- **No size ceiling**: Messages are not constrained by the 8KB appData limit
- **Efficient updates**: Changing one name sends one small message, not every profile
- **Decoupled from metadata**: Profile bugs cannot corrupt invite tags or encryption keys
- **No profile server**: Entirely serverless, handled by XMTP infrastructure
- **Complete privacy isolation**: Profiles in different conversations cannot be linked
- **Forward secrecy solved**: ProfileSnapshots give new joiners immediate access to all profiles
- **Agent identification**: MemberKind enum enables agent-specific UI
- **Extensible**: Typed metadata allows arbitrary key-value data without schema changes

### Negative

- **Message scan on snapshot build**: Building a snapshot scans up to 500 messages (bounded)
- **No global identity**: Users must set up profiles per-conversation (mitigated by Quickname)
- **Avatar URL dependency**: If image hosting goes down, avatars break
- **Dual-write overhead**: During Phase 2, both messages and appData are written (temporary)
- **Brief stale data on initial sync**: appData profiles may briefly show before message-sourced profiles are processed

### Privacy Model

| Property | Guarantee |
|----------|-----------|
| Cross-conversation linkability | Different XMTP identities per conversation (ADR 002) |
| Profile server correlation | No profile server exists |
| Quickname detection | Local-only; other participants cannot detect reuse |
| Profile scope | Visible only to members of that conversation |
| Anonymity | Profiles are optional; users can participate without name/avatar |
| Message-level encryption | ProfileUpdate/ProfileSnapshot messages are E2E encrypted by XMTP |

## Related Files

### ConvosProfiles package

- `Proto/profile_messages.proto` — protobuf schema
- `Proto/profile_messages.pb.swift` — generated Swift types
- `ProfileMessages/ProfileUpdateCodec.swift` — XMTP content codec for ProfileUpdate
- `ProfileMessages/ProfileSnapshotCodec.swift` — XMTP content codec for ProfileSnapshot
- `ProfileMessages/ProfileSnapshotBuilder.swift` — builds snapshots from message history
- `ProfileMessages/ProfileMessageHelpers.swift` — MemberProfile init, metadata helpers, image ref conversion

### ConvosInvites package

- `ContentTypes/JoinRequestCodec.swift` — XMTP content codec for JoinRequest (carries joiner profile)

### ConvosAppData package

- `Proto/conversation_custom_metadata.pb.swift` — legacy appData protobuf (ConversationProfile, EncryptedImageRef)
- `AppDataSerialization.swift` — Base64URL encoding, DEFLATE compression for legacy appData
- `ProfileHelpers.swift` — legacy profile collection helpers

### ConvosCore

- `Storage/Database Models/DBMemberProfile.swift` — GRDB profile model with metadata
- `Storage/Writers/MyProfileWriter.swift` — sends ProfileUpdate + best-effort appData write
- `Storage/Writers/ConversationWriter.swift` — message-primary reads with gap-fill from appData
- `Storage/Writers/ConversationMetadataWriter.swift` — sends ProfileSnapshot after addMembers
- `Syncing/StreamProcessor.swift` — intercepts profile messages, writes to GRDB, sends initial snapshots
- `Syncing/InviteJoinRequestsManager.swift` — sends ProfileSnapshot after accepting join request
- `Inboxes/InboxStateMachine.swift` — registers profile codecs with XMTP client
- `Inboxes/MessagingService+PushNotifications.swift` — silent push handling for profile messages
- `Image Cache/ImageCache.swift` — three-tier image caching

### Main App

- `Profile/QuicknameSettings.swift` — local Quickname storage
- `Profile/QuicknameSettingsViewModel.swift` — Quickname UI logic

## Related ADRs

- ADR 001: Invite System (invite tags still stored in appData; profiles no longer compete for 8KB space)
- ADR 002: Per-Conversation Identity Model (each conversation has a separate XMTP inbox)
- ADR 004: Explode Feature (expiration timestamps in appData)
- ADR 009: Encrypted Conversation Images (AES-256-GCM encryption for profile avatars)
