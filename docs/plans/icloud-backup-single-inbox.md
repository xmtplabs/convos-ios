# iCloud Backup — Port to Single-Inbox Identity

> **Status**: Draft (rev 2 after architect review)
> **Created**: 2026-04-21
> **Supersedes**: [docs/plans/icloud-backup.md](./icloud-backup.md) (vault-centric design, never merged)
> **Related**: [ADR 011 — Single-Inbox Identity Model](../adr/011-single-inbox-identity-model.md), [docs/plans/single-inbox-identity-refactor.md](./single-inbox-identity-refactor.md)
> **Prior work**: PRs [#591](https://github.com/xmtplabs/convos-ios/pull/591), [#596](https://github.com/xmtplabs/convos-ios/pull/596), [#602](https://github.com/xmtplabs/convos-ios/pull/602), [#603](https://github.com/xmtplabs/convos-ios/pull/603), [#618](https://github.com/xmtplabs/convos-ios/pull/618), [#626](https://github.com/xmtplabs/convos-ios/pull/626) on `louis/icloud-backup` + `louis/backup-scheduler`

## TL;DR

The old backup design was vault-centric because each conversation had its own XMTP inbox and we needed a way to move N keys across devices. The single-inbox refactor eliminated that problem. Backup now has a much smaller job — and per the architect review, a smaller one than the first draft of this plan assumed:

- **Identity keys** → already sync via iCloud Keychain (`KeychainIdentityStore` uses `kSecAttrSynchronizable = true` + `kSecAttrAccessibleAfterFirstUnlock` per ADR 011 §1). No bundle carries them.
- **Group memberships + message history** → XMTP Device Sync (`deviceSyncEnabled: true` per ADR 011 §2) replays from the XMTP history server on a second device. **The bundle does not duplicate this.**
- **Local GRDB state** (conversation local flags, pending invites, unread cursors, pinned/muted, cached profiles, invite tag ledger, asset renewal bookkeeping) → **only we can back this up**. This is the bundle's entire job.

Net result: the port is a ~60% deletion of the old stack. No vault, no per-conversation archives, no `ICloudIdentityStore`, no partial-stale state, **no in-bundle XMTP archive, no HKDF salt dance, no `RestoreLifecycleControlling` protocol**. The core infrastructure (bundle tar format, `replaceDatabase` with rollback, inactive-conversation UX, stale-device UX surfaced via `SessionStateMachine`, background scheduler, restore-prompt card) ports over much simpler.

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
| Same Apple ID, new device | iCloud Keychain ✓ | Device Sync replays ✓ | **Bundle restores it** |
| App reinstall, same device | iCloud Keychain ✓ | Device Sync replays ✓ | **Bundle restores it** |
| All devices lost (same Apple ID later) | iCloud Keychain ✓ | Device Sync replays ✓ | **Bundle restores it** |
| New Apple ID | ✗ — no path | ✗ — no path | ✗ — no path |

Only GRDB holds:

- `ConversationLocalState` — `isPinned`, `isMuted`, `isUnread`, `muteUntil`, `isActive`
- Invite ledger (`inviteTag` scoping, pending-invite timers)
- Draft messages (`DBDraft`)
- Profile snapshots + encrypted image refs not yet materialized
- Asset-renewal timestamps
- Expired-conversation metadata
- Read receipts / read cursors

Without the bundle, a restored user sees a correctly-populated conversation list (via Device Sync) but loses personalization and secondary state. **The bundle's job is to close that gap — nothing more.**

### Why no XMTP archive in the bundle

An earlier draft of this plan included `xmtp-archive.encrypted` alongside the GRDB snapshot "as cheap insurance against history-server gaps." Architect review killed this. Reasoning:

- Device Sync is the architectural contract (ADR 011 §2). Writing a parallel, eagerly-bundled copy of what the history server already provides means we're hedging against our own architecture.
- It introduces a real correctness hazard — `importArchive` racing against Device Sync on first boot of a restored device has undefined behavior per the XMTPiOS SDK's current shape. Verifying that behavior is a research task the bundle shouldn't be blocking on.
- It doubles the restore test matrix (consent-reset pass, failure modes for archive-missing vs archive-corrupt).

If measurement later reveals Device Sync gaps that matter, we add the archive as a v2 bundle feature with eyes open. For v1, **the bundle is GRDB + metadata.**

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
| `BackupManager` | **Simplify** | Delete: vault archive creation, per-conversation archive loop, `broadcastKeysToVault`, `nonVaultUsedInboxes` iteration, XMTP archive creation. Keep: staging dir, iCloud-or-local path resolution, atomic write with temp file, metadata sidecar. |
| `RestoreManager` | **Simplify** | Delete: vault archive import, `reCreateVault`, `saveKeysToKeychain` loop, per-conversation-archive import loop, archive-importer protocol, `revokeStaleInstallationsForRestoredInboxes` loop (collapses to one call). Keep: rollback harness (XMTP file stash + pre-restore keychain snapshot + `committed` boundary), `findAvailableBackup`, `markAllConversationsInactive`, progress `RestoreState` enum. |
| `RestoreLifecycleControlling` protocol | **Delete** | One state machine, one cache slot. `RestoreManager` calls package-internal `SessionManager` methods directly. See §Restore integration below. |
| `DatabaseManager.replaceDatabase` | **Salvage + harden** | Pool-to-pool copy with rollback snapshot. Update filename target to `convos-single-inbox.sqlite`. Require explicit WAL checkpoint before swap. Run the whole swap under `NSFileCoordinator`'s write barrier so the NSE coordinates. Preserve `DatabaseManagerError.rollbackFailed`. |
| `ConvosBackupArchiveProvider` | **Delete** | No XMTP archive in the bundle. |
| `ConvosRestoreArchiveImporter` | **Delete** | Same. |
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
│                     metadata.json                │
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
4. Write `metadata.json` (version, createdAt, deviceId, deviceName, osString, conversationCount, schemaGeneration, appVersion).
5. Tar the staging dir (with 4-byte magic + 1-byte version header prepended).
6. `AES.GCM.seal(tar, using: SymmetricKey(data: identity.keys.databaseKey))` → `backup-latest.encrypted`.
7. Atomic write to iCloud Drive (`replaceItemAt`); write sidecar `metadata.json` next to it.
8. Cleanup staging dir.

### Restore flow (new)

1. `findAvailableBackup` reads the sidecar `metadata.json` — no decryption needed. Rejects bundles whose `schemaGeneration` ≠ `LegacyDataWipe.currentGeneration`.
2. User confirms restore on `BackupRestoreSettingsView` (or fresh-install card).
3. `awaitIdentityWithTimeout(30s)` — blocks until `loadSync()` succeeds. On timeout, surface "iCloud Keychain still syncing, try again shortly."
4. Read sealed bundle → `AES.GCM.open(...)` with `identity.keys.databaseKey` → untar to staging.
5. Validate staging metadata version + presence of `convos-single-inbox.sqlite`.
6. `SessionManager.pauseForRestore()` — sets `restoreInProgress`, cancels `UnusedConversationCache`, stops the state machine, clears the cached service.
7. Stage aside: move `xmtp-*.db3` family to a temp stash, snapshot the current keychain identity (for rollback). (The keychain snapshot exists because `replaceDatabase` failures could leave us in a state where rolling the DB back is better than losing the XMTP files entirely.)
8. `DatabaseManager.replaceDatabase(with: staging/convos-single-inbox.sqlite)` — WAL checkpoint, `NSFileCoordinator` write barrier, pool-to-pool copy, rollback snapshot.
9. Commit point reached. Discard the XMTP stash.
10. `ConversationLocalStateWriter.markAllConversationsInactive()`.
11. `XMTPInstallationRevoker.revokeOtherInstallations(inboxId:, signingKey: identity.keys.signingKey, keepInstallationId: current)` — single call, non-fatal on failure.
12. `SessionManager.resumeAfterRestore()` — clears `restoreInProgress`, rebuilds the messaging service. `SessionStateMachine.authorize(inboxId:)` runs; Device Sync replays groups and message history from the XMTP history server; `StreamProcessor.reactivateIfNeeded` flips `isActive = true` on each conversation as peers issue MLS commits or send messages.
13. (No post-restore snapshot. The bundle is still valid — same identity, same `databaseKey`. Next scheduled daily backup handles the refresh.)

### Rollback harness (preserved)

The current `RestoreManager` on `louis/icloud-backup` has excellent discipline around destructive-op ordering:
- `preRestoreIdentities` snapshotted before wipe
- `xmtpStashDir` holds displaced files
- `destructiveOpsStarted` / `committed` flags gate rollback
- Rollback on any throw before commit: restore keychain + XMTP files
- Post-commit errors are non-fatal and do not roll back

All of that survives the port unchanged. One of the strongest parts of the old stack.

---

## PR stack

Target: a `dev`-based branch `backup-single-inbox-plan` with this document as PR 1. Land only after `single-inbox-refactor` (#713) merges.

Architect review collapsed 13 PRs to ~7. Each is standalone, compiles, passes `swift test --package-path ConvosCore`, independently reviewable.

### PR 1 — This plan
`docs/plans/icloud-backup-single-inbox.md`.
Blocker: `single-inbox-refactor` (#713) merged to `dev`.

### PR 2 — Inactive-conversation mode (floats ahead of the backup stack)

Lands on `dev` independently because it's useful on its own for network-recovery UX and de-risks the restore stack.

- Add `ConversationLocalState.isActive` column + migration step `v2-inactive-conversations`.
- Add `setActive`, `markAllConversationsInactive` to `ConversationLocalStateWriter`.
- Surface `isActive: Bool` on `Conversation` via hydration.
- Port `StreamProcessor.reactivateIfNeeded`, `markReconnectionIfNeeded`, `markRecentUpdatesAsReconnection` from old branch.
- Port `DBMessage.Update.isReconnection` with backward-compatible decoder default.
- Port `InactiveConversationBanner.swift` + wire `isActive` into `ConversationViewModel` + `ConversationView` (muted composer, send/reaction/reply interception → "Awaiting reconnection" alert).
- `ConversationsListItem` subtitle: add inactive indicator next to the existing `isPendingInvite` branch.
- Tests: reactivation on incoming message, reactivation on successful `syncAllConversations`, no reactivation on failed sync, `isReconnection` flag set on 5 most recent updates, UI state transitions.

### PR 3 — Bundle format + crypto

- Port `BackupBundle` (tar + path-traversal hardening) with 4-byte magic (`"CVBD"`) + 1-byte format version at head.
- Port `BackupBundleCrypto`: direct `SymmetricKey(data: databaseKey)` + `AES.GCM.seal` / `open`. **No HKDF, no salt.**
- Port `BackupBundleMetadata` with `schemaGeneration`, `conversationCount`, `appVersion`. No `hkdfSalt`.
- Tests: round-trip, path-traversal (salvaged from `BackupBundleTests`), magic-byte rejection on unknown format/version.

### PR 4 — `DatabaseManager.replaceDatabase` + NSE coordination

- Add `replaceDatabase(with backupPath: URL) throws` to `DatabaseManagerProtocol`.
- Port pool-to-pool implementation. Target `convos-single-inbox.sqlite`.
- WAL checkpoint before swap.
- Wrap swap in `NSFileCoordinator.coordinate(writingItemAt:)` against the DB URL.
- Add `RestoreInProgressFlag` helper (app-group UserDefaults key, set/get/clear API).
- Modify NSE entry point to early-exit when `RestoreInProgressFlag.isSet` (empty content delivery, push loss is acceptable for the narrow window).
- Preserve `DatabaseManagerError.rollbackFailed`.
- Tests: successful replace + migration, rollback-on-failure, double-fault produces `rollbackFailed`, NSE bail on flag set.

### PR 5 — `BackupManager` + `RestoreManager` + installation revocation (combined)

With the XMTP archive gone and `RestoreLifecycleControlling` deleted, this collapses from 3 PRs to 1.

- Port `BackupManager` in single-inbox form: GRDB snapshot + metadata → tar → seal → atomic iCloud/local write. Skip-if-no-identity, skip-if-restore-in-progress.
- Port `RestoreManager` in single-inbox form: `findAvailableBackup` (rejects schemaGeneration mismatch), `awaitIdentityWithTimeout`, decrypt → untar → validate → `pauseForRestore` → stash XMTP + snapshot identity → `replaceDatabase` → commit → `markAllConversationsInactive` → single `XMTPInstallationRevoker` call → `resumeAfterRestore`.
- Port `XMTPInstallationRevoker` (tiny file).
- Add `pauseForRestore()` / `resumeAfterRestore()` package-internal methods on `SessionManager` (cancels `UnusedConversationCache`, stops state machine, clears cache slot, sets/clears `RestoreInProgressFlag`).
- Rollback harness preserved (pre-restore keychain snapshot, XMTP stash, `committed` boundary).
- Tests: happy path, iCloud-unavailable → local fallback, rollback on replace failure, schemaGeneration mismatch refused, identity-timeout surfaces clean error, revocation failure is non-fatal, `RestoreState` progression, re-entrancy (second restore call while first is running is blocked).

### PR 6 — `SessionStateMachine` surfaces `.error(DeviceReplacedError)` + banner

- Define `DeviceReplacedError`.
- Add installation-active check to `SessionStateMachine` on `authenticatingBackend → ready` and on foreground retry. On detection, transition to `.error(DeviceReplacedError())`.
- `StaleDeviceBanner` single-variant ("This device has been replaced"). Observes `SessionStateObserver`. Reset action = `SessionManager.deleteAllInboxes()`.
- Delete any leftover `InboxesRepository.staleInboxIdsPublisher` / per-inbox `isStale` scaffolding if it survived the refactor.
- Tests: state transition on revocation, banner visibility driven by state, reset triggers teardown.

### PR 7 — Settings + scheduler + restore prompt + docs

Consolidation PR. Scheduler gets its own commit-level seam but ships in the same PR since the xcconfig change is small.

- Port `BackupRestoreSettingsView` + `BackupRestoreViewModel` in single-inbox form. Strip vault-specific UI.
- Port `BackupDebugView` (drop vault-sync debug).
- Port `BackupScheduler` (main-app target). `org.convos.backup.daily` task id. Register + schedule from `ConvosApp.init`. Honor `RestoreInProgressFlag` (skip with reschedule on conflict). Skip-if-no-identity.
- `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers` in Dev/Local/Prod xcconfigs. Verify emitted Info.plist per old plan's caution about array-typed keys from `INFOPLIST_KEY_*`.
- Port fresh-install restore prompt card (empty conversations view). Trigger: no inbox row in GRDB + `findAvailableBackup` returns a bundle + `loadSync()` succeeds. Re-check on `sceneDidBecomeActive`. Skip-persistence per `deviceId + createdAt`.
- New `docs/adr/012-icloud-backup-single-inbox.md` documenting ported design.
- Remove or annotate-as-superseded: `docs/plans/icloud-backup.md`, `docs/plans/stale-device-detection.md`, `docs/plans/icloud-backup-inactive-conversation-mode.md`, `docs/plans/vault-re-creation-on-restore.md`, `docs/plans/backup-restore-followups.md`.
- Release-notes snippet.

---

## What we're explicitly not doing in this port

- **Media in the bundle.** Deferred to a later bundle version. The 1-byte format version at the tar head supports discrimination.
- **XMTP archive in the bundle.** Device Sync is the contract. Revisit only if measurement shows gaps.
- **HKDF on the bundle key.** Not buying anything under the actual threat model.
- **Compression.** `Compression` framework DEFLATE is a natural v3 if bundle sizes grow. Measure first.
- **Disk-space preflight.** Today's bundles are well under 1MB. Revisit if users with very large GRDBs start seeing failures.
- **Multi-device pairing UX.** Out of scope — Device Sync + iCloud Keychain cover the happy path.
- **Incremental backups.** Full-snapshot each time.
- **Wiping the bundle on `deviceReplaced` reset.** Surviving same-Apple-ID devices can still decrypt it. Leave it alone.

---

## Resolved questions (with reasoning)

From the first draft of this plan, with architect review calls:

1. **XMTP archive in bundle?** **No.** Device Sync is the contract; including it creates a race and doubles the test matrix for zero benefit under the happy path.
2. **HKDF salt cadence?** **Moot — no HKDF.** Raw `databaseKey` as `SymmetricKey` is the correct ceremony level.
3. **Stale-device cadence?** **Foreground + on `authenticatingBackend → ready`.** One network call, driven from the existing `SessionStateMachine`.
4. **Wipe bundle on reset?** **No.** Leave it. Surviving same-Apple-ID devices can still decrypt. Destructive moves on user confusion are bad policy.
5. **Device Sync + importArchive overlap?** **Eliminated** by answer to #1.
6. **`databaseFilename` in metadata?** **No — `schemaGeneration` instead.** That's the thing that actually governs restore correctness.

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| NSE opens DB mid-swap | **Critical** | `RestoreInProgressFlag` + `NSFileCoordinator` write barrier in `replaceDatabase` (PR 4). |
| iCloud Keychain sync lag → new-identity fork | **Critical** | `awaitIdentityWithTimeout` gate in `RestoreManager` + fresh-install card gates Restore button on `loadSync()` success (PR 5). |
| `LegacyDataWipe` generation drift wipes restorable bundle | **High** | `metadata.schemaGeneration` + refusal on mismatch (PRs 3 + 5). |
| `BackupScheduler` fires during restore | **Medium** | Scheduler honors `RestoreInProgressFlag` and reschedules (PR 7). |
| `UnusedConversationCache` prewarm mid-restore poisons restored DB | **Medium** | `pauseForRestore` cancels and awaits unwind before swap (PR 5). |
| `SessionManager.cachedMessagingService` race with restore | **Medium** | `pauseForRestore` clears slot under lock; `resumeAfterRestore` lets `loadOrCreateService` naturally repopulate (PR 5). |
| `replaceDatabase` rollback fails (double-fault) | **Critical but rare** | `DatabaseManagerError.rollbackFailed`; UI must treat as fatal and surface reinstall path. Already covered in port. |
| Inactive conversation never reactivates (quiet conversation) | **Medium** | Banner persists — same limitation as old plan. Revisit with periodic `isActive()` probe in a follow-up if users report it. |
| Bundle decryption fails because identity rotated | **Low** | Only rotates on delete-all-data or on successful restore. Both are explicit user actions. |

---

## Success criteria

Phase complete when:

- [ ] Fresh install on Device B with the same Apple ID as Device A finds Device A's backup, restores it, and lands in a conversations list matching Device A's view (minus messages that reactivation clears as peers re-engage).
- [ ] App reinstall on the same device produces the same result.
- [ ] `DeviceReplacedError` surfaces within one foreground cycle of a second device taking over.
- [ ] Background backup runs daily on a real device without user action.
- [ ] NSE and `BackupScheduler` both drop work cleanly during a restore window.
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
