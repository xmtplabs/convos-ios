# Profile Messages Phase 2: Message-Primary Reads

## Context

Phase 1 (current state) dual-writes: `MyProfileWriter` sends both a `ProfileUpdate` message and updates appData. `StreamProcessor` processes incoming `ProfileUpdate` and `ProfileSnapshot` messages into GRDB. But `ConversationWriter._store()` still reads profiles from appData on every sync, deletes all GRDB profile rows, and re-creates them from appData. This means message-written profiles are ephemeral — they survive only until the next `_store` call.

Phase 2 makes messages the primary source of profile data. appData continues to receive profile writes for backward compatibility with older clients, but GRDB profiles are no longer overwritten from appData on sync.

## Problem

`ConversationWriter.saveConversationToDatabase` does this on every sync:

```swift
// Delete old members
try DBMemberProfile
    .filter(DBMemberProfile.Columns.conversationId == dbConversation.id)
    .deleteAll(db)
// Save members
try self.saveMembers(dbMembers, in: db)
// Update profiles from appData
try memberProfiles.forEach { profile in
    try profile.save(db)
}
```

This wipes all message-sourced profiles and replaces them with appData. There are three call sites:

1. **`StreamProcessor.processConversation`** — initial sync or conversation discovery
2. **`StreamProcessor.processMessage`** — called on every incoming message via `conversationWriter.store`
3. **`MessagingService+PushNotifications`** — push notification handling

## Changes

### 1. Stop deleting profiles in `saveConversationToDatabase`

Remove the delete-all-and-rewrite pattern. Instead, merge appData profiles into existing GRDB profiles using "fill gaps" semantics — only write appData profile data for members that don't already have message-sourced profiles.

```swift
// Before (Phase 1):
try DBMemberProfile
    .filter(DBMemberProfile.Columns.conversationId == dbConversation.id)
    .deleteAll(db)
try memberProfiles.forEach { profile in
    try profile.save(db)
}

// After (Phase 2):
try memberProfiles.forEach { profile in
    let existing = try DBMemberProfile.fetchOne(
        db,
        conversationId: dbConversation.id,
        inboxId: profile.inboxId
    )
    if existing?.name != nil || existing?.avatar != nil {
        // Already have message-sourced profile data, skip appData
        return
    }
    let member = DBMember(inboxId: profile.inboxId)
    try member.save(db)
    try profile.save(db)
}
```

This matches the same "fill gaps" semantics used in `processProfileSnapshot`.

### 2. Handle member removal

The current delete-all serves a second purpose: cleaning up profiles for removed members. Without it, profiles for members who left the group would linger.

Replace with targeted deletion — remove profiles for members no longer in the group:

```swift
let currentMemberInboxIds = Set(dbMembers.map(\.inboxId))
try DBMemberProfile
    .filter(DBMemberProfile.Columns.conversationId == dbConversation.id)
    .filter(!currentMemberInboxIds.contains(DBMemberProfile.Columns.inboxId))
    .deleteAll(db)
```

### 3. `_store` no longer needs to read appData profiles

Currently `_store` calls `conversation.memberProfiles` which decodes the full appData blob to extract profiles. In Phase 2, this becomes optional — we only need appData profiles as a fallback for members without message-sourced data. The read still happens (for gap-filling), but it's no longer the primary source.

In Phase 3, this read goes away entirely.

### 4. `processProfileUpdate` should overwrite unconditionally

The current `processProfileUpdate` already does an unconditional overwrite (upsert), which is correct — a `ProfileUpdate` from a member always takes precedence over any previous data, whether from appData or a snapshot.

No change needed here.

### 5. `processProfileSnapshot` "fill gaps" logic stays

The current logic skips members that already have name or avatar data. This is correct for Phase 2 — a snapshot should never regress a member's profile to older data.

No change needed here.

### 6. Missing encryption key on message-sourced profiles

