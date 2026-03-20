# Convos Vault & Backup Architecture Review

**PRs analyzed:** #591, #596, #602, #603, #618, #626 (all by @lourou)
**Base:** `jarod/convos-vault-impl` (vault foundation by @yewreeka)

---

## Architecture Overview

### The Big Picture

The backup system uses a **vault-centric** architecture where the Convos Vault (an XMTP group conversation that stores conversation keys as messages) is the single source of truth for all cryptographic keys. This is layered in four tiers:

```
┌─────────────────────────────────────────────┐
│  iCloud Keychain (vault key only)           │  ← Disaster recovery
├─────────────────────────────────────────────┤
│  Encrypted Backup Bundle (iCloud Drive)     │  ← Full state restore
│  ┌─────────────────────────────────────┐    │
│  │ vault-archive.encrypted             │    │  Keys for all conversations
│  │ conversations/<inboxId>.encrypted   │    │  Per-conversation message history
│  │ database.sqlite                     │    │  GRDB app state
│  │ metadata.json                       │    │  Bundle version, device info
│  └─────────────────────────────────────┘    │
├─────────────────────────────────────────────┤
│  Vault Group (XMTP messages)                │  ← Live multi-device key sharing
├─────────────────────────────────────────────┤
│  Local Keychain + GRDB + XMTP DBs          │  ← Active device state
└─────────────────────────────────────────────┘
```

### PR Stack Summary

| PR | Purpose | Status |
|----|---------|--------|
| #591 | Vault key iCloud sync + keychain migration + debug tools | Foundation layer |
| #596 | Revoke other installations on restore + persist installationId | Security enforcement |
| #602 | Architecture plan document | Design reference |
| #603 | Backup bundle creation (AES-256-GCM encryption) | Create side |
| #618 | Restore flow (decrypt, import vault, replace DB) | Restore side |
| #626 | Inactive conversation mode, iCloud sync fix, restore reliability | Polish + critical fixes |

### Data Flow

**Backup:**
1. Broadcast all conversation keys to vault (`VaultManager.shareAllKeys()`)
2. Create vault XMTP archive → `vault-archive.encrypted`
3. Create per-conversation XMTP archives → `conversations/<inboxId>.encrypted`
4. Copy GRDB database → `database.sqlite`
5. Generate metadata → `metadata.json`
6. Tar all files → AES-256-GCM encrypt with vault `databaseKey` → write to iCloud Drive

**Restore:**
1. Find newest backup in iCloud Drive (sidecar `metadata.json` for discovery without decryption)
2. Load vault key from iCloud Keychain (via `ICloudIdentityStore` fallback)
3. Try all available vault keys to decrypt the bundle
4. Import vault archive → extract `[VaultKeyEntry]` with all conversation keys
5. Wipe local XMTP state (keychain identities + xmtp-* database files)
6. Save each key to local keychain
7. Replace GRDB database (backup API, with rollback on failure)
8. Import per-conversation XMTP archives
9. Mark all conversations inactive
10. On next message receipt, conversations reactivate automatically

---

## What's Good

### Vault-centric key management is the right call
Using the vault as the single source of truth means:
- Delete a conversation → vault handles it naturally
- Disable backups → remove one vault key from iCloud
- No need to maintain a separate key export/import system

### ICloudIdentityStore dual-write pattern is solid
The local-first, iCloud-fallback approach handles the common failure modes well:
- iCloud unavailable → local works, syncs later
- Fresh device restore → iCloud fallback kicks in, caches locally
- Both available → local preferred for speed

### Restore with rollback is defensive
`DatabaseManager.replaceDatabase()` creates a rollback snapshot before swapping. If the restore fails, it rolls back to the pre-restore state. This is significantly better than the naive "delete and replace" approach.

### Inactive conversation mode is well-thought-out
Post-restore, conversations can't immediately send/receive because the new installation hasn't been re-added to the MLS group. Rather than showing broken conversations, the UI surfaces an "Awaiting reconnection" state with appropriate interaction blocking, and automatically clears it when a message arrives (proving the other side has re-added this installation).

### Per-conversation failure isolation
Both backup and restore treat individual conversation archive failures as non-fatal. If one conversation's archive fails, the rest still succeed. This is critical for reliability at scale.

