# Stale Device Detection (Post-Revocation UX)

> **Status**: Draft
> **Author**: Louis
> **Created**: 2026-04-07
> **Updated**: 2026-04-07

## Problem

When a user restores their account on device B, device B revokes all other installations (device A's installations) for every restored conversation inbox (and, with the vault re-creation fix, for the vault too). This happens silently from device A's perspective — device A is not notified.

Device A's current user experience after being revoked:

1. User opens Convos on device A
2. App attempts to sync conversations
3. Sync operations silently fail (XMTP SDK returns errors for the revoked installations)
4. User sees conversations in the list, but:
   - Cannot send messages
   - Cannot receive new messages
   - Cannot do anything meaningful
5. No explanation is shown. User thinks the app is broken.

This is a bad UX. We need to detect that the current device has been revoked and present a clear, actionable state.

## Goals

- [ ] Detect when the current device's installation has been revoked for one or more inboxes
- [ ] Surface a clear, non-scary UI explaining what happened ("This device has been replaced from a backup on another device")
- [ ] Offer a clean exit path — log out / delete local data
- [ ] Prevent the user from seeing stale/broken conversation state
- [ ] Graceful handling of partial revocation (some inboxes revoked, some not — rare but possible)

## Non-Goals

- Trying to "recover" the revoked device (not possible — MLS is designed so revocation is final)
- Automatic re-pairing with the active device (future feature, vault-based)
- Cross-device notifications ("you've been logged out") via push (out of scope)

## Detection strategy

### XMTP SDK API

`client.inboxState(refreshFromNetwork: true)` returns an `InboxState` containing `installations: [Installation]`. Each `Installation` has an `id`. Our installation is revoked if `client.installationId` is **not** in that list.

This is a cheap, authoritative check — it hits the XMTP network to get the current state.

### When to check

Three points in the lifecycle:

1. **When an inbox reaches ready state** (after `Client.build` succeeds during app startup or inbox wake). Add the check right after `revokeInstallationsHandler` logic in `InboxStateMachine.handleStart`. If the stored installationId matches the new one (i.e., we expected to still be valid) but the remote state doesn't include us, we've been revoked.

2. **On app foreground** (via `AppLifecycleProviding`). If the user hasn't opened the app in a while, their inboxes may have been revoked on another device in the meantime. Check each active inbox on foreground transition.

3. **When an XMTP operation fails with a specific error**. The XMTP SDK may expose a "no installation in group" or "installation removed" error for sends/syncs. Catching these as a secondary signal is belt-and-suspenders.

For v1, start with **#1 (inbox ready)** and **#2 (foreground)**. #3 is a nice-to-have that we can layer on once we see the actual error types in the wild.

### Storage

Add a new column to `DBInbox`: `revocationState: String?` with values:

- `nil` / empty — normal, no revocation detected
- `"stale"` — this installation has been revoked for this inbox

Surface on the domain `Inbox` model so ViewModels can react.

Alternatively, store it in `ConversationLocalState` to keep it per-conversation, but since revocation is per-inbox (not per-conversation), `DBInbox` is the right place.

### Writer protocol

Add `InboxWriter.markStale(inboxId:)` that sets `revocationState = 'stale'`.

## UI treatment

### Conversations list

When any inbox is stale, show a top banner on the conversations list:

> ⚠️ This device has been replaced
>
> Your account has been restored on another device. This one is no longer active.
>
> [Log out]

The banner is dismissible (swipe away), but reappears on next launch until the user logs out / deletes data.

Individual conversations belonging to a stale inbox are either:
- Hidden entirely (cleanest)
- Shown but visually greyed out with a "read-only" indicator (less destructive but more confusing)

**Leaning toward hidden** — if the inbox is revoked, the user can't do anything with those conversations anyway.

### Conversation detail (if somehow reached)

If the user deep-links into a stale conversation, show a full-screen takeover:

> This conversation is on a device that was replaced. Log out to clean up.

### Settings

Existing "Delete All Data" flow is the exit path. Already works. No new UI needed.

## Flow diagram

```
Device B restores (already done)
  ↓
  Revokes device A's installations for all inboxes
  ↓
Device A opens app (later)
  ↓
  AppLifecycle.onForeground
  ↓
  For each active inbox:
    client.inboxState(refreshFromNetwork: true)
    if ourInstallationId not in installations:
      markStale(inboxId)
      emit QAEvent "inbox.revoked_detected"
  ↓
  Conversations list re-renders
  ↓
  ValueObservation picks up DBInbox.revocationState change
  ↓
  Banner appears
```

## Failure modes

- **Network unavailable**: `refreshFromNetwork: true` will fail. Fall back to cached state (may miss recent revocation). Next successful check catches up.
- **Partial detection**: if check runs on 3 of 5 inboxes before app backgrounds, only 3 are marked stale. Next foreground completes the others.
- **False positive**: extremely unlikely — we'd have to misread the remote state. `inboxState` is authoritative.
- **False negative**: impossible if the check completes — XMTP is the source of truth.

## Testing strategy

- Unit test: `InboxStateMachine` detects stale state when the SDK returns a mismatched installation list
- Unit test: `InboxWriter.markStale` updates the column correctly
- Unit test: `Inbox` domain model surfaces the stale flag
- Integration test: mock XMTP client that returns different installation lists before/after revocation
- Manual: back up on device A, restore on device B, open app on device A, verify banner appears, verify conversations are hidden

## Open Questions

1. **Hide conversations vs grey them out?** Leaning toward hide (cleaner, less confusing)
2. **Multiple simultaneously revoked inboxes** — show one banner, or per-inbox? Show one aggregate banner
3. **What if the user's quickname/profile is the only thing that's not revoked?** Quickname is UserDefaults, unrelated. No issue.
4. **Should the banner appear during app startup or only after the check completes?** Only after check — otherwise users see a scary banner every launch while we're still checking
5. **Log out vs delete all data** — the banner CTA should probably be "Delete data and start fresh" which is the existing flow
6. **What about the vault?** When the vault is re-created on device B, device A's vault installation is also revoked (with the upcoming fix). The same detection logic applies. Vault doesn't have a user-facing UI for this, but the flag should be set.

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Check hits network on every foreground | Low | Cache results, only refresh every N minutes |
| False positive locks user out | High | Never mark stale without a definitive remote check; double-confirm on retry |
| User dismisses banner but conversations still broken | Medium | Banner persists across launches until delete-all-data; conversations are hidden regardless |
| XMTP SDK behavior changes | Low | Abstract the check behind a protocol method; swap implementation if SDK changes |

## Sequencing

**Phase 1 — Detection + storage** (~1 day)
- Add `DBInbox.revocationState` column + migration
- Add `InboxWriter.markStale(inboxId:)`
- Add check in `InboxStateMachine.handleStart` after revoke logic
- Add check on app foreground via `AppLifecycleProviding`

**Phase 2 — Repository surfacing** (~0.5 day)
- Surface `isStale` on domain `Inbox` model
- Filter stale inboxes out of `ConversationsRepository.fetchAll` (or pass through and let the list decide)

**Phase 3 — UI** (~1 day)
- Banner on conversations list (reactive to stale state)
- Hide conversations from stale inboxes
- Wire "Delete data" button

**Phase 4 — Tests** (~0.5 day)

**Total: ~3 days**

## References

- `docs/plans/vault-re-creation-on-restore.md` — the complementary restore-side work
- `docs/plans/icloud-backup.md` — overall backup architecture
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` — revocation firing point
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBInbox.swift` — schema
- XMTP SDK: `Client.inboxState(refreshFromNetwork:)` → `InboxState.installations`
