# Removed-Member Handling & Profile Metadata Integrity

> **Status**: Draft
> **Branch**: `jarod/removed-member-plan`
> **Linear**: IOS-452, IOS-453, IOS-454, IOS-455

## Overview

A production incident (2026-06-04, "The Convosation") exposed a chain of four bugs
around group-member removal and paired-device state. This plan covers the fix stack.

Incident chain, confirmed across three devices' logs:

1. A paired iPad, dormant for ~19h (NSE-only) and freshly app-updated, launched with
   incomplete local state ("no profile") and rewrote the conversation's custom
   metadata from that state, shrinking the blob 1478 -> 1376 bytes and dropping the
   user's avatar fields. Other members saw the profile degrade.
2. The group creator, seeing a broken-looking member, manually removed the user's
   inbox. XMTP removal is inbox-level, so every paired device was kicked at once.
3. On the user's phone, removal handling is in-memory only
   (`ConversationsViewModel.hiddenConversationIds`): the pinned conversation vanished
   from the list, then reappeared after a force-quit as a zombie - history visible,
   sends failing with `GroupError::GroupInactive`, no new messages arriving.
4. Diagnosing this took three devices' logs partly because LeaveRequest and other
   unregistered content types are invisible: `dbRepresentation()` throws
   `unsupportedContentType` with no logging, so an entire class of inbound messages
   leaves no trace.

## Goals

- A user removed from a conversation sees consistent state across restarts: the
  conversation does not silently reappear as a dead zombie.
- Re-adding or rejoining (new welcome for the same group id) restores the
  conversation cleanly.
- A device can never destructively downgrade a member's profile entry in group
  custom metadata because its own local state is incomplete.
- Inbound messages with unregistered content types leave a log trace sufficient for
  forensics.

## Non-Goals

- "You were removed" banner / dedicated UI surface (follow-up; this stack only makes
  the data layer correct and keeps the existing hide behavior).
- Dormant paired-device lifecycle work (stale intent replay, NSE-only hydration,
  re-auth weirdness). Tracked separately.
- libxmtp changes (LeaveRequest visibility at the SDK level).

## PR Stack

```
dev
 └── removed-member-plan            # PR 1: this document
      └── unknown-content-logging    # PR 2: observability for unsupported content types
           └── persist-removed-state # PR 3: persist removal, filter lists, reset on re-add
                └── profile-metadata-merge # PR 4: merge-don't-clobber profile metadata
```

### PR 2 - Log unsupported content types (IOS-455)

`DecodedMessage.dbRepresentation()` throws `unsupportedContentType` for any codec the
app does not register (LeaveRequest, ProfileUpdate as messages, future types). Today
that throw is silent. Add a single log line carrying the content type id + authority
+ conversation id so unknown traffic is visible in exported logs. No behavior change.

### PR 3 - Persist removed-from-conversation state (IOS-453)

- New `wasRemoved` boolean on `ConversationLocalState` (survives conversation
  re-saves; `insert(onConflict: .ignore)` already protects local state).
- Set idempotently in `IncomingMessageWriter.persist` when `removedInboxIds` contains
  the local inbox - independent of `messageAlreadyExists`, so it also works when the
  NSE saved the removal message first.
- Filter `wasRemoved` conversations out of `ConversationsRepository` list queries and
  the count repositories, matching what the in-memory hide already intends.
- Reset the flag in `ConversationWriter.persist` when a conversation syncs again (a
  new welcome implies membership), covering re-add and rejoin-via-invite.
- Keep `leftConversationNotification` + `hiddenConversationIds` as the live-UX fast
  path; broaden the notification gate so it also fires when the message row already
  existed.

### PR 4 - Profile metadata merge-don't-clobber (IOS-452)

`Group.updateProfile(_:)` currently replaces the member's whole `ConversationProfile`
entry with one built from the local `DBMemberProfile`; an avatar-less local row drops
`encryptedImage`/`image`/`connections` from the group metadata.

- Add a merge helper in ConvosAppData: incoming profile wins for `name`; existing
  remote values are preserved when the incoming side is empty
  (`encryptedImage`, legacy `image`, `connections`).
- `updateProfile` uses merge semantics; its `verify` closure checks the merged
  invariant instead of exact equality.
- Explicit avatar removal moves to a dedicated clearing API so removals remain
  possible but can never happen as a side effect of empty local state.
- Guard `MyProfileWriter.syncFromGlobalProfile` so a freshly-rehydrated device
  (no synced avatar, no content digest) does not propagate an avatar "removal" it
  never observed.

### Follow-up (IOS-454, not in this stack)

Dormant paired-device lifecycle: epoch-stale queued intents replayed hours later,
app-DB hydration when the NSE has been the only process running, and backend re-auth
("Subscription belongs to a different account") after updates.

## Risks

- The `wasRemoved` reset runs on every conversation persist; it must only flip the
  flag when a sync actually implies membership. Covered by tests (set, idempotent
  re-set, reset-on-welcome).
- Merge semantics change what `updateProfile` writes; the explicit-removal paths get
  a dedicated API and tests so avatar removal still propagates.
- Migration is append-only per `SharedDatabaseMigrator` conventions; default `false`
  preserves legacy visibility.

## Test Plan

- ConvosCore: new `IncomingMessageWriterRemovalTests` (set / idempotent / NSE-first),
  repository filter tests, reset-on-persist test.
- ConvosAppData: new `ProfileMergeTests` including a byte-size regression test
  (merging an avatar-less local profile never shrinks the encoded metadata).
- Full `swift test --package-path ConvosCore` against local Docker XMTP node before
  every push.
