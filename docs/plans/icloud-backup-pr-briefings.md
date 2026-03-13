# iCloud Backup — PR Briefings

Stack: `dev → jarod/convos-vault-impl → louis/icloud-backup (plan) → vault-key-sync → ...`

Plan: `docs/plans/icloud-backup.md`

Previous implementation (reverted, use as reference):
- Branch: `louis/icloud-keychain-sync`
- `74ad2657` — Refactor KeychainIdentityStore: configurable service/accessibility, remove SecAccessControl
- `9ccfed5e` — Add ICloudIdentityStore: dual-write coordinator with iCloud sync
- `addac09f` — Wire ICloudIdentityStore into app launch
- `232f228d` — Add tests for ICloudIdentityStore, sync, and local format migration
- `b50081f6` — Address code review: fix migration safety, merge loadAll, log delete failures

---

## PR 1: Vault key iCloud sync (`vault-key-sync`)

**Goal**: sync the vault's private key to iCloud Keychain so it survives device loss. This is the foundation — without this key, nothing else can be decrypted on restore.

**What to build**:

1. **Refactor `KeychainIdentityStore`** to accept `accessibility` parameter (in addition to `service` which Jarod already added):
   - Add `accessibility: CFString` parameter (default: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
   - Remove `SecAccessControl` usage, replace with plain `kSecAttrAccessible`
   - Add `migrateToPlainAccessibilityIfNeeded()` static method with `NSLock` concurrency guard
   - Migration uses add-first-then-delete pattern (no data loss window — see `b50081f6`)
   - Reference: `74ad2657`, `b50081f6`

2. **Port `ICloudIdentityStore`** (dual-write coordinator):
   - Wraps two `KeychainIdentityStoreProtocol` instances: local (`ThisDeviceOnly`) + iCloud (`AfterFirstUnlock`)
   - save → write to both (iCloud failure non-fatal, log warning)
   - identity(for:) → local first, iCloud fallback, cache locally on fallback
   - loadAll() → merge both stores, deduplicate by inboxId (see `b50081f6`)
   - delete → remove from both (log warning on iCloud failure)
   - `syncLocalKeysToICloud()` — repeatable, runs every launch, copies missing keys to iCloud
   - `deleteICloudCopy()` / `deleteAllICloudCopies()` — for future backup disable
   - `hasICloudOnlyKeys()` — detects restore scenario
   - `isICloudAvailable` — checks `ubiquityIdentityToken`
   - Reference: `9ccfed5e`, `b50081f6`

3. **Wire to `VaultKeyStore`**:
   - In `ConvosClient+App.swift`, Jarod creates `VaultKeyStore(store: vaultKeychainStore)` where `vaultKeychainStore` is a `KeychainIdentityStore` with service `"org.convos.vault-identity"`
   - Replace that with `ICloudIdentityStore` wrapping two `KeychainIdentityStore` instances:
     - Local: service `"org.convos.vault-identity"`, accessibility `ThisDeviceOnly`
     - iCloud: service `"org.convos.vault-identity.icloud"`, accessibility `AfterFirstUnlock`
   - Run `syncLocalKeysToICloud()` on launch (fire-and-forget Task)
   - Run `migrateToPlainAccessibilityIfNeeded()` before creating stores
   - Conversation keys stay in the regular `KeychainIdentityStore` (unchanged) — vault messages are the source of truth for those

4. **Tests** (target: 30+):
   - `KeychainIdentityStore`: save/load/delete, concurrent operations, edge cases, coding, format migration (SecAccessControl → plain), migration idempotency
   - `ICloudIdentityStore`: dual-write, local preference, iCloud fallback, fallback caching, loadAll merge + dedup, delete from both, delete iCloud only, hasICloudOnlyKeys
   - Sync: copies missing keys, skips already synced, idempotent, re-sync after iCloud copies deleted, empty local store
   - iCloud availability detection
   - Reference: `232f228d`

**Key files**:
- `ConvosCore/Sources/ConvosCore/Auth/Keychain/KeychainIdentityStore.swift` — refactor
- `ConvosCore/Sources/ConvosCore/Auth/Keychain/ICloudIdentityStore.swift` — new
- `ConvosCore/Sources/ConvosCore/ConvosClient+App.swift` — wire up
- `ConvosCore/Sources/ConvosCore/Auth/Keychain/VaultKeyStore.swift` — may need to accept `ICloudIdentityStore`
- `KeychainIdentityStoreTests/KeychainIdentityStoreTests.swift` — tests

**Vault branch context**:
- `VaultKeyStore` wraps any `KeychainIdentityStoreProtocol` — our `ICloudIdentityStore` conforms to this
- `VaultManager` receives `identityStore` (for conversation keys) and `vaultKeyStore` (for the vault key) — we only change how `vaultKeyStore` is constructed
- `ConvosClient+App.swift` is where both stores are created and injected

---

## PR 2: Installation revocation on inbox ready

**Goal**: when an inbox becomes ready (after authorize), revoke all previous installations. Single-device model — only the current installation should be valid.

**What to build**:

1. **Add `revokeAllOtherInstallations` to `XMTPClientProvider` protocol**:
   - Already available on `XMTPiOS.Client` as `revokeAllOtherInstallations(signingKey:)`
   - The protocol already has `revokeInstallations(signingKey:installationIds:)` — add the simpler API
   - Implement in the concrete XMTP client wrapper

2. **Call revocation in `InboxStateMachine`**:
   - When inbox transitions to ready state, call `revokeAllOtherInstallations`
   - If revocation fails, log warning and continue (don't block messaging)
   - Consider: should this run on every ready transition, or only on first ready after restore?

3. **Add `installationId` column to `DBInbox`**:
   - New GRDB migration in `SharedDatabaseMigrator.swift`
   - Store the installation ID when inbox becomes ready
   - Useful for diagnostics and future multi-device
   - Note: Jarod already added `isVault` and `sharedToVault` columns — add migration after his

4. **Tests**:
   - Revocation called on ready transition
   - Revocation failure doesn't block inbox
   - Installation ID persisted to DB
   - Mock `XMTPClientProvider` with revocation tracking

**Key files**:
- `ConvosCore/Sources/ConvosCore/Messaging/XMTPClientProvider.swift` — protocol addition
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` — call revocation
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBInbox.swift` — new column
- `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift` — migration
- XMTP SDK reference: `Client.revokeAllOtherInstallations(signingKey:)`, `Client.inboxState(refreshFromNetwork:).installations`

---

## PR 3: Backup bundle creation

**Goal**: create an encrypted backup bundle containing vault archive + per-conversation XMTP archives + GRDB database. Write to iCloud Drive.

**What to build**:

1. **Backup bundle orchestrator** (`BackupManager` or similar):
   - `createBackup() async throws -> URL` — creates the full bundle
   - Steps:
     a. Call `VaultManager.createArchive(at:encryptionKey:)` → vault XMTP archive
     b. For each conversation inbox, call `XMTPiOS.Client.createArchive()` → conversation archives
     c. Copy GRDB database
     d. Write `metadata.json` (bundle version, device name, model, timestamp)
     e. Package all into a single encrypted bundle (encrypt with vault private key's `databaseKey`)
   - Handle errors per-conversation (one failed archive shouldn't block the whole backup)

2. **iCloud Drive integration**:
   - Write bundle to: `iCloud Drive/Convos/backups/<device-uuid>/backup-latest.encrypted`
   - Use `FileManager.url(forUbiquityContainerIdentifier:)` for iCloud container
   - Write metadata.json alongside the bundle

3. **Per-conversation archive creation**:
   - Need to iterate all active inboxes and create XMTP archives
   - `XMTPiOS.Client.createArchive(path:encryptionKey:opts:)` — already available in SDK
   - Use the conversation's own `databaseKey` as encryption key
   - Store archive paths in a temp directory, then bundle them

4. **Tests**:
   - Bundle creation with mock vault manager and mock XMTP clients
   - Metadata generation (version, device info, timestamp)
   - Error handling: single conversation archive failure doesn't fail whole backup
   - Bundle structure validation
   - iCloud Drive path generation

**Key files**:
- New: `ConvosCore/Sources/ConvosCore/Backup/BackupManager.swift` (or similar)
- New: `ConvosCore/Sources/ConvosCore/Backup/BackupBundle.swift` — bundle structure/metadata
- `ConvosCore/Sources/ConvosCore/Vault/VaultManager+Archive.swift` — Jarod's API (already exists)
- `ConvosCore/Sources/ConvosCore/Messaging/XMTPClientProvider.swift` — may need `createArchive` on protocol

**Open questions to resolve before this PR**:
- Bundle encryption: AES-256-GCM with vault `databaseKey`? Or generate a separate backup key?
- XMTP archive API: does `createArchive` work on inactive clients? Or do we need clients to be awake?
- iCloud container identifier: what's ours?

---

## PR 4: Restore flow

**Goal**: decrypt a backup bundle, import vault archive to extract keys, restore GRDB, import conversation archives, revoke old installations.

**What to build**:

1. **Restore orchestrator**:
   - `restoreFromBackup(bundlePath: URL) async throws`
   - Steps:
     a. Get vault key from `ICloudIdentityStore` (iCloud fallback)
     b. Decrypt backup bundle with vault key
     c. Call `VaultManager.importArchive(from:encryptionKey:)` → returns `[VaultKeyEntry]`
     d. Save each `VaultKeyEntry` to local keychain via identity store
     e. Replace local GRDB database with backup copy
     f. Import per-conversation XMTP archives
     g. For each inbox: create XMTP client → `revokeAllOtherInstallations` → sync
     h. Clean up expired exploding conversations

2. **Restore detection**:
   - On launch, check `ICloudIdentityStore.hasICloudOnlyKeys()` — if true, vault key exists in iCloud but not locally (restore scenario)
   - Check iCloud Drive for backup bundles
   - Surface restore option (this PR provides the detection logic; UI comes in PR 6)

3. **GRDB database replacement**:
   - Close current database connections
   - Replace database file with backup copy
   - Re-open connections
   - Run any pending migrations (backup may be from older app version)

4. **Tests**:
   - Full restore flow with mock data
   - VaultKeyEntry → keychain save
   - Restore detection logic
   - Database replacement
   - Expired conversation cleanup
   - Error handling: partial restore recovery

**Key files**:
- New: `ConvosCore/Sources/ConvosCore/Backup/RestoreManager.swift`
- `ConvosCore/Sources/ConvosCore/Vault/VaultManager+Archive.swift` — `importArchive` returns `[VaultKeyEntry]`
- `ConvosCore/Sources/ConvosCore/Vault/VaultKeyEntry.swift` — key entry model
- `ConvosCore/Sources/ConvosCore/Auth/Keychain/ICloudIdentityStore.swift` — `hasICloudOnlyKeys()`

---

## PR 5: Backup scheduling

**Goal**: automatic periodic backups using `BGProcessingTask`.

**What to build**:

1. **Background task registration**:
   - Register `BGProcessingTask` with identifier (e.g., `org.convos.backup`)
   - Schedule based on user preference: daily (default) or weekly
   - Requires `BGTaskSchedulerPermittedIdentifiers` in Info.plist

2. **Scheduling logic**:
   - Track last backup timestamp (in GRDB or UserDefaults)
   - On app launch / foreground, check if backup is due
   - Schedule next background task
   - Handle: app killed before backup completes, retry on next launch

3. **Backup frequency configuration**:
   - Model: `BackupFrequency` enum (daily, weekly)
   - Store in GRDB (after UserDefaults migration) or UserDefaults for now
   - Default: daily

4. **Tests**:
   - Scheduling logic (due date calculation)
   - Frequency change updates schedule
   - Last backup timestamp tracking

**Key files**:
- New: `ConvosCore/Sources/ConvosCore/Backup/BackupScheduler.swift`
- `Info.plist` — task identifier
- `ConvosApp.swift` or `AppDelegate` — task registration

---

## PR 6: Settings UI

**Goal**: backup settings in the app: toggle, frequency, manual trigger, last backup, restore option.

**What to build**:

1. **Backup settings view**:
   - Toggle: "Back up conversations" (default on)
   - Frequency picker: daily / weekly
   - "Back up now" button with progress
   - "Last backup: [timestamp]" label
   - "Restore from backup" (visible when vault key detected in iCloud + backup exists)

2. **Restore confirmation flow**:
   - "This will replace all current conversations and data"
   - Progress indicator during restore
   - Restore summary: conversations restored count

3. **iCloud status warning**:
   - If `ICloudIdentityStore.isICloudAvailable == false`, show warning banner
   - "Sign in to iCloud to enable backups"

4. **ViewModel**:
   - `BackupSettingsViewModel` — drives the UI
   - Calls `BackupManager.createBackup()` for manual trigger
   - Calls `RestoreManager.restoreFromBackup()` for restore
   - Observes backup state (idle, backing up, restoring, error)

5. **Tests**:
   - ViewModel state transitions
   - Toggle behavior (enable/disable calls appropriate methods)
   - Restore confirmation flow

**Key files**:
- New: `Convos/Settings/BackupSettingsView.swift`
- New: `Convos/Settings/BackupSettingsViewModel.swift`
- Existing settings navigation — add "Backups" row
