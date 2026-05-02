# ADR 005: Member Profile System

> **Status**: Accepted (revised 2026-03; clarified against
> [ADR 011](./011-single-inbox-identity-model.md) on 2026-04-20;
> Quickname replaced by a global profile + activate-sync on 2026-05-02).
> **Supersedes**: Original ADR 005 (profile storage in appData)
>
> Profiles are **per-conversation on the wire** (one `DBMemberProfile` row
> per `(conversationId, inboxId)`), but locally the user now has a single
> **global profile** (`DBMyProfile`) that becomes the default for every new
> conversation and propagates into existing conversations the next time
> each one becomes active. The wire formats (`ProfileUpdate`,
> `ProfileSnapshot`, `JoinRequest`) and the resolution precedence below
> are unchanged by ADR 011 or by the global-profile change; ADR 011 made
> `inboxId` 1:1 with the user across every conversation, and the
> global-profile change moved the local profile preset out of UserDefaults
> and into a GRDB table that drives auto-application.

## Context

Convos historically used a per-conversation identity model (ADR 002,
superseded by ADR 011) where each conversation had its own XMTP inbox.
Per-conversation profiles were a natural fit and are retained under the
single-inbox model. The profile system must:

- Work without a centralized profile server
- Allow users to have different profiles per conversation
- Support optional profile sharing (users can remain anonymous)
- Work within XMTP's infrastructure constraints
- Provide good UX for users who want to reuse profiles

The original design stored profiles in the group's `appData` field as compressed protobuf. The biggest problem was that appData is not permissioned — any member could overwrite any other member's profile. This became especially problematic with agents, which could inadvertently clobber human profiles during concurrent metadata writes. Beyond that, the approach caused write contention (concurrent profile and tag updates clobbering each other), wasted bandwidth (changing one name rebroadcast every profile), and coupled profiles with unrelated metadata (invite tags, encryption keys). The system was migrated to dedicated XMTP messages in 2026-03.

## Decision

Member profiles are stored and transmitted as **XMTP group messages** using two custom content types. Locally, each user owns a single **global profile** that drives the default identity for new conversations and is propagated into existing conversations on next activation.

### 1. Profile Messages

Two custom XMTP content types carry profile data:

**ProfileUpdate** (`convos.org/profile_update` v1.0) — sent by a member when they change their own profile. The sender's inbox ID is implicit from the XMTP message envelope, preventing spoofing. Sending a ProfileUpdate with no fields set clears the profile.

**ProfileSnapshot** (`convos.org/profile_snapshot` v1.0) — sent after adding members to a group. Contains all current member profiles so new joiners have everyone's data immediately, solving the MLS forward secrecy gap where older messages (including prior ProfileUpdates) may be undecryptable.

Both are silent (`shouldPush = false`), use protobuf encoding, and are not displayed in chat.

**Protobuf Schema** (`ConvosCore/Sources/ConvosCore/Profiles/Proto/profile_messages.proto`):

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

### 7. Global Profile + Activate-Sync

Each user maintains a single **global profile** locally — display name, avatar, and metadata — that becomes the default for every new conversation. This solves the UX problem of repeatedly entering profile information without compromising privacy: the global profile never leaves the device, and other participants only ever see the per-conversation profile (`DBMemberProfile`) message that gets sent.

**Storage** (`DBMyProfile`, GRDB):

```swift
struct DBMyProfile {
    let inboxId: String              // Primary key
    let name: String?
    let imageData: Data?             // Raw avatar bytes (encrypted at rest)
    let imageAssetIdentifier: String?// PHAsset id, used to preselect picker
    let imageContentDigest: String?  // SHA-256 base64; the sync identity
    let metadata: ProfileMetadata?
    let updatedAt: Date
}
```

The image is held as raw bytes locally. `imageContentDigest` is a SHA-256 of the bytes — it is the canonical identity used to detect changes (the `imageAssetIdentifier` is photo-library-specific and only used to preselect the picker).

**Default for new conversations.** When a draft conversation is created, the global profile populates the placeholder identity in the composer. When the conversation reaches `.ready`, the per-conversation `DBMemberProfile` is created with the global name/avatar and the global digest is recorded as `imageSourceContentDigest`.

**Activate-sync for existing conversations.** Whenever a conversation transitions to `.ready` (`ConversationStateManager.scheduleProfileSync`), `MyProfileWriter.syncFromGlobalProfile` runs:

1. Compare `global.name` to `member.name`. If different, send a `ProfileUpdate` with the new name.
2. Compare `global.imageContentDigest` to `member.imageSourceContentDigest`. If they differ, re-upload the new avatar from the global bytes and stamp the new digest into the per-conversation row.
3. If the global avatar was cleared (`global.imageData == nil`) and the member still has an avatar, propagate the removal.

Per-conversation rows whose `imageSourceContentDigest` is `nil` are treated as **per-conversation overrides** (the user explicitly picked a different photo just for this conversation) and are not overwritten by activate-sync. Today the UI does not surface a per-conversation override — the field exists so the model can absorb the future "nickname / different photo per conversation" feature without a schema change.

**Serialization.** `ProfileSyncCoordinator` (an actor keyed by `conversationId`) chains rapid `.ready` transitions for the same conversation so two syncs cannot race and double-upload. Different conversations sync independently.

