# iCloud Backup — Port to Single-Inbox Identity

> **Status**: Draft (rev 3 — XMTP archive re-added to bundle for device-loss restore)
> **Created**: 2026-04-21 (rev 3: 2026-04-22)
> **Supersedes**: [docs/plans/icloud-backup.md](./icloud-backup.md) (vault-centric design, never merged)
> **Related**: [ADR 011 — Single-Inbox Identity Model](../adr/011-single-inbox-identity-model.md), [docs/plans/single-inbox-identity-refactor.md](./single-inbox-identity-refactor.md)
> **Prior work**: PRs [#591](https://github.com/xmtplabs/convos-ios/pull/591), [#596](https://github.com/xmtplabs/convos-ios/pull/596), [#602](https://github.com/xmtplabs/convos-ios/pull/602), [#603](https://github.com/xmtplabs/convos-ios/pull/603), [#618](https://github.com/xmtplabs/convos-ios/pull/618), [#626](https://github.com/xmtplabs/convos-ios/pull/626) on `louis/icloud-backup` + `louis/backup-scheduler`

## TL;DR

The old backup design was vault-centric because each conversation had its own XMTP inbox and we needed a way to move N keys across devices. The single-inbox refactor eliminated that problem. Backup has a much smaller job — but not quite as small as rev 2 of this plan assumed:

- **Identity keys** → already sync via iCloud Keychain (`KeychainIdentityStore` uses `kSecAttrSynchronizable = true` + `kSecAttrAccessibleAfterFirstUnlock` per ADR 011 §1). No bundle carries them.
- **Group memberships + message history** → XMTP Device Sync (`deviceSyncEnabled: true` per ADR 011 §2) replays from the XMTP history server **only when a pre-existing installation is online** to upload the archive. In device-loss / single-device-reinstall scenarios there is no such installation, and Device Sync produces an empty history. The bundle therefore carries a **single-inbox XMTP archive** (`client.createArchive`) to cover that path.
- **Local GRDB state** (conversation local flags, pending invites, unread cursors, pinned/muted, cached profiles, invite tag ledger, asset renewal bookkeeping) → **only we can back this up**.

Net result: still a large deletion of the old stack. No vault, no per-conversation archives, no `ICloudIdentityStore`, no partial-stale state, no HKDF salt dance, no `RestoreLifecycleControlling` protocol. The in-bundle XMTP archive returns, but as a *single archive* covering the single inbox — not N per-conversation archives. The core infrastructure (bundle tar format, `replaceDatabase` with rollback, inactive-conversation UX, stale-device UX surfaced via `SessionStateMachine`, background scheduler, restore-prompt card) ports over much simpler.

---

## Why the old design had to go

The old backup design was built around three hard constraints that no longer exist:

1. **N identities per user.** One inbox per conversation meant N keychain entries and N XMTP databases. We needed a vault group to broadcast keys across devices; we needed per-conversation XMTP archives to rebuild each inbox's local MLS state; we needed `ICloudIdentityStore` to dual-write every key to iCloud Keychain.
2. **Vault couldn't self-recover.** A restored vault had no "other member" to re-admit the new installation, so `RestoreManager.reCreateVault` had to tear it down and create a fresh one, then `shareAllKeys()` to rebroadcast every conversation key.
3. **Partial staleness was a real state.** If one old device held installations across N inboxes and got some of them revoked (not all), the user genuinely lived in a mixed state. Hence `StaleDeviceState = { healthy, partialStale, fullStale }`.

All three collapse in the single-inbox world:

1. **One identity, already iCloud-synced.** The keychain entry at `org.convos.ios.KeychainIdentityStore.v3` account `convos-identity` is synchronizable by default.
2. **No vault to recover.** The only thing we would have re-created is the sole inbox, and the identity comes from iCloud Keychain.
3. **Staleness is binary.** There is exactly one installation per user; it is either active or revoked.

---

## What the new backup is for

With iCloud Keychain handling identity and XMTP Device Sync handling groups + messages, the bundle has to cover the gap — **our own GRDB state**. Concretely, the restore scenarios are:

| Scenario | Identity | XMTP groups + history | GRDB local state |
|---|---|---|---|
| Same Apple ID, new device, **prior install still online** | iCloud Keychain ✓ | Device Sync replays ✓ | **Bundle restores it** |
| Same Apple ID, new device, **prior install offline / gone** | iCloud Keychain ✓ | **Bundle archive restores it** (inactive/read-only) | **Bundle restores it** |
| App reinstall, same device (no other install) | iCloud Keychain ✓ | **Bundle archive restores it** | **Bundle restores it** |
| All devices lost (same Apple ID later) | iCloud Keychain ✓ | **Bundle archive restores it** | **Bundle restores it** |
| New Apple ID | ✗ — no path | ✗ — no path | ✗ — no path |

Per XMTP's own docs: History Sync requires a *pre-existing installation to be online* to receive the sync request, build the archive, and upload it to the history server. Without one, a newly-registered installation sees welcomes but no message history. This is the exact scenario archive-based backups exist to cover — XMTP's guidance is explicit that History Sync and archive-based backup serve the "multiple devices used at the same time" and "upgrade or replace their device" cases respectively. Convos backup is the second case.

Only GRDB holds:

- `ConversationLocalState` — `isPinned`, `isMuted`, `isUnread`, `muteUntil`, `isActive`
- Invite ledger (`inviteTag` scoping, pending-invite timers)
- Draft messages (`DBDraft`)
- Profile snapshots + encrypted image refs not yet materialized
- Asset-renewal timestamps
- Expired-conversation metadata
- Read receipts / read cursors

Without the bundle, a restored user sees a correctly-populated conversation list (via Device Sync) but loses personalization and secondary state. **The bundle's job is to close that gap — nothing more.**

### Why the bundle carries a single-inbox XMTP archive

Rev 2 of this plan omitted the XMTP archive, reasoning that Device Sync was the architectural contract and the archive would just hedge against our own architecture. That reasoning only holds for the multi-device-still-active path. Rev 3 adds a single-inbox XMTP archive back after confirming the gap against XMTP's own docs.

**Terminology check, since it matters here:** in XMTP, an *inbox* is the permanent user identity (one `inboxId` per Convos user under ADR 011). An *installation* is a device-level MLS client — one per device, per inbox. Groups contain installations as members, but installations are not per-group. The old "per-conversation archive" pattern was an artifact of the pre-refactor "one inbox per conversation" model; with single-inbox, `client.createArchive` on the sole installation produces **one archive covering the one inbox** — not N.

XMTP's own FAQ on the sync gap:

> *"Ensure... the pre-existing app installation is online to receive the sync request, process and encrypt the archive, upload it to the history server, and send a sync reply message to the new app installation."*

In the device-loss / single-device-reinstall cases, there is no pre-existing installation online; Device Sync produces an empty history. Since Convos backup's entire reason for existing is the "upgrade or replace their device" path, shipping without a history-recovery mechanism for that path is a silent-data-loss bug.

The shape this time is very different from the vault era:

- **One archive, not N.** A single `client.createArchive` per bundle — not one archive per conversation.
- **No race.** `importArchive` runs on the restored device *before* `SessionManager.resumeAfterRestore()`. If Device Sync later layers on top (when/if a peer installation comes online), it merges with the already-imported history per MLS semantics. Conversations imported from an archive are **inactive / read-only** per XMTP's own spec (`Group is inactive` on write) — which is exactly the UX state the `InactiveConversationBanner` was built for. They transition to active as peers re-engage via `StreamProcessor.reactivateIfNeeded`.
- **No consent duplication.** Archive element set is `{conversations, messages}` only; consent is reflected by the restored GRDB state and separately synced via XMTP's consent stream.
- **Bounded test matrix.** Three meaningful cases: archive present + peer online (redundant, both resolve to same state), archive present + no peer (archive is the ground truth), archive missing + peer online (degraded to rev-2 behavior — conversation list only).

The old concern about `importArchive` racing Device Sync "has undefined behavior per the XMTPiOS SDK's current shape" — that's a research task, not a blocker. The archive is written to a deterministic path in the bundle tar and imported on an empty SQLCipher DB immediately after `replaceDatabase`, before any streams are opened. That's the ordering XMTP's archive docs describe.

---

## Component-by-component port

Each row is tagged as:
- **Salvage** — move over largely intact, adjust for single-inbox
- **Simplify** — keep the concept, collapse the state
- **Delete** — no longer needed

| File / concept | Verdict | Notes |
|---|---|---|
| `BackupBundle` (tar format + path-traversal hardening) | **Salvage** | Add magic bytes + 1-byte format version at the head of the tar. No other changes. |
| `BackupBundleCrypto` (AES-256-GCM) | **Salvage** | Use the identity's raw `databaseKey` directly as the `SymmetricKey`. **No HKDF, no salt.** See §HKDF below. |
| `BackupBundleMetadata` | **Salvage** | Drop `inboxCount`. Add `conversationCount`, `schemaGeneration`, `appVersion`. No `hkdfSalt`. |
| `BackupManager` | **Simplify** | Delete: vault archive creation, per-conversation archive loop, `broadcastKeysToVault`, `nonVaultUsedInboxes` iteration. Keep: staging dir, iCloud-or-local path resolution, atomic write with temp file, metadata sidecar. **Keep** single-inbox XMTP archive creation via `client.createArchive(elements: [.conversations, .messages])`. |
| `RestoreManager` | **Simplify** | Delete: vault archive import, `reCreateVault`, `saveKeysToKeychain` loop, per-conversation-archive import loop, archive-importer protocol, `revokeStaleInstallationsForRestoredInboxes` loop (collapses to one call). Keep: rollback harness (XMTP file stash + pre-restore keychain snapshot + `committed` boundary), `findAvailableBackup`, `markAllConversationsInactive`, progress `RestoreState` enum. **Add** single `client.importArchive` call after `replaceDatabase` and before `resumeAfterRestore`. |
| `RestoreLifecycleControlling` protocol | **Delete** | One state machine, one cache slot. `RestoreManager` calls package-internal `SessionManager` methods directly. See §Restore integration below. |
| `DatabaseManager.replaceDatabase` | **Salvage + harden** | Pool-to-pool copy with rollback snapshot. Update filename target to `convos-single-inbox.sqlite`. Require explicit WAL checkpoint before swap. Run the whole swap under `NSFileCoordinator`'s write barrier so the NSE coordinates. Preserve `DatabaseManagerError.rollbackFailed`. |
| `ConvosBackupArchiveProvider` | **Simplify** | Collapse from per-conversation-loop to a single `client.createArchive` call on the singleton inbox. Output path: `staging/xmtp-archive.bin` (archive is already encrypted by XMTP with a 32-byte key we generate per-bundle; that key is carried inside the GRDB-sidecar metadata tar entry so decryption needs only the bundle's own AES-GCM key). |
| `ConvosRestoreArchiveImporter` | **Simplify** | Collapse from per-conversation-loop to a single `client.importArchive` call. Invoked after `replaceDatabase`, before `resumeAfterRestore`. Non-fatal on failure — the GRDB restore is the primary contract; archive failure degrades to conversation-list-only. |
| `ConvosVaultArchiveImporter` | **Delete** | Vault is gone. |
| `VaultManager`, `VaultKeyStore`, `VaultKeyCoordinator`, `VaultManager+Archive`, `VaultHealthCheck`, vault sub-actors | **Delete** | Already gone on `single-inbox-refactor`. |
| `ICloudIdentityStore` (dual-write local + iCloud keychain) | **Delete** | The new `KeychainIdentityStore` is single-store-with-sync. |
| `KeychainIdentityStore.loadAll / deleteAll / identity(for:) / identities(...)` | **Delete** | Already gone on `single-inbox-refactor`; new API is `save/load/loadSync/delete`. |
| `XMTPInstallationRevoker` | **Salvage** | One call, with the restored identity's signing key, keeping `client.installationID`. Non-fatal on failure. |
| `StaleDeviceState` + partial/full distinction + `InboxesRepository.staleInboxIdsPublisher` | **Delete** | Surface "device replaced" as a `SessionStateMachine.State.error(DeviceReplacedError)` case on the existing state machine. No parallel enum, no separate publisher. See §Stale-device below. |
| Inactive-conversation mode (`ConversationLocalState.isActive`, `markAllConversationsInactive`, `setActive`, reactivation in `StreamProcessor.reactivateIfNeeded` / `markReconnectionIfNeeded`, `DBMessage.Update.isReconnection`) | **Salvage** | Unchanged. Useful on its own for network-recovery UX; lands ahead of the backup stack as an independent PR (see sequencing). |
| `InactiveConversationBanner` ("Restored from backup") | **Salvage** | Unchanged copy + icon. |
| `StaleDeviceBanner` + `StaleDeviceInfoView` + auto-reset flow | **Simplify** | Single-variant banner ("This device has been replaced"). Reads state from `SessionStateMachine.currentState`. Reset action is `SessionManager.deleteAllInboxes()`. |
| `BackupRestoreSettingsView` + `BackupRestoreViewModel` | **Salvage** | Strip vault-specific surfaces; keep "Back up now", "Last backup", "Available restore from [deviceName]", alert + confirmation, iCloud-availability warning. |
| `BackupDebugView` | **Salvage** | Drop vault-sync debug; keep bundle/restore diagnostics. |
| `VaultKeySyncDebugView` | **Delete** | Vault gone. |
| `BackupScheduler` + `BGProcessingTask` wiring + `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers` in xcconfigs | **Salvage + harden** | Skip condition simplifies from "vault not bootstrapped" to "no identity yet." Additionally: honor the process-wide `restoreInProgress` flag and skip-with-reschedule while a restore is active. |
| Fresh-install restore prompt card | **Salvage + harden** | Trigger condition simplifies to "no inbox row in GRDB." Re-check on `sceneDidBecomeActive`. Restore entry point blocks on a bounded `loadSync()` poll so iCloud Keychain sync lag can't produce a registered-new-identity fork. See §iCloud Keychain timing below. |
| Per-device backup path `iCloud/Convos/Documents/backups/<deviceId>/backup-latest.encrypted` + sidecar `metadata.json` | **Salvage** | Unchanged. Metadata sidecar for discover-without-decrypt stays. |

---

## Key design decisions (after architect review)

### No HKDF on the bundle key

The threat model in ADR 011 already concedes iCloud Keychain compromise leaks the identity. The `databaseKey` is 32 bytes of CSPRNG used only to decrypt *this user's own backup*. XMTPiOS already uses the same `databaseKey` as the SQLCipher key for the XMTP DB, so "compromising the backup key compromises the XMTP DB" was already the threat model before the bundle existed. HKDF here would be security theater carried over from the vault world.

Implementation:

```swift
// encrypt
let key = SymmetricKey(data: identity.keys.databaseKey)
let sealed = try AES.GCM.seal(tarData, using: key)
return sealed.combined ?? throw CryptoError.encryptionFailed(...)

// decrypt
let key = SymmetricKey(data: identity.keys.databaseKey)
let sealed = try AES.GCM.SealedBox(combined: data)
return try AES.GCM.open(sealed, using: key)
```

That's it. No salt, no info string, no sidecar derivation parameter. The nonce is AES-GCM's built-in 96-bit random.

### `schemaGeneration` in metadata (not `databaseFilename`)

The bundle's real version-skew risk is not the filename — it's the GRDB schema. `LegacyDataWipe` is gated on a `convos.schemaGeneration` marker in app-group UserDefaults; the current tag is `single-inbox-v2`. If we ever bump the generation, the wipe runs *before* `DatabaseManager` opens the DB, which is before restore runs. A bundle built at generation N, restored on a device running generation N+1, would be wiped by the wipe pass and silently lost.

Mitigation: `metadata.json` carries `schemaGeneration: String`. `RestoreManager.findAvailableBackup` compares against `LegacyDataWipe.currentGeneration` and refuses mismatches with a clear error. Same-generation bundles restore as today; cross-generation bundles surface a "this backup was made on an older version of Convos and can't be restored" message.

### Restore integration with `SessionManager` directly

`RestoreLifecycleControlling` existed in the vault era to coordinate teardown across N `InboxLifecycleManager` entries. Post-refactor there is exactly one `SessionStateMachine` actor and exactly one `MessagingService` cache slot (`SessionManager.cachedMessagingService`).

The honest shape of "prepare for restore" is closer to `deleteAllInboxes()` without the delete: stop the state machine, drop the cached service, cancel any `UnusedConversationCache` prewarm in flight, swap the DB file, let the next `messagingService()` call naturally repopulate the cache on the (unchanged) identity.

The seam: two package-internal methods on `SessionManager`, no protocol, no mock.

```swift
// SessionManager (package-internal, not in the public protocol)
func pauseForRestore() async {
    // mark process-wide flag
    RestoreInProgressFlag.set(true)
    // cancel prewarm and await unwind
    await unusedConversationCache.cancel()
    // stop the state machine (releases XMTP client + GRDB connections)
    if let service = cachedMessagingService.withLock({ $0 }) {
        await service.sessionStateManager.stop()
    }
    // clear the cache slot — next access will rebuild
    cachedMessagingService.withLock { $0 = nil }
}

func resumeAfterRestore() async {
    RestoreInProgressFlag.set(false)
    // first access will run loadSync + rebuild service on the restored DB
    _ = loadOrCreateService()
}
```

`RestoreManager` takes a `SessionManager` directly. No protocol, no registration, no mocking surface. Tests inject a `SessionManager` built against an in-memory keychain store.

### NSE coordination during DB swap

`convos-single-inbox.sqlite` is shared between the main app and the NotificationService Extension via the app-group container. A push delivery during the ~1–2s restore window could open the DB file mid-swap — worst case, the NSE opens a half-written DB and corrupts the WAL, or the main app's `replaceItemAt` fails because the NSE holds a read lock.

Two-layer fix:

1. **Process-wide flag**: a `restoreInProgress` bool in app-group UserDefaults, set/cleared by `SessionManager.pauseForRestore` / `resumeAfterRestore`. The NSE checks this at entry (`didReceive(_:withContentHandler:)`) and bails with an empty content delivery if set. Push delivery loss during a restore window is acceptable — the restore itself is a narrow window explicitly initiated by the user.
2. **`NSFileCoordinator` write barrier**: `DatabaseManager.replaceDatabase` runs the pool-to-pool swap under `NSFileCoordinator.coordinate(writingItemAt:…)` against the DB URL. Any coordinated reader (which the NSE's `DatabaseManager` init already is, if we thread coordination through) waits for the barrier.

`BackupScheduler` honors the same `restoreInProgress` flag: if a scheduled backup fires mid-restore, it returns `setTaskCompleted(success: true)` immediately and reschedules, avoiding an open-for-read during the swap.

### iCloud Keychain sync gate on restore entry

`KeychainIdentityStore.loadSync()` returns `nil` on fresh install until iCloud Keychain syncs the identity. `SessionManager.loadOrCreateService()` already tolerates this via the 5s backoff. But the restore flow must not enter the `.register` branch during this window — it would mint a new identity whose `databaseKey` can't decrypt the bundle, and the user would be permanently locked out of their backup.

Fix: `RestoreManager.restoreFromBackup` gates on a bounded `loadSync()` poll before any destructive op.

```swift
private func awaitIdentityWithTimeout(_ timeout: Duration = .seconds(30)) async throws -> KeychainIdentity {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let identity = try? identityStore.loadSync() {
            return identity
        }
        try await Task.sleep(for: .milliseconds(500))
    }
    throw RestoreError.identityNotAvailable
}
```

The fresh-install restore prompt also uses `loadSync()` success as an additional gate before enabling the Restore button.

### Stale-device as a session state, not a sidecar

Architect call: collapse `StaleDeviceState` (and the `InboxesRepository.staleInboxIdsPublisher` + per-inbox `isStale` plumbing) into a `SessionStateMachine.State.error(DeviceReplacedError)` case.

Implementation:
- Define `DeviceReplacedError: Error` in `ConvosCore/Inboxes/`.
- `SessionStateMachine`'s existing foreground-retry path (which already calls `inboxState(refreshFromNetwork: true)`-style network checks) throws `DeviceReplacedError` when `client.installationId` is not in the active installations list.
- `State.error` already exists and is already observed by `SessionStateObserver`. `StaleDeviceBanner` observes and renders on a `DeviceReplacedError` match.
- Reset action = `SessionManager.deleteAllInboxes()`, same as today.

No new publisher, no new state enum, no new DB column. The check is one network call on foreground + on `authenticatingBackend → ready`.

---

## Architecture after the port

```
┌──────────────────────────────────────────────────┐
│  iCloud Keychain (identity, 1 key total)         │  ← Apple handles sync
│    org.convos.ios.KeychainIdentityStore.v3       │    (kSecAttrSynchronizable)
├──────────────────────────────────────────────────┤
│  Encrypted Backup Bundle (iCloud Drive)          │  ← Our only payload
│    iCloud/Convos/Documents/backups/<deviceId>/   │
│      metadata.json        (discovery, unencrypted)│
│      backup-latest.encrypted                     │
│        └─ AES-GCM(identity.databaseKey)          │
│             └─ tar: convos-single-inbox.sqlite   │
│                     xmtp-archive.bin             │  ← single-inbox archive
│                     metadata.json                │     (XMTP createArchive)
├──────────────────────────────────────────────────┤
│  XMTP History Server                             │  ← deviceSyncEnabled = true
│    group memberships, message history            │     (Apple/XMTP handle it)
├──────────────────────────────────────────────────┤
│  Local state:                                    │
│    KeychainIdentityStore.v3                      │
│    convos-single-inbox.sqlite                    │
│    xmtp-*.db3                                    │
└──────────────────────────────────────────────────┘
```

### Backup flow (new)

1. Early-exit if `RestoreInProgressFlag.isSet`.
2. Load identity from keychain (`loadSync`). Skip if `nil` (no identity yet → nothing to back up).
3. GRDB: `dbPool.backup(to: DatabaseQueue(path: staging/convos-single-inbox.sqlite))`.
4. XMTP: `client.createArchive(path: staging/xmtp-archive.bin, encryptionKey: archiveKey, elements: [.conversations, .messages])`. `archiveKey` is 32 bytes of fresh CSPRNG per bundle.
5. Write `metadata.json` (version, createdAt, deviceId, deviceName, osString, conversationCount, schemaGeneration, appVersion, archiveKey, archiveMetadata {startNs, endNs}).
6. Tar the staging dir (with 4-byte magic + 1-byte version header prepended).
7. `AES.GCM.seal(tar, using: SymmetricKey(data: identity.keys.databaseKey))` → `backup-latest.encrypted`. The inner `archiveKey` is now protected by the same AES-GCM layer, so bundle decryption remains a single-key operation.
8. Atomic write to iCloud Drive (`replaceItemAt`); write sidecar `metadata.json` next to it (sidecar omits `archiveKey` — discovery doesn't need it).
9. Cleanup staging dir.

### Restore flow (new)

1. `findAvailableBackup` reads the sidecar `metadata.json` — no decryption needed. Rejects bundles whose `schemaGeneration` ≠ `LegacyDataWipe.currentGeneration`.
2. User confirms restore on `BackupRestoreSettingsView` (or fresh-install card).
3. `awaitIdentityWithTimeout(30s)` — blocks until `loadSync()` succeeds. On timeout, surface "iCloud Keychain still syncing, try again shortly."
4. Read sealed bundle → `AES.GCM.open(...)` with `identity.keys.databaseKey` → untar to staging.
5. Validate staging metadata version + presence of `convos-single-inbox.sqlite` + `xmtp-archive.bin` + inner `archiveKey`.
6. `SessionManager.pauseForRestore()` — sets `restoreInProgress`, cancels `UnusedConversationCache`, stops the state machine, clears the cached service.
7. Stage aside: move `xmtp-*.db3` family to a temp stash, snapshot the current keychain identity (for rollback).
8. `DatabaseManager.replaceDatabase(with: staging/convos-single-inbox.sqlite)` — WAL checkpoint, `NSFileCoordinator` write barrier, pool-to-pool copy, rollback snapshot.
9. Rebuild XMTP client on the restored identity against a fresh empty XMTP DB file (the stashed ones are discarded on commit).
10. `client.importArchive(path: staging/xmtp-archive.bin, encryptionKey: archiveKey)`. Imported conversations are inactive/read-only per XMTP's own semantics. Non-fatal on failure — log via `Logger.error` and continue; the GRDB restore is still useful on its own.
11. Commit point reached. Discard the XMTP stash.
12. `ConversationLocalStateWriter.markAllConversationsInactive()` — redundant with step 10 for archived conversations, but covers conversations present in GRDB but absent from the archive (edge case).
13. `XMTPInstallationRevoker.revokeOtherInstallations(inboxId:, signingKey: identity.keys.signingKey, keepInstallationId: current)` — single call, non-fatal on failure.
14. `SessionManager.resumeAfterRestore()` — clears `restoreInProgress`, rebuilds the messaging service. `SessionStateMachine.authorize(inboxId:)` runs on the already-populated XMTP DB. Device Sync, if another installation is online, layers on top and merges per MLS. `StreamProcessor.reactivateIfNeeded` flips `isActive = true` on each conversation as peers issue MLS commits or send messages.
15. (No post-restore snapshot. The bundle is still valid — same identity, same `databaseKey`. Next scheduled daily backup handles the refresh.)

### Rollback harness (preserved)

The current `RestoreManager` on `louis/icloud-backup` has excellent discipline around destructive-op ordering:
- `preRestoreIdentities` snapshotted before wipe
- `xmtpStashDir` holds displaced files
- `destructiveOpsStarted` / `committed` flags gate rollback
- Rollback on any throw before commit: restore keychain + XMTP files
- Post-commit errors are non-fatal and do not roll back

All of that survives the port unchanged. One of the strongest parts of the old stack.

---

## Ship plan (3 PRs)

Rev 2 proposed a 7-PR stack. Rev 3 collapses it: almost everything in the stack is tightly coupled (restore needs `replaceDatabase`; `replaceDatabase` needs NSE coordination; NSE coordination needs the flag that only the restore flow sets; the UI exists to drive the restore flow), so splitting it buys little and costs real review-coordination overhead. #713 shipped 197 files as one PR and that was the right call for coherent work — same pattern here.

Target: `dev`-based branch `backup-single-inbox-plan`. Land only after `single-inbox-refactor` (#713) merges (already the case).

### PR 1 — This plan
`docs/plans/icloud-backup-single-inbox.md`. What #724 already is.

### PR 2 — Inactive-conversation mode (floats ahead)

Lands on `dev` independently because it's useful on its own for network-recovery UX and de-risks the restore path.

- Add `ConversationLocalState.isActive` column + migration step `v2-inactive-conversations`.
- Add `setActive`, `markAllConversationsInactive` to `ConversationLocalStateWriter`.
- Surface `isActive: Bool` on `Conversation` via hydration.
- Port `StreamProcessor.reactivateIfNeeded`, `markReconnectionIfNeeded`, `markRecentUpdatesAsReconnection` from old branch.
- Port `DBMessage.Update.isReconnection` with backward-compatible decoder default.
- Port `InactiveConversationBanner.swift` + wire `isActive` into `ConversationViewModel` + `ConversationView` (muted composer, send/reaction/reply interception → "Awaiting reconnection" alert).
- `ConversationsListItem` subtitle: add inactive indicator next to the existing `isPendingInvite` branch.
- Tests: reactivation on incoming message, reactivation on successful `syncAllConversations`, no reactivation on failed sync, `isReconnection` flag set on 5 most recent updates, UI state transitions.

### PR 3 — Backup + restore (everything else)

One feature branch, organized via commits rather than PR boundaries. Every commit compiles and passes `swift test --package-path ConvosCore` — the checkpoint discipline from #713 carries over.

**Bundle format + crypto**
- `BackupBundle` (tar + path-traversal hardening) with 4-byte magic (`"CVBD"`) + 1-byte format version at head.
- `BackupBundleCrypto`: direct `SymmetricKey(data: databaseKey)` + `AES.GCM.seal` / `open`. **No HKDF.**
- `BackupBundleMetadata` with `schemaGeneration`, `conversationCount`, `appVersion`, `archiveKey` (inner/encrypted only).

**`DatabaseManager.replaceDatabase` + NSE coordination**
- `replaceDatabase(with backupPath: URL) throws` on `DatabaseManagerProtocol`. Pool-to-pool, WAL checkpoint before swap, `NSFileCoordinator.coordinate(writingItemAt:)` around the swap. Target `convos-single-inbox.sqlite`. Preserve `DatabaseManagerError.rollbackFailed`.
- `RestoreInProgressFlag` helper (app-group UserDefaults).
- NSE entry point early-exits on `RestoreInProgressFlag.isSet` (empty content delivery — push loss in a user-initiated restore window is acceptable).

**`BackupManager` + `RestoreManager` + XMTP archive + revocation**
- `BackupManager`: GRDB snapshot → `client.createArchive(elements: [.conversations, .messages])` with fresh 32-byte `archiveKey` → metadata → tar → seal → atomic iCloud/local write. Skip-if-no-identity, skip-if-restore-in-progress.
- `RestoreManager`: `findAvailableBackup` (rejects schemaGeneration mismatch), `awaitIdentityWithTimeout`, decrypt → untar → validate → `pauseForRestore` → stash XMTP + snapshot identity → `replaceDatabase` → rebuild client on fresh XMTP DB → `client.importArchive` (non-fatal) → commit → `markAllConversationsInactive` → `XMTPInstallationRevoker` (non-fatal) → `resumeAfterRestore`.
- `ConvosBackupArchiveProvider` / `ConvosRestoreArchiveImporter` in simplified single-call form.
- `pauseForRestore()` / `resumeAfterRestore()` as package-internal methods on `SessionManager`.
- Rollback harness: pre-restore keychain snapshot, XMTP stash, `committed` boundary. Rollback path restores XMTP stash and exits before `importArchive` runs — no half-imported state to unwind.

**`DeviceReplacedError` + banner**
- `DeviceReplacedError: Error` in `ConvosCore/Inboxes/`.
- `SessionStateMachine` installation-active check on `authenticatingBackend → ready` and on foreground retry; transitions to `.error(DeviceReplacedError())` on detection.
- `StaleDeviceBanner` single-variant ("This device has been replaced"), observes `SessionStateObserver`. Reset action = `SessionManager.deleteAllInboxes()`.
- Delete any leftover `staleInboxIdsPublisher` / per-inbox `isStale` scaffolding.

**Settings + scheduler + restore prompt + docs**
- `BackupRestoreSettingsView` + `BackupRestoreViewModel` (strip vault-specific UI).
- `BackupDebugView` (drop vault-sync debug).
- `BackupScheduler` (main-app target, `org.convos.backup.daily`, register + schedule from `ConvosApp.init`, honor `RestoreInProgressFlag`). `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers` in xcconfigs.
- Fresh-install restore prompt card (empty conversations view, re-check on `sceneDidBecomeActive`, gates Restore on `loadSync()` success).
- New `docs/adr/012-icloud-backup-single-inbox.md`.
- Supersede/remove: `docs/plans/icloud-backup.md`, `stale-device-detection.md`, `icloud-backup-inactive-conversation-mode.md`, `vault-re-creation-on-restore.md`, `backup-restore-followups.md`.
- Release-notes snippet.

**Test coverage** (not a commit, but the bar for merge)
- Happy paths: archive + peer online, archive only, no archive + peer online (degraded), no backup available.
- Failure modes: iCloud-unavailable → local fallback, rollback on `replaceDatabase` failure, double-fault → `rollbackFailed`, schemaGeneration mismatch refused, identity-timeout clean error, `importArchive` failure non-fatal and surfaces as `RestoreState.archiveImportFailed`, revocation failure non-fatal, NSE bail on flag set, scheduler reschedules on flag set.
- Integration: full `swift test --package-path ConvosCore` green; QA regression against the `single-inbox-refactor` baseline is zero regressions.

---

## What we're explicitly not doing in this port

- **Media in the bundle.** Deferred to a later bundle version. The 1-byte format version at the tar head supports discrimination.
- **HKDF on the bundle key.** Not buying anything under the actual threat model.
- **Compression.** `Compression` framework DEFLATE is a natural v3 if bundle sizes grow. Measure first.
- **Disk-space preflight.** Today's bundles are well under 1MB. Revisit if users with very large GRDBs start seeing failures.
- **Multi-device pairing UX.** Out of scope — Device Sync + iCloud Keychain cover the happy path.
- **Incremental backups.** Full-snapshot each time.
- **Wiping the bundle on `deviceReplaced` reset.** Surviving same-Apple-ID devices can still decrypt it. Leave it alone.

---

## Resolved questions (with reasoning)

1. **XMTP archive in bundle?** **Yes — one archive per bundle (the single-inbox archive).** Rev 2 said no on the grounds that Device Sync was the contract; that's true for the multi-device-still-active path but wrong for device-loss / single-device-reinstall, which is the primary reason backup exists. XMTP's own docs recommend archive-based backups for exactly this case. The archive is scoped to the single inbox (not N per-conversation archives), so the footprint cost is bounded.
2. **HKDF salt cadence?** **Moot — no HKDF.** Raw `databaseKey` as `SymmetricKey` is the correct ceremony level.
3. **Stale-device cadence?** **Foreground + on `authenticatingBackend → ready`.** One network call, driven from the existing `SessionStateMachine`.
4. **Wipe bundle on reset?** **No.** Leave it. Surviving same-Apple-ID devices can still decrypt. Destructive moves on user confusion are bad policy.
5. **Device Sync + importArchive overlap?** **Ordered, not raced.** `importArchive` runs inside `pauseForRestore`, on a fresh empty XMTP DB, before streams open. Device Sync — if a peer later comes online — merges per MLS semantics with already-imported conversations. The imported conversations are MLS-inactive until reactivated by the peer, so there is no writable-state collision.
6. **`databaseFilename` in metadata?** **No — `schemaGeneration` instead.** That's the thing that actually governs restore correctness.

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| NSE opens DB mid-swap | **Critical** | `RestoreInProgressFlag` + `NSFileCoordinator` write barrier in `replaceDatabase`. |
| iCloud Keychain sync lag → new-identity fork | **Critical** | `awaitIdentityWithTimeout` gate in `RestoreManager` + fresh-install card gates Restore button on `loadSync()` success. |
| `LegacyDataWipe` generation drift wipes restorable bundle | **High** | `metadata.schemaGeneration` + refusal on mismatch. |
| Device Sync race with `importArchive` on fresh boot | **Medium** | `importArchive` runs inside the `pauseForRestore` window, on a fresh XMTP DB, before streams open. Device Sync, if a peer comes online later, merges per MLS semantics. |
| `BackupScheduler` fires during restore | **Medium** | Scheduler honors `RestoreInProgressFlag` and reschedules. |
| `UnusedConversationCache` prewarm mid-restore poisons restored DB | **Medium** | `pauseForRestore` cancels and awaits unwind before swap. |
| `SessionManager.cachedMessagingService` race with restore | **Medium** | `pauseForRestore` clears slot under lock; `resumeAfterRestore` lets `loadOrCreateService` naturally repopulate. |
| `importArchive` failure leaves GRDB restored but no message history | **Medium** | Non-fatal; surfaced via `RestoreState.archiveImportFailed(Error)`. User sees conversation list + inactive banners; Device Sync may later populate if a peer comes online. |
| `replaceDatabase` rollback fails (double-fault) | **Critical but rare** | `DatabaseManagerError.rollbackFailed`; UI must treat as fatal and surface reinstall path. Already covered in port. |
| Inactive conversation never reactivates (quiet conversation) | **Medium** | Banner persists — same limitation as old plan. Revisit with periodic `isActive()` probe in a follow-up if users report it. |
| Bundle decryption fails because identity rotated | **Low** | Only rotates on delete-all-data or on successful restore. Both are explicit user actions. |

---

## Success criteria

Phase complete when:

- [ ] Fresh install on Device B with the same Apple ID as Device A finds Device A's backup and restores it, with both the conversation list **and** message history present (conversations inactive until peers re-engage, per the MLS archive contract).
- [ ] App reinstall on the same device (no other installations) restores conversation list + message history from the bundle alone.
- [ ] "All devices lost, then restore later" walks back to the same end state.
- [ ] Multi-device happy path (Device A still online when Device B installs): Device Sync merges cleanly with the imported archive; no duplicate conversations, no lost messages.
- [ ] `DeviceReplacedError` surfaces within one foreground cycle of a second device taking over.
- [ ] Background backup runs daily on a real device without user action.
- [ ] NSE and `BackupScheduler` both drop work cleanly during a restore window.
- [ ] `importArchive` failure is non-fatal and surfaces as `RestoreState.archiveImportFailed`; restored user sees conversation list with inactive banners.
- [ ] All `RestoreManagerTests`, `BackupBundleTests`, `ConversationLocalStateWriterTests` pass. No `StaleDeviceStateTests` (deleted with the state enum).
- [ ] `swift test --package-path ConvosCore` green with zero new flakes. QA regression suite is zero regressions against the `single-inbox-refactor` baseline.

---

## References

- [ADR 011 — Single-Inbox Identity Model](../adr/011-single-inbox-identity-model.md)
- [docs/plans/single-inbox-identity-refactor.md](./single-inbox-identity-refactor.md)
- [docs/identity-system-overview.md](../identity-system-overview.md)
- [docs/vault-backup-architecture-review.md](../vault-backup-architecture-review.md) — prior-stack review, useful for concern list
- [`louis/icloud-backup`](https://github.com/xmtplabs/convos-ios/tree/louis/icloud-backup) — source of truth for code to port
- [`louis/backup-scheduler`](https://github.com/xmtplabs/convos-ios/tree/louis/backup-scheduler) — scheduler + restore prompt
