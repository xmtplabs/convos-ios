# ADR 012: iCloud Backup — Single-Inbox Architecture

> **Status**: Accepted (2026-04-23).
> **Supersedes**: the vault-centric backup design in
> [docs/plans/icloud-backup.md](../plans/icloud-backup.md),
> [docs/plans/stale-device-detection.md](../plans/stale-device-detection.md),
> [docs/plans/icloud-backup-inactive-conversation-mode.md](../plans/icloud-backup-inactive-conversation-mode.md),
> [docs/plans/vault-re-creation-on-restore.md](../plans/vault-re-creation-on-restore.md),
> [docs/plans/backup-restore-followups.md](../plans/backup-restore-followups.md)
> (marked Superseded by this ADR).
> **Implementation plan**: [docs/plans/icloud-backup-single-inbox.md](../plans/icloud-backup-single-inbox.md) (Rev 4).
> **Depends on**: [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md).

## Context

The vault-centric backup stack on `louis/icloud-backup` was designed
under the per-conversation-inbox model (superseded by ADR 011): N
keychain identities, N XMTP databases, a vault group that broadcast
conversation keys to paired devices, and an `ICloudIdentityStore`
dual-write that kept the vault key in sync across iCloud Keychain.
With ADR 011's collapse to a single XMTP inbox per user, that
machinery is obsolete:

- **One identity**, already synchronizable by default
  (`KeychainIdentityStore` v3: `kSecAttrSynchronizable = true` +
  `kSecAttrAccessibleAfterFirstUnlock`). Identity flows across
  same-Apple-ID devices without any bundle.
- **Group memberships + message history** are replayed by XMTP
  Device Sync (`deviceSyncEnabled: true`) — **only when a
  pre-existing installation is online** to upload the archive to the
  history server. In the device-loss / single-device-reinstall
  cases (the entire reason backup exists), there is no such
  installation.
- **Local GRDB state** (conversation local flags, pending invites,
  unread cursors, pinned/muted, profile snapshots, invite-tag
  ledger, asset-renewal bookkeeping) is neither identity-material
  nor XMTP-managed — only the app's backup can preserve it.

The plan doc walks the rev 1→4 evolution; this ADR captures what
landed.

## Decision

Convos backs up a **single encrypted bundle** per device to iCloud
Drive. The bundle carries exactly what Device Sync and iCloud
Keychain don't: a GRDB snapshot, a single-inbox XMTP archive, and
metadata. Restore is destructive and user-initiated; progress is
surfaced via a typed `RestoreState` enum.

### 1. Bundle format

```
iCloud Drive / Convos / Documents / backups / <deviceId> /
    metadata.json             (sidecar, unencrypted, discovery-only)
    backup-latest.encrypted   (AES-256-GCM with identity.databaseKey)
        └─ tar (CVBD magic + 1-byte version):
             convos-single-inbox.sqlite   (GRDB snapshot)
             xmtp-archive.bin             (single-inbox XMTP archive)
             metadata.json                (full form; carries archiveKey)
```

- **Outer seal key**: `identity.databaseKey` (32 bytes). Raw — no
  HKDF. Under the ADR 011 threat model, XMTPiOS already uses the
  same `databaseKey` as the SQLCipher key, so HKDF buys no
  isolation that isn't already conceded.
- **Inner `archiveKey`**: fresh 32 bytes of CSPRNG per bundle,
  used only to decrypt `xmtp-archive.bin`, stored inside the
  GRDB-sidecar metadata tar entry. Ephemeral: a leaked historical
  bundle's archive key does not compromise any other bundle.
- **Sidecar**: unencrypted `metadata.json` next to the sealed
  bundle. Carries `deviceName`, `deviceId`, `createdAt`,
  `conversationCount`, `schemaGeneration`, `appVersion`, and
  bundle format `version`. Never carries `archiveKey` or any
  secret. Drives `findAvailableBackup` discovery without requiring
  the outer-seal key.

The tar format uses a 4-byte ASCII magic (`"CVBD"`) + 1-byte format
version at the head so future bundle-format bumps discriminate
cleanly rather than decoding past-incompatible data.

### 2. Create flow

