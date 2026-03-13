# Profile Messages: Moving Profiles Out of appData

## Problem

Member profiles (name, encrypted avatar) are currently stored in the XMTP group's `appData` field as part of the `ConversationCustomMetadata` protobuf. This causes several problems:

1. **Size limit** — `appData` is capped at 8KB. Every member's profile competes for space with the invite tag, encryption keys, expiration, and the group image. Large groups will hit this ceiling.

2. **Write contention** — Every profile update requires a read-modify-write of the entire `appData` blob. Concurrent updates (profile change + tag rotation, two members updating profiles simultaneously) can clobber each other. We patched this with `atomicUpdateMetadata` retries, but the fundamental problem remains.

3. **Bandwidth** — Every profile change rebroadcasts the entire metadata blob (all profiles, tag, keys) to all members as a group commit.

4. **Coupling** — Unrelated concerns (profiles, invite tags, encryption keys, expiration) share one mutable blob. A bug in any write path can corrupt all of them.

## Solution

Replace appData profile storage with two new XMTP custom content types sent as group messages:

### Content Types

**`ProfileUpdate`** — Sent by a member when they change their own profile.

```
authority: convos.org
typeId: profile_update
```

Contains a single profile: the sender's updated name and/or encrypted avatar reference. Only the sender can author their own profile update — the sender inbox ID is implicit from the XMTP message.

**`ProfileSnapshot`** — Sent by the member who adds a new member to the group.

```
authority: convos.org
typeId: profile_snapshot
```

Contains a map of all current member profiles. Sent immediately after adding a member so the new joiner has everyone's profiles without needing to scan message history.

### Why Two Content Types

`ProfileUpdate` handles the steady-state: members changing their own names/avatars. It's lightweight (single profile) and conflict-free (each member owns their own).

`ProfileSnapshot` solves the forward secrecy problem. XMTP uses MLS — older messages become undecryptable after key rotations. A member who joined recently can't read a `ProfileUpdate` sent months ago. The snapshot provides a durable checkpoint authored by the adder, who is online and has current key material.

### Profile Resolution Order

When building the current profile for a member:

