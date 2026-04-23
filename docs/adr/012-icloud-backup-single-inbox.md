# ADR 012: iCloud Backup for Single-Inbox Identity

> **Status**: Accepted
> **Author**: @lourou
> **Created**: 2026-04-23
> **Supersedes**: the unshipped vault-centric iCloud backup work from
> `louis/icloud-backup` and `louis/backup-scheduler`
> **Related**: [ADR 003 — Inbox Lifecycle Management](./003-inbox-lifecycle-management.md), [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md), [docs/plans/icloud-backup-single-inbox.md](../plans/icloud-backup-single-inbox.md)

## Context

Convos needs device-to-device backup and restore so users can keep their
history when they replace or reinstall. The prior vault-centric design
(pre-#713) shipped N inboxes per user and built the backup stack around
that fan-out — per-conversation XMTP archives, a "vault" inbox brokering
keys, an `ICloudIdentityStore` dual-writing keys across devices, and a
`StaleDeviceState` enum covering the half-migrated cases. None of it
merged.

The single-inbox refactor (#713) collapses the identity count to one per
user. That invalidates most of the vault-era machinery:

- **Identity** already syncs via iCloud Keychain
  (`KeychainIdentityStore.v3` with `kSecAttrSynchronizable = true`), so
  cross-device key broadcast is an Apple problem now.
- **Group memberships + message history** sync through XMTP Device Sync
  (`deviceSyncEnabled: true`) *when another installation is online to
  upload the archive*. Device Sync does not cover device-loss or
  single-device-reinstall, which is exactly the "upgrade or replace
  their device" case that archive-based backup exists for.
- **Local GRDB state** (pinned/muted/unread, invite ledger, drafts,
  asset renewal bookkeeping, read receipts, profile snapshots) has no
  other path off-device.

So the backup bundle's job is narrow: cover the GRDB gap, plus a single
XMTP archive for the device-loss path.

## Decision

Ship an encrypted backup bundle that carries exactly three files:

- `convos-single-inbox.sqlite` — GRDB snapshot
- `xmtp-archive.bin` — one XMTP `createArchive` of the sole inbox
- `metadata.json` — inner metadata (carries the per-bundle `archiveKey`)

The whole bundle is sealed with AES-GCM using the identity's
`databaseKey` directly (no HKDF — the threat model already assumes
iCloud Keychain compromise leaks both that key and the SQLCipher DB it
already protects). An unencrypted sidecar sits next to the sealed
bundle carrying non-secret discovery fields so `findAvailableBackup`
can enumerate bundles without the bundle key.

Crash-safety comes from a persisted `RestoreTransaction` record in
app-group UserDefaults plus rollback artifacts (XMTP stash + GRDB
snapshot) under the shared container. `RestoreRecoveryManager` runs at
app start before `SessionManager` prewarm and reconciles any
pre-commit interruption.

The live-device side of "another device took over this account" is
surfaced as a `SessionStateMachine.State.error(DeviceReplacedError)`
that conforms to `TerminalSessionError`. The foreground-retry path
short-circuits on that marker so the reset banner is the only way out;
no silent coincidence-retry can land the session in `.ready`.

## Key design decisions

### One bundle per device, one XMTP archive per bundle

Single-inbox means `client.createArchive` on the sole installation
produces one archive. No per-conversation fan-out. The archive element
set is `[.messages]` only — consent is deliberately excluded so
restore doesn't pin a stale consent state; consent is reconciled by
the restored GRDB + the XMTP consent stream after the real client
boots.

### No HKDF on the bundle key

The `databaseKey` is already the SQLCipher key for the local XMTP DB.
Deriving a second key from it protects against no additional threat
(iCloud Keychain compromise takes both). Per-bundle AES-GCM nonces are
random (96-bit). HKDF here would be security theater carried over from
the vault era.

### Two keys, two roles — don't collapse them

The outer AES-GCM seal uses `identity.databaseKey`. The inner
`xmtp-archive.bin` is sealed with a per-bundle `archiveKey` (32 bytes
of fresh CSPRNG), stored inside the inner metadata inside the tar so
the outer seal protects it end-to-end. Per-bundle keys keep historical
bundles cryptographically isolated; a pre-iCloud-Keychain compromise
does not cascade to every archive ever made.

### `schemaGeneration` in metadata

The real version-skew risk isn't the bundle filename — it's GRDB
schema drift. `LegacyDataWipe` runs before `DatabaseManager` opens the
DB, so a restore of an old-schema bundle onto a newer app would be
silently wiped. Sidecar + inner metadata both carry
`schemaGeneration`; `findAvailableBackup` and
`decryptAndValidateBundle` refuse mismatches with a distinct
`RestoreError.schemaGenerationMismatch`.

### Throwaway XMTP client for archive import

Routing `importArchive` through `SessionStateMachine` would require a
new `.importing` state, a new action, and a `SessionManager`
cache-don't-cache branch — four coupling points for a one-shot
operation. Instead, `RestoreManager` constructs a throwaway
`Client.build` against the restored (empty) XMTP DB, calls
`importArchive`, and explicitly `dropLocalDatabaseConnection()` in a
defer. LibXMTP's SQLCipher pool is not ARC-managed; dropping the
Swift reference alone would leave the real client unable to reopen
the same DB.

A companion `isRestoringInProcess` flag on `SessionManager` (guarded
by the existing `cachedMessagingService` lock) prevents a concurrent
push delivery from racing a second client against the throwaway's
SQLCipher pool.

### Fresh-install bootstrap gate

On first launch the app would otherwise register a brand-new identity
before the restore prompt card appeared — invalidating the backup the
user never saw. `SessionManager.restoreBootstrapDecision`
(.unknown / .restoreAvailable / .noRestoreAvailable / .dismissedByUser
/ .restoreSucceeded) gates both `prewarmUnusedConversation()` and the
`.register` branch of `loadOrCreateService()` until the decision is
terminal. The app-layer restore prompt card is the only code that
advances it.

### Device-replaced detection is a session state, not a sidecar

Collapsed the prior `StaleDeviceState` + `InboxesRepository
.staleInboxIdsPublisher` + per-inbox `isStale` plumbing into a single
`SessionStateMachine.State.error(DeviceReplacedError)`. The check runs
in `handleClientAuthorized` between `authenticateBackend` and the
transition to `.ready`: one `Client.inboxStatesForInboxIds` call, then
`contains { $0.id == client.installationId }`. Network failures
treated as "still active" so a transient API blip doesn't spuriously
lock the user out.

### BackupScheduler honors the flag + foreground catch-up

iOS background tasks are best-effort. To keep the "daily backup"
product contract, `BackupScheduler` additionally runs a foreground
catch-up on launch/foreground if `lastSuccessfulBackupAt` is older
than 24 hours. Every path — manual, background, catch-up — shares one
`isBackupInProgress` mutex and skips (with telemetry) if
`RestoreInProgressFlag` is set.

## Consequences

Positive:
- Single file format, single flow — much smaller surface than the
  vault era. No `ICloudIdentityStore`, no `reCreateVault`, no
  `StaleDeviceState`.
- Restore is crash-safe end-to-end: the persisted
  `RestoreTransaction` + rollback artifacts let a killed app resume
  or roll back on next launch.
- Fresh installs can't invalidate their own restore opportunity.
- "This device has been replaced" is surfaced in one session-cycle
  rather than eventually.

Negative / tradeoffs:
- iCloud Drive entitlements aren't configured yet — the backup path
  falls back to the local app-group container until provisioning
  lands. Restore across devices won't actually work on production
  builds until that happens.
- `importArchive` failure is non-fatal but not silently recovered:
  the user gets a partial-restore warning and is asked to re-run
  restore. A later iteration may add a live-client retry path once
  XMTP SDK behavior on populated DBs is validated.
- The schema-generation guard means a user whose last backup predates
  a schema bump and who uninstalls before `BackupScheduler` refreshes
  cannot restore. This is the small population we accept; the common
  path (fresh daily bundle at newer generation) is unaffected.

## References

- [docs/plans/icloud-backup-single-inbox.md](../plans/icloud-backup-single-inbox.md)
- [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md)
- XMTP docs on History Sync + archive-based backup:
  https://docs.xmtp.org/inboxes/history-sync