### Good test coverage
- 958 lines of keychain tests (migration, iCloud sync, edge cases)
- 561 lines of backup bundle tests (crypto, tar, metadata, orchestrator)
- 586 lines of restore manager tests (full flow, partial failure, state progression)
- Tests use proper mocks and protocol-based dependency injection

### Custom tar format with security protections
The `BackupBundle` tar implementation includes path traversal protection on unpack — validates that resolved file paths stay within the target directory. Symlink resolution prevents escape attacks.

---

## Areas of Concern

### 1. iCloud Keychain `synchronizable` flag was missing (Critical — fixed in #626)

The original `ICloudIdentityStore` in #591 used `kSecAttrAccessibleAfterFirstUnlock` without `kSecAttrSynchronizable: true`. This means vault keys were *never actually syncing to iCloud*. Each device created independent vault keys, making cross-device restore impossible.

This was fixed in #626, but it means **all testing on PRs #591-#618 was done against broken iCloud sync**. The fix required adding `synchronizable: Bool` to `KeychainIdentityStore` and threading it through all query paths.

**Concern:** This is a fundamental plumbing error that shipped across 4 PRs before being caught during physical device testing. The keychain test suite used mock stores, so it couldn't catch this. Consider adding an integration test that verifies the actual keychain query attributes include `kSecAttrSynchronizable` when expected.

### 2. Bundle encryption uses vault `databaseKey` directly

The backup bundle is encrypted with the vault's `databaseKey` — the same key that encrypts the vault's XMTP database. This means:
- If an attacker obtains the vault database key, they can decrypt all backups
- The vault database key is a 32-byte key generated once and never rotated
- There's no key derivation or salt — the raw `databaseKey` is used as the AES-256-GCM key

**Recommendation:** Consider deriving a backup-specific key from the vault key using HKDF: `backupKey = HKDF(ikm: databaseKey, info: "convos-backup-v1", salt: random)`. This way, compromising the backup key doesn't directly compromise the vault database, and the salt provides per-backup uniqueness.

### 3. Restore wipes all local XMTP state before import

`RestoreManager.restoreFromBackup()` calls `wipeLocalXMTPState()` which deletes all keychain identities and XMTP database files *before* importing the backup. If the import fails partway through, the user loses both their current state AND the backup.

The GRDB replacement has rollback protection (`replaceDatabase` creates a snapshot), but the keychain wipe + XMTP file deletion do not. If the process crashes between `wipeLocalXMTPState()` (line ~100) and `saveKeysToKeychain()` (line ~106), the user's keys are gone.

**Recommendation:** Either:
- Move the wipe to *after* successful import (rename/archive old files, only delete after confirmation), or
- Create a pre-wipe checkpoint that can be recovered from

### 4. `RestoreLifecycleControlling` error handling gap

In `restoreFromBackup()`, if `prepareForRestore()` succeeds but the restore fails, `finishRestore()` is called in the catch block to resume sessions. But if `finishRestore()` itself throws, that error is silently swallowed. The original restore error is re-thrown, but the app may be left in a partially stopped state.

### 5. `ConvosRestoreArchiveImporter` uses `Client.create` (network call) during restore

The archive importer calls `Client.create(account:options:)` when no existing XMTP database exists for an inbox. `Client.create` requires network access to register with the XMTP network. If the device is offline during restore, this will fail.

The backup path correctly uses `Client.build()` (local-only, no network). But the restore path falls back to `Client.create()` which is network-dependent. This means offline restore will fail for conversations that don't already have a local XMTP database.

**Recommendation:** Use `Client.build()` for restore as well, or make the network dependency explicit in the restore preconditions.

### 6. Custom tar format vs standard tar

`BackupBundle` implements a custom binary archive format (`[4-byte path length][path UTF8][8-byte file length][file data]`). This works, but:
- No compression — the entire directory tree is archived uncompressed before encryption
- No checksums per file — corruption within the encrypted blob can't be detected at the file level
- Not inspectable with standard tools — debugging requires custom code
- The format has no magic bytes or version header — can't distinguish between a corrupted file and an incompatible format

For v1 this is fine, but consider whether the `bundleVersion` in metadata is sufficient for future format evolution, or whether the binary format itself needs a version header.

### 7. `DatabaseManager.replaceDatabase` uses GRDB backup API but the approach changed between PRs