**Privacy model.** The global profile lives only in the local GRDB database and the in-memory cache. Other participants cannot detect that a profile was applied from a global preset versus typed in conversation by conversation — the wire format is the same `ProfileUpdate` either way.

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
- **Sync gap on reactivation**: Existing conversations only pick up a new global name/avatar the next time they become active, so the user may briefly see an older name/avatar from a peer's perspective until their next `.ready` transition propagates the change
- **Avatar URL dependency**: If image hosting goes down, avatars break
- **Dual-write overhead**: During Phase 2, both messages and appData are written (temporary)
- **Brief stale data on initial sync**: appData profiles may briefly show before message-sourced profiles are processed

### Privacy Model

| Property | Guarantee |
|----------|-----------|
| Cross-conversation linkability | Per-conversation profiles are independent rows, but the underlying `inboxId` is shared across conversations under ADR 011 — a peer in two of the user's conversations can correlate them via the inbox ID |
| Profile server correlation | No profile server exists |
| Global profile detection | The global profile is local-only (`DBMyProfile`); other participants only see the per-conversation `ProfileUpdate` and cannot tell whether it came from a global preset or was typed manually |
| Profile scope | Visible only to members of that conversation |
| Anonymity | Profiles are optional; users can participate without name/avatar |
| Message-level encryption | ProfileUpdate/ProfileSnapshot messages are E2E encrypted by XMTP |

## Related Files

### ConvosCore — Profiles module

> **Note (2026-04, single-inbox refactor C1)**: Profile code was folded from the standalone `ConvosProfiles` package into `ConvosCore` at `ConvosCore/Sources/ConvosCore/Profiles/`. The ConvosProfiles Swift package is removed. File names and contents are unchanged.

- `Profiles/Proto/profile_messages.proto` — protobuf schema
- `Profiles/Proto/profile_messages.pb.swift` — generated Swift types
- `Profiles/ProfileMessages/ProfileUpdateCodec.swift` — XMTP content codec for ProfileUpdate
- `Profiles/ProfileMessages/ProfileSnapshotCodec.swift` — XMTP content codec for ProfileSnapshot
- `Profiles/ProfileMessages/ProfileSnapshotBuilder.swift` — builds snapshots from message history
- `Profiles/ProfileMessages/ProfileMessageHelpers.swift` — MemberProfile init, metadata helpers, image ref conversion
- `Profiles/Crypto/ImageEncryption.swift` — AES-256-GCM avatar encryption
- `Profiles/Crypto/EncryptedImageLoader.swift` — encrypted image fetch + decrypt helper

### ConvosInvites package

- `ContentTypes/JoinRequestCodec.swift` — XMTP content codec for JoinRequest (carries joiner profile)

### ConvosAppData package

- `Proto/conversation_custom_metadata.pb.swift` — legacy appData protobuf (ConversationProfile, EncryptedImageRef)
- `AppDataSerialization.swift` — Base64URL encoding, DEFLATE compression for legacy appData
- `ProfileHelpers.swift` — legacy profile collection helpers

### ConvosCore

- `Storage/Database Models/DBMemberProfile.swift` — GRDB per-conversation profile model (carries `imageSourceContentDigest` for activate-sync)
- `Storage/Database Models/DBMyProfile.swift` — GRDB global profile model (raw image bytes, content digest, asset identifier)
- `Storage/Writers/MyProfileWriter.swift` — sends ProfileUpdate + best-effort appData write; `syncFromGlobalProfile` performs activate-sync
- `Storage/Writers/MyGlobalProfileWriter.swift` — writes the global profile to `DBMyProfile`, computes the SHA-256 content digest
- `Storage/Writers/ProfileSyncCoordinator.swift` — actor that serializes activate-sync per `conversationId`
- `Storage/Writers/ConversationStateManager.swift` — schedules activate-sync on `.ready`
- `Storage/Repositories/MyGlobalProfileRepository.swift` — observed read access to `DBMyProfile`
- `Storage/Writers/ConversationWriter.swift` — message-primary reads with gap-fill from appData
- `Storage/Writers/ConversationMetadataWriter.swift` — sends ProfileSnapshot after addMembers
- `Syncing/StreamProcessor.swift` — intercepts profile messages, writes to GRDB, sends initial snapshots
- `Syncing/InviteJoinRequestsManager.swift` — sends ProfileSnapshot after accepting join request
- `Inboxes/InboxStateMachine.swift` — registers profile codecs with XMTP client
- `Inboxes/MessagingService+PushNotifications.swift` — silent push handling for profile messages
- `Image Cache/ImageCache.swift` — three-tier image caching

### Main App

- `Profile/ProfileSettingsViewModel.swift` — global profile editor backed by `DBMyProfile`
- `Profile/MyProfileViewModel.swift` — per-conversation editor; `preferredImage(for:)` chooses the in-memory global vs the per-conversation cache to avoid avatar flicker between activate-sync passes

## Related ADRs

- ADR 001: Invite System (invite tags still stored in appData; profiles no
  longer compete for 8KB space)
- ADR 002: Per-Conversation Identity Model (superseded — historical
  context for why per-conversation profiles were introduced)
- ADR 004: Explode Feature (expiration timestamps in appData)
- ADR 009: Encrypted Conversation Images (AES-256-GCM encryption for profile avatars)
- ADR 011: Single-Inbox Identity Model (current identity model;
  per-conversation profile rows now share an inboxId across conversations
  but remain independent)