1. **Latest `ProfileUpdate` from that member** — highest priority, most recent self-authored update
2. **Most recent `ProfileSnapshot` containing that member** — fallback when no `ProfileUpdate` exists (e.g., new joiner who hasn't updated their profile yet, or `ProfileUpdate` lost to forward secrecy)
3. **No profile** — member has no name/avatar set

This means snapshot preparation must follow the same precedence: the adder scans for the latest `ProfileUpdate` per member first, falls back to the most recent `ProfileSnapshot` for any members without a `ProfileUpdate`, then bundles everything into the new snapshot.

## Detailed Design

### ProfileUpdate Content Type

```swift
struct ProfileUpdateContent: Codable, Sendable {
    let name: String?
    let encryptedImage: EncryptedImageRefContent?
}

struct EncryptedImageRefContent: Codable, Sendable {
    let url: String
    let salt: Data  // 32-byte HKDF salt
    let nonce: Data // 12-byte AES-GCM nonce
}
```

The sender's inbox ID comes from the XMTP message itself — no need to include it in the payload. This prevents spoofing: you can only update your own profile.

Sending a `ProfileUpdate` with `name: nil` and `encryptedImage: nil` clears the profile.

### ProfileSnapshot Content Type

```swift
struct ProfileSnapshotContent: Codable, Sendable {
    let profiles: [MemberProfileEntry]
}

struct MemberProfileEntry: Codable, Sendable {
    let inboxId: String
    let name: String?
    let encryptedImage: EncryptedImageRefContent?
}
```

The snapshot explicitly includes inbox IDs since it contains other members' profiles.

### When Snapshots Are Sent

A `ProfileSnapshot` is sent immediately after adding members in these flows:

1. **`ConversationMetadataWriter.addMembers`** — manual member addition
2. **`InviteCoordinator.processJoinRequest`** — invite-based join (after `group.addMembers`)
3. **Group creation** — creator sends a snapshot with their own profile

### Snapshot Preparation

The adder builds the snapshot by:

1. Syncing the group to ensure latest message state
2. Scanning recent group messages for `ProfileUpdate` messages — collecting the latest per inbox ID
3. For any member without a `ProfileUpdate`, checking the most recent `ProfileSnapshot` message for that member's entry
4. Bundling all resolved profiles into the new `ProfileSnapshot`

This scan is bounded — we only need to find one `ProfileUpdate` per member and one fallback `ProfileSnapshot`. In practice, pagination with a reasonable limit (e.g., last 500 messages) should suffice. Members whose profiles can't be resolved simply have empty entries.

### Processing ProfileUpdate Messages

When `StreamProcessor.processMessage` receives a `ProfileUpdate`:

1. Extract the sender's inbox ID from the message
2. Decode the `ProfileUpdateContent`
3. Write to `DBMemberProfile` in GRDB (upsert by conversationId + inboxId)
4. The message is not displayed in chat (filtered like `ExplodeSettings`)

### Processing ProfileSnapshot Messages

When `StreamProcessor.processMessage` receives a `ProfileSnapshot`:

1. Decode the `ProfileSnapshotContent`
2. For each profile entry, check if we already have a newer `ProfileUpdate` from that member in GRDB (compare message timestamps or just check if a `ProfileUpdate` has been processed)
3. Write any missing/older profiles to `DBMemberProfile`
4. Not displayed in chat

### Writing Profile Updates (MyProfileWriter)

Current flow:
1. Update `DBMemberProfile` in GRDB
2. Call `group.updateProfile()` which does read-modify-write on appData

New flow:
1. Update `DBMemberProfile` in GRDB
2. Send a `ProfileUpdate` message to the group
3. (Migration period) Also write to appData for backward compatibility

### Reading Profiles (ConversationWriter)

Current flow:
1. `ConversationWriter._store()` calls `conversation.memberProfiles` which reads from appData
2. Saves all profiles to GRDB, overwriting existing data

New flow:
1. `ConversationWriter._store()` no longer reads profiles from appData
2. Profiles come exclusively from processing `ProfileUpdate` and `ProfileSnapshot` messages
3. On initial sync / conversation discovery, the snapshot sent when we were added provides our baseline

### appData After Migration

With profiles removed, `ConversationCustomMetadata` becomes:

```protobuf
message ConversationCustomMetadata {
    string tag = 1;
    // field 2 (profiles) removed
    optional sfixed64 expiresAtUnix = 3;
    optional bytes imageEncryptionKey = 4;
    optional EncryptedImageRef encryptedGroupImage = 5;
}
```

This is a small, rarely-written blob — only changing on tag rotation, expiration changes, key generation, or group image updates. The contention and size problems disappear.

## Migration Strategy

### Phase 1: Dual-Write (This PR)

- Add `ProfileUpdate` and `ProfileSnapshot` codecs
- `MyProfileWriter` sends `ProfileUpdate` messages AND writes to appData
- `StreamProcessor` processes incoming `ProfileUpdate` and `ProfileSnapshot` messages
- `ConversationWriter._store()` still reads profiles from appData as fallback
- Member addition flows send `ProfileSnapshot` after adding
- All clients can read both sources; new profiles propagate via messages

### Phase 2: Message-Primary (Future)

- `ConversationWriter._store()` stops reading profiles from appData
- Profiles come exclusively from messages
- appData profile writes continue for backward compatibility with older clients

### Phase 3: Remove appData Profiles (Future)

- Stop writing profiles to appData
- Remove `profiles` field handling from `ConversationCustomMetadata`
- Clean migration complete

## Package Structure

The profile content types, codecs, and snapshot logic live in the **`ConvosProfiles`** package — not in `ConvosCore`. This makes the profile system reusable by anyone building on XMTP, not just Convos.

`ConvosProfiles` already depends on `ConvosAppData` (shared protobuf types) and `XMTPiOS`. It currently contains image encryption utilities (`ImageEncryption`, `EncryptedImageLoader`). The new profile message types are a natural extension.

### What goes in ConvosProfiles

- `ProfileUpdateCodec` — content codec for `ProfileUpdate`
- `ProfileSnapshotCodec` — content codec for `ProfileSnapshot`
- `ProfileSnapshotBuilder` — scans group messages, resolves profiles per the precedence rules, builds snapshots
- Profile content models (`ProfileUpdateContent`, `ProfileSnapshotContent`, `MemberProfileEntry`)
- Protobuf definitions for the message payloads

### What stays in ConvosCore

- `MyProfileWriter` — orchestrates profile updates (writes to GRDB, calls into `ConvosProfiles` to send the message)
- `StreamProcessor` — routes incoming `ProfileUpdate`/`ProfileSnapshot` messages to GRDB writes
- `ConversationWriter` — stops reading profiles from appData (Phase 2)
- `ConversationMetadataWriter` — calls `ProfileSnapshotBuilder` after `addMembers`

### What stays in ConvosCore (bridge to ConvosProfiles)

- `InviteJoinRequestsManager` — after accepting a join request, uses `ProfileSnapshotBuilder` to send a snapshot

## Impact on Existing Code

### Files Modified

| File | Package | Change |
|------|---------|--------|
| `MyProfileWriter.swift` | ConvosCore | Send `ProfileUpdate` message instead of (or in addition to) appData write |
| `StreamProcessor.swift` | ConvosCore | Handle `ProfileUpdate` and `ProfileSnapshot` message types |
| `ConversationWriter.swift` | ConvosCore | Stop reading profiles from appData (Phase 2) |
| `ConversationMetadataWriter.swift` | ConvosCore | Send `ProfileSnapshot` after `addMembers` |
| `InviteCoordinator.swift` / `InviteJoinRequestsManager.swift` | ConvosCore/ConvosInvites | Send `ProfileSnapshot` after accepting join request |
| `XMTPGroup+CustomMetadata.swift` | ConvosCore | Remove `updateProfile` and `memberProfiles` (Phase 3) |
| `ConvosProfiles.swift` | ConvosProfiles | Update module docs to reflect new message-based approach |

### New Files

| File | Package | Purpose |
|------|---------|---------|
| `ProfileUpdateCodec.swift` | ConvosProfiles | Content codec for `ProfileUpdate` |
| `ProfileSnapshotCodec.swift` | ConvosProfiles | Content codec for `ProfileSnapshot` |
| `ProfileSnapshotBuilder.swift` | ConvosProfiles | Scan messages, resolve profiles, build snapshots |
| `ProfileModels.swift` | ConvosProfiles | Content models for profile messages |

### No Changes Needed

- `DBMemberProfile` — schema stays the same, just the write source changes
- UI layer — reads from GRDB, unaffected by where the data comes from
- `EncryptedImagePrefetcher` — still works on `DBMemberProfile` data
- Image encryption — `imageEncryptionKey` stays in appData

## Message Size

XMTP's gRPC payload limit is **25MB** (`GRPC_PAYLOAD_LIMIT` in libxmtp). The max group size in XMTP is 250 members; Convos caps at 150.

Per-member profile in protobuf is approximately **~308 bytes** (64-byte inbox ID hex string, ~50-byte name, ~120-byte encrypted image URL, 32-byte salt, 12-byte nonce, ~30 bytes protobuf overhead).

| Members | Snapshot Size | Headroom vs 25MB |
|---------|--------------|------------------|
| 150     | ~45 KB       | 567x             |
| 250     | ~75 KB       | 340x             |

Snapshot size is not a concern — even at max group size, a `ProfileSnapshot` is well under 100KB. Using protobuf encoding keeps it compact. No need for splitting, pagination, or remote attachment patterns.

## Open Questions

1. **Race between add and snapshot** — If the adder's snapshot send fails after successfully adding the member, the new joiner has no profiles. Mitigation: joiner can request a snapshot, or any member could respond to a "missing profiles" signal.

2. **Profile update rate limiting** — Should we debounce rapid profile updates (e.g., user typing in name field) to avoid message spam?

3. **Codec registration** — Both codecs need to be registered on the XMTP client. Need to add them to the client initialization in `TestHelpers`, `MessagingService`, and `NotificationService`.