`BackupManager.createBackup()`:

1. Early-exit if `RestoreInProgressFlag` is set (app-group
   UserDefaults).
2. Load identity via `loadSync()`; skip if `nil` (no inbox yet).
3. Snapshot GRDB via `dbReader.backup(to:)` into a staging dir.
4. Generate a fresh `archiveKey`; call
   `client.createArchive(path:encryptionKey:)` via the
   `XMTPClientProvider` protocol.
5. Write full `metadata.json` (with `archiveKey`) into the
   staging dir.
6. Tar the staging dir with the magic+version header.
7. `AES.GCM.seal` with `identity.databaseKey` → sealed bytes.
8. Atomic write (`replaceItemAt`) to
   `iCloud/Convos/Documents/backups/<deviceId>/backup-latest.encrypted`;
   fall back to local shared container if the iCloud container is
   unavailable.
9. Write the sidecar `metadata.json` (secret-free) **after** the
   sealed bundle. `findAvailableBackup` readers never see a sidecar
   pointing at a not-yet-landed bundle.

### 3. Restore flow

`RestoreManager.restoreFromBackup(bundleURL:)`:

1. Read bundle bytes.
2. `awaitIdentityWithTimeout` — bounded `loadSync()` poll (default
   30s, 500ms interval). iCloud Keychain may lag on fresh install;
   entering the `.register` branch with the restore bundle in hand
   would mint a forked identity that can never decrypt the bundle.
3. Decrypt + untar to a staging dir.
4. Validate: metadata present, `schemaGeneration` matches
   `LegacyDataWipe.currentGeneration` (mismatch throws a distinct
   `RestoreError.schemaGenerationMismatch` + emits telemetry),
   GRDB + XMTP archive present, `archiveKey` length correct.
5. `SessionManager.pauseForRestore()` — sets
   `RestoreInProgressFlag` (app-group) **and** an in-process
   `isRestoringInProcess` flag; stops the cached
   `MessagingService`; cancels the `UnusedConversationCache`
   prewarm. Cancellation-safe: any throw triggers
   `resumeAfterRestore` + rethrow.
6. Stage existing `xmtp-*.db3` files aside (rollback anchor).
7. `DatabaseManager.replaceDatabase(with:)` — pool-to-pool GRDB
   `backup(to:)`, WAL checkpoint before the swap,
   `NSFileCoordinator.coordinate(writingItemAt:)` barrier,
   rollback snapshot. Double-fault surfaces as
   `DatabaseManagerError.rollbackFailed`; UI treats as fatal.
8. Build a throwaway `XMTPiOS.Client` against the
   now-empty `xmtp-*.db3` directory and call `importArchive`.
   `defer { try? dropLocalDatabaseConnection() }` ensures the
   SQLCipher pool releases before the real session rebuilds.
   Non-fatal on throw: state transitions to
   `.archiveImportFailed`; GRDB restore is already committed, so
   degrading to conversation-list-only beats aborting.
9. **Commit point.** Discard the XMTP stash. Post-commit errors
   do not roll back.