In #618, `replaceDatabase` was implemented as close-pool → file-swap → reopen. In #626, it was changed to use GRDB's backup API (pool-to-pool copy). The backup API approach is better (no file-level race conditions), but the PR description for #618 still describes the old file-swap approach. This documentation mismatch could confuse future maintainers.

### 8. Inactive conversation reactivation relies solely on message receipt

Conversations are reactivated when a message arrives (`StreamProcessor.processMessage` and `processConversation`). But what if:
- The conversation has no new messages after restore (both parties are idle)?
- The user opens the conversation but no messages arrive?

The conversation stays in "Awaiting reconnection" indefinitely. There's no polling fallback or manual "retry" button for the user (the banner links to learn.convos.org but doesn't offer a retry action).

**Recommendation:** Consider a periodic check (e.g., on conversation open or on a timer) that calls `isActive()` on the XMTP conversation, or offer a manual "Check connection" action. PR #626 notes that `isActive()` returns stale results after `importArchive`, but this may resolve after the first sync.

### 9. `broadcastKeysToVault()` is non-fatal during backup

`BackupManager.createBundleData()` calls `archiveProvider.broadcastKeysToVault()` and logs a warning if it fails, then continues with the backup. This means a backup could be created without the latest conversation keys in the vault archive. If a new conversation was created since the last successful broadcast, its keys won't be in the backup.

This is a correctness risk: the backup bundle will contain the conversation's XMTP archive but not its keys in the vault archive, making that conversation unrestorable.

### 10. No backup size limits or disk space checks

`BackupManager` doesn't check available disk space before creating the bundle. For a user with hundreds of conversations, the staging directory + encrypted bundle could consume significant space. The backup is also written entirely to memory (`Data`) before being written to disk, which could cause OOM for very large backups.

---

## Code Quality Assessment

### Strengths
- Clean protocol-based dependency injection (`BackupArchiveProvider`, `RestoreArchiveImporter`, `VaultArchiveImporter`, `RestoreLifecycleControlling`)
- Proper use of Swift actors for thread safety (`BackupManager`, `RestoreManager`, `ICloudIdentityStore`)
- Comprehensive logging throughout backup/restore flows
- Defensive error handling with non-fatal fallbacks for per-conversation operations
- Well-structured PR stack — each PR has a clear purpose and builds cleanly on the previous

### Areas for improvement
- Some files are quite long (`KeychainIdentityStore` at 654 lines) — could benefit from extraction
- The debug views (`VaultKeySyncDebugView`, `BackupDebugView`) contain production-impacting code (they directly invoke backup/restore operations) — consider separating debug actions from debug display
- `ConvosBackupArchiveProvider.broadcastKeysToVault()` does a force-cast to `VaultManager` — should use protocol method instead
- The `isReconnection` flag on `DBMessage.Update` uses backward-compatible decoding (defaults to `false`) but the field was added mid-stack, meaning older messages in existing databases won't have it — this is handled correctly but adds schema complexity

### Test gaps
- No integration test verifying actual iCloud Keychain query attributes
- No test for the "backup without vault key broadcast" scenario (concern #9)
- No test for offline restore behavior (concern #5)
- No stress test for large conversation counts
- Inactive conversation reactivation is tested via mock but not via actual XMTP message flow

---

## Overall Assessment

This is a well-architected backup system with good separation of concerns and defensive error handling. The vault-centric approach is the right design choice for Convos's per-conversation identity model.

The most significant issues are:
1. **The iCloud sync fix (#626)** — a fundamental bug that invalidated earlier testing
2. **The destructive wipe before restore** — risk of total data loss if restore fails mid-way
3. **Network dependency during restore** — `Client.create()` prevents offline restore

The code quality is generally high, with proper protocol abstractions, comprehensive logging, and good test coverage. The main recommendation is to add integration tests for the keychain layer and to make the restore flow more resilient to partial failures.

### Suggested priority for follow-ups
1. **High:** Make restore wipe reversible (archive old state instead of deleting)
2. **High:** Derive backup encryption key via HKDF instead of using raw `databaseKey`
3. **Medium:** Add periodic reactivation check for inactive conversations
4. **Medium:** Add iCloud Keychain integration tests
5. **Low:** Add disk space pre-check before backup creation
6. **Low:** Add version header to custom tar format