`XMTPGroup.memberProfiles(withKey:)` reads the `imageEncryptionKey` from appData metadata and attaches it to each profile as `avatarKey`. Message-sourced profiles don't have this key because `ProfileUpdate` and `ProfileSnapshot` don't carry the group encryption key (intentionally — it would be redundant and a security concern to broadcast it in every message).

Currently, `processProfileUpdate` does `profile.with(key: profile.avatarKey)` — preserving any existing key. But for a new profile (no existing row), `avatarKey` is nil. This means encrypted avatars from message-sourced profiles can't be decrypted inline by the image cache.

The `EncryptedImagePrefetcher` receives `groupKey` as a separate parameter (not from `avatarKey`), so prefetch-based decryption works fine. But `ImageCache.fetchEncryptedImageInline` reads `encryptionKey` from the `Profile` (which comes from `avatarKey`) for cold-start scenarios where the prefetcher hasn't run.

**Fix: Populate on write.** When `processProfileUpdate` / `processProfileSnapshot` save a profile with an encrypted image, look up the conversation's `imageEncryptionKey` from GRDB within the same write transaction:

```swift
// In processProfileUpdate, inside the databaseWriter.write block:
if update.hasEncryptedImage, update.encryptedImage.isValid {
    let conversation = try DBConversation.fetchOne(db, id: conversationId)
    profile = profile.with(
        avatar: update.encryptedImage.url,
        salt: update.encryptedImage.salt,
        nonce: update.encryptedImage.nonce,
        key: conversation?.imageEncryptionKey
    )
}
```

This is one extra GRDB read per profile write, but profile updates are infrequent and the read is within the same write transaction (no extra I/O boundary).

### 7. Profile updates during initial sync

When a user opens a conversation for the first time (or reinstalls), `processConversation` calls `storeWithLatestMessages`. The current flow:

1. Sync group
2. Read appData profiles → save to GRDB
3. Fetch latest messages → which include `ProfileUpdate`/`ProfileSnapshot`
4. Each message triggers `processProfileMessage` → writes to GRDB

In Phase 2, step 2 becomes "fill gaps" instead of "overwrite". But there's a timing consideration: step 2 happens before step 3. If we only fill gaps, and the appData profiles are stale (member updated their name since the appData was last written), we'd persist stale data that then gets overwritten in step 3.

This is acceptable because:
- The stale data is only visible momentarily (until the `ProfileUpdate` message is processed)
- The `ProfileUpdate` processing overwrites unconditionally
- The user sees a brief flash of old data at worst

For a better experience, we could reverse the order (process messages first, then fill gaps from appData), but that requires restructuring `_store` significantly. Not worth it for Phase 2.

## Ordering of Changes

1. Add encryption key population to `processProfileUpdate` and `processProfileSnapshot`
2. Replace delete-all with targeted member cleanup in `saveConversationToDatabase`
3. Replace unconditional profile save with gap-filling logic
4. Remove `memberProfiles` read from `_store` (optional — can keep for gap-filling)

## Testing

### Unit Tests

- Profile from `ProfileUpdate` survives a `_store` call (previously would be deleted)
- Profile from `ProfileSnapshot` survives a `_store` call
- appData profile fills gaps for members without message-sourced profiles
- Removed members' profiles are cleaned up
- Encryption key is populated when saving message-sourced profiles with encrypted images

### Integration Tests

- Full flow: member A updates profile via message → `_store` called → profile still correct
- Snapshot sent after add → new member sees profiles after initial sync
- appData fallback: member with only appData profile (old client) still has profile after sync

## Risk Assessment

**Low risk:**
- Profile display is read from GRDB regardless of source — no UI changes
- appData writes continue (backward compatibility)
- Gap-filling is the same pattern already used in `processProfileSnapshot`

**Medium risk:**
- Encryption key population (Option B) adds a database read per profile write. Acceptable given profile updates are infrequent.
- Brief flash of stale appData profiles on initial sync (acceptable)

**Not a risk:**
- Old clients that only write to appData will still have their profiles picked up via gap-filling
- New clients that only read messages will get profiles from `ProfileUpdate`/`ProfileSnapshot`