10. `ConversationLocalStateWriter.markAllConversationsInactive()`
    — restored conversations land in the `InactiveConversationBanner`
    state until peers re-admit this installation. Reactivation is
    handled by `InactiveConversationReactivator` (PR #725).
11. `XMTPInstallationRevoker.revokeOtherInstallations` — one
    network call using the restored identity's signing key,
    keeping the newly-registered installation. Non-fatal.
12. `SessionManager.resumeAfterRestore()` — clears both flags;
    next `messagingService()` call rebuilds the session against
    the restored DB.

### 4. NSE coordination

The shared GRDB (`convos-single-inbox.sqlite`) and `xmtp-*.db3`
files are visible to the NotificationService Extension via the
app-group container. During the 1–2s restore window, the NSE must
not open coordinated handles on either.

Two-layer protection:

- **Process-crossing flag**: `RestoreInProgressFlag` in app-group
  `UserDefaults`. `SessionManager.pauseForRestore` sets it;
  `resumeAfterRestore` clears it. `NotificationService.didReceive`
  early-exits with empty content when set. Strict on set (throws
  if the app-group container is unavailable); lenient on read.
- **`NSFileCoordinator` write barrier**: `replaceDatabase` runs
  the swap under
  `coordinate(writingItemAt: .forReplacing)` against the DB URL.
  Any coordinated reader waits for the barrier.

### 5. Device-replaced detection

On successful authorization (`authenticatingBackend → ready`) and
on foreground retry, `SessionStateMachine.handleAuthorized`
probes `client.inboxState(refreshFromNetwork: true)`. If the
local installation ID is not in the active set, it throws
`DeviceReplacedError`, which conforms to a new
`TerminalSessionError` marker protocol.

`handleRetryFromError` short-circuits on `TerminalSessionError`
conformance — without this, a foreground retry could coincide with
a background keychain refresh and silently flip the session to
`.ready`, masking the reset-device banner that was the only path
out. Observer-side code (the `StaleDeviceBanner`) watches
`SessionStateObserver` and renders when the current state matches
`.error(DeviceReplacedError)`.

### 6. What the bundle does **not** contain

- Media assets. Remote attachments have their own 30-day URLs; a
  future bundle version (the 1-byte tar header bumps cleanly) may
  include them.
- Keychain identity material. iCloud Keychain handles that.
- MLS group memberships or message history in non-archive form.
  The single-inbox XMTP archive is the one and only copy.
- Retained XMTP server credentials. Archive is authoritative for
  its own point-in-time; divergence reconciles via MLS sync.

## Consequences

### Positive

- **One bundle, one key family**: outer seal keyed on the
  identity's `databaseKey`, inner archive keyed on a fresh
  ephemeral. Straightforward cryptographic story; the sidecar
  metadata is the only unencrypted file.
- **Device Sync + archive are complementary**, not competing.
  Multi-device-still-active restores use Device Sync; device-loss /
  single-device-reinstall uses the archive. Imported conversations
  are MLS-inactive until peers re-admit, reconciled by
  `InactiveConversationReactivator`.
- **One rollback path**: pre-commit throws unwind the XMTP file
  stash + session state. Post-commit errors surface via state
  (`archiveImportFailed`, revocation log), not thrown. User
  consented to destructive op; degrading beats aborting.
- **Terminal errors are explicit.** `TerminalSessionError` marker
  prevents the state machine from retrying a revoked installation
  into an incorrect `.ready` by coincidence.

### Negative

- **No media in v1.** Remote-attachment URLs may expire between
  backup and restore; user sees placeholder thumbnails for older
  messages.
- **Cross-Apple-ID users cannot restore.** Identity only crosses
  same-Apple-ID devices via iCloud Keychain. An Android user
  signing into iOS for the first time has no identity to decrypt
  the bundle with. Acceptable under the current consumer-app
  threat model.
- **`schemaGeneration` mismatch is a hard refusal.** Users with
  stale bundles (uninstalled after an older schema, reinstalling
  on a newer build) see a specific error and must start fresh. The
  next scheduled daily backup refreshes the sidecar for future
  cross-device restores.

### Mitigations

- **`archiveImportFailed` is retryable** (persistence + retry UI
  deferred to CP3e / follow-up PR): archive bytes stay on disk,
  Settings surfaces a "Retry history import" affordance, GRDB
  restore stands on its own in the meantime.
- **iCloud Keychain sync lag**: `awaitIdentityWithTimeout` gates
  the restore entry point on `loadSync()` success before touching
  any destructive op. Fresh-install restore prompt (deferred to
  follow-up PR) also re-checks on `sceneDidBecomeActive` so a
  late-syncing identity unblocks the Restore button without a
  manual retry.
- **NSE + `BackupScheduler` both honor `RestoreInProgressFlag`**.
  Scheduled backups mid-restore reschedule silently; NSE drops
  deliveries in-window.

## Security model

| Threat | Treatment |
| --- | --- |
| Attacker reads sealed bundle without identity | Blocked — AES-256-GCM with 32-byte `databaseKey` |
| Attacker reads sealed bundle with cached archive key from another bundle | Blocked — per-bundle ephemeral `archiveKey` |
| Attacker reads sidecar `metadata.json` | Only learns `deviceName`, `deviceId`, `createdAt`, `conversationCount`, `schemaGeneration`, `appVersion`, and bundle version. No secrets. |
| NSE reads DB mid-restore | Blocked — `RestoreInProgressFlag` + `NSFileCoordinator` barrier |
| Restored device spawns a second XMTP client against the same SQLCipher pool | Blocked — in-process `isRestoringInProcess` flag short-circuits `loadOrCreateService` during restore |
| Foreground retry masks device-replaced state | Blocked — `TerminalSessionError` marker + `handleRetryFromError` short-circuit |
| Stale bundle restored after schema bump silently corrupts DB | Blocked — `schemaGeneration` check in `findAvailableBackup` rejects cross-generation bundles |

## Related Files

### Code

- `ConvosCore/Sources/ConvosCore/Backup/BackupBundle.swift` — tar
  format, pack/unpack, path-traversal hardening.
- `ConvosCore/Sources/ConvosCore/Backup/BackupBundleCrypto.swift`
  — AES-256-GCM + archive-key generation.
- `ConvosCore/Sources/ConvosCore/Backup/BackupBundleMetadata.swift`
  — full vs sidecar projection.
- `ConvosCore/Sources/ConvosCore/Backup/BackupManager.swift` — create flow.
- `ConvosCore/Sources/ConvosCore/Backup/RestoreManager.swift` —
  restore flow + rollback harness + static `findAvailableBackup`.
- `ConvosCore/Sources/ConvosCore/Backup/RestoreInProgressFlag.swift`
  — app-group coordination flag + `RestoreInProgressError`
  placeholder for the `SessionManager` cache slot.
- `ConvosCore/Sources/ConvosCore/Backup/XMTPInstallationRevoker.swift`
  — one-call revocation via the `XMTPClientProvider` protocol.
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`
  — `pauseForRestore` / `resumeAfterRestore` with in-process flag
  gating `loadOrCreateService`.
- `ConvosCore/Sources/ConvosCore/Storage/DatabaseManager.swift`
  — `replaceDatabase(with:)` + `DatabaseManagerError.rollbackFailed`.
- `ConvosCore/Sources/ConvosCore/Inboxes/TerminalSessionError.swift`
  — marker protocol + `DeviceReplacedError`.
- `ConvosCore/Sources/ConvosCore/Inboxes/SessionStateMachine.swift`
  — stale-installation probe in `handleAuthorized` +
  `handleRetryFromError` short-circuit.
- `Convos/Conversations List/StaleDeviceBanner.swift` — "This device
  has been replaced" banner; wired into `ConversationsView` via
  `ConversationsViewModel.isDeviceReplaced`.

### Tests

- `BackupBundleTests` — tar round-trip, magic-byte rejection,
  path-traversal refusal, crypto key-length, sidecar omits
  `archiveKey`, metadata round-trip.
- `DatabaseManagerReplaceTests` — successful replace, missing file,
  corrupt backup rollback.
- `SessionManagerRestoreTests` — flag lifecycle, placeholder during
  pause, placeholder caching, eviction on resume.
- `BackupManagerTests` — happy path (sealed bundle decrypts,
  sidecar omits archiveKey), skip-on-restore, skip-on-no-identity,
  archive-failure surfaces.
- `RestoreManagerTests` — happy path, discovery, schema-generation
  mismatch, identity timeout, archive-import non-fatal.
- `TerminalSessionErrorTests` — marker-protocol conformance
  contract.

### Deferred to follow-up PRs

- `BackupRestoreSettingsView` + `BackupRestoreViewModel`
  (user-facing "Back up now" / "Restore" screen + retry-history
  affordance).
- `BackupDebugView` (debug-build diagnostics).
- `BackupScheduler` (main-app target, `BGProcessingTask`
  daily scheduling, `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers`
  xcconfig).
- Fresh-install restore-prompt card on the empty conversations
  view.
- Persisted archive bytes at `<sharedContainer>/pending-archive-import.bin`
  + "Retry history import" UX for the `archiveImportFailed`
  state.

All of the above depend on the machinery this ADR describes being
in place; none of them affect the on-disk bundle format or the
threat model, so they can land incrementally.
