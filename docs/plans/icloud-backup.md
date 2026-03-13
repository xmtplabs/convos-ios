# iCloud Backup Plan for Convos

## TL;DR

- **Vault is the single source of truth for conversation keys.** Keys live as messages in the vault group (`DeviceKeyBundle`/`DeviceKeyShare`). No separate per-conversation key backup needed.
- **iCloud Keychain only stores the vault key** (one key, not N). Uses dual-store pattern: local `ThisDeviceOnly` + iCloud `AfterFirstUnlock`.
- **Backup bundle** = vault XMTP archive + per-conversation XMTP archives + GRDB database. Encrypted with vault private key.
- **Restore**: vault key from iCloud Keychain → decrypt bundle → import vault archive → extract conversation keys from vault messages in GRDB → import conversation archives.
- **Disable backups = remove one vault key from iCloud.** Delete a conversation = vault handles it. Single source of truth, no extra cleanup.
- **No media in v1.** Versioned bundle supports v2 with media later.

---

## Why vault-centric?

Two reasons drove the decision to keep keys only in the vault rather than backing them up separately:

1. **Delete/explode consistency**: when a conversation is deleted, the vault is the single source of truth. If keys were also stored in a backup key export, we'd need to clean them up in an extra place.
2. **Disable backups simplicity**: removing backup = delete one vault key from iCloud. Without vault, disabling means removing N keys from iCloud (one per conversation).

---

## Architecture overview

This plan builds on top of `jarod/convos-vault-impl`, which provides:
- `VaultManager.createArchive(at:encryptionKey:)` — creates encrypted vault XMTP archive
- `VaultManager.importArchive(from:encryptionKey:)` — imports archive, returns `[VaultKeyEntry]` with all conversation keys extracted from vault messages
- `VaultKeyStore` — stores the vault's own identity key in a separate keychain service
- Key extraction logic: processes `DeviceKeyBundleContent` and `DeviceKeyShareContent` messages, deduplicates by inboxId

Our work layers on top:
- Sync the vault key to iCloud Keychain (dual-store)
- Create/restore the full backup bundle (vault archive + conversation archives + GRDB)
- Installation lifecycle management
- Backup scheduling and UI

---

## Current state

- Per-conversation identity model (ADR 002): one XMTP inbox per conversation
- Vault implementation in progress (`jarod/convos-vault-impl`): conversation keys shared as vault group messages
- Keychain identity stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not iCloud-synced)
- QuickName and some user preferences stored in UserDefaults
- `deviceSyncEnabled: false`
- No explicit archive backup
- Remote media assets expire after 30 days

---

## Phase 1: Vault key iCloud sync + installation lifecycle

### 1) Dual-store for vault key

Sync the vault key to iCloud Keychain using `ICloudIdentityStore`:

| Location | Service name | Accessibility | Purpose |
|----------|-------------|---------------|---------|
| Local (primary) | `org.convos.vault-identity` | `AfterFirstUnlockThisDeviceOnly` | Always available on this device |
| iCloud (backup) | `org.convos.vault-identity.icloud` | `AfterFirstUnlock` | Syncs to iCloud Keychain for restore |

**On save**: write to both (iCloud failure non-fatal).
**On read**: local first, iCloud fallback (cache locally on fallback).
**On delete**: remove from both.
**On disable backup**: remove iCloud copy only.

`syncLocalKeysToICloud()` runs on every app launch — copies any local-only vault keys to iCloud. Handles the case where iCloud was disabled and re-enabled: items written to the iCloud service with `AfterFirstUnlock` are stored locally regardless and sync automatically when iCloud Keychain is enabled at the system level.

**Status**: `ICloudIdentityStore` is implemented and tested (36 tests). Needs to be wired to the vault key store instead of conversation key stores.

### 2) Installation lifecycle

On inbox ready (after authorize), revoke all previous installations:
- Call `revokeAllOtherInstallations(signingKey:)` on the XMTP client
- Single-device model: only the current installation should exist
- Track `installationId` per inbox in GRDB (new column on inbox table)
- If revocation fails, log and continue

### 3) Detect iCloud status

- `ICloudIdentityStore.isICloudAvailable` checks `ubiquityIdentityToken`
- Warn user if iCloud is unavailable (keys won't sync)

---

## Phase 2: Encrypted backup bundle

### What Jarod provides (vault branch)

```swift
// Create encrypted vault archive
func createArchive(at path: URL, encryptionKey: Data) async throws

// Import vault archive, extract all conversation keys
func importArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry]
```

`VaultKeyEntry` contains: `inboxId`, `clientId`, `conversationId`, `privateKeyData`, `databaseKey`.

After import, conversation keys are extracted by iterating vault messages in GRDB — they're structured `DeviceKeyBundleContent`/`DeviceKeyShareContent` content types, so extraction is just a database query, not message parsing.

### What we build

#### Backup bundle contents

| Component | Source | Purpose |
|-----------|--------|---------|
| Vault XMTP archive | `VaultManager.createArchive()` | Contains all conversation keys as vault messages |
| Per-conversation XMTP archives | `XMTPiOS.Client.createArchive()` per conversation | Conversation message history |
| GRDB database | Local database copy | App state, conversations, members, preferences |
| Bundle metadata | Generated | Device name, model, timestamp, bundle version |

**Excluded**: media assets (v1), disappearing/exploding messages (if expired at restore time).

#### Bundle encryption

The backup bundle is encrypted using the **vault's private key** (`databaseKey` from `VaultKeyStore`). The vault key is the only key that needs to be in iCloud Keychain — it unlocks everything else.

#### Backup flow

1. Create vault archive → `vault-archive.encrypted`
2. Create per-conversation XMTP archives → `conversations/<inboxId>.encrypted`
3. Copy GRDB database → `database.sqlite`
4. Write bundle metadata → `metadata.json` (version, device, timestamp)
5. Package and encrypt with vault key
6. Upload to iCloud Drive

#### Restore flow

1. Vault key restored from iCloud Keychain (via `ICloudIdentityStore` fallback)
2. Download backup bundle from iCloud Drive
3. Decrypt bundle with vault key
4. Import vault archive → `VaultManager.importArchive()` → returns `[VaultKeyEntry]`
5. Save each `VaultKeyEntry` to local keychain via identity store
6. Restore GRDB database
7. Import per-conversation XMTP archives
8. For each inbox: create XMTP client → `revokeAllOtherInstallations` → sync
9. XMTP clients catch up messages sent between backup and restore
10. Clean up expired exploding conversations

#### Per-device backup organization

```
iCloud Drive/
  Convos/
    backups/
      <device-uuid>/
        metadata.json
        backup-latest.encrypted
```

#### Backup scheduling and UI

- **Settings**: "Backups" section
  - Toggle: "Back up conversations" (default on)
  - Frequency: daily / weekly
  - "Back up now" manual trigger
  - "Last backup" timestamp
  - "Restore from backup" (when vault key detected in keychain)
- **Background task**: `BGProcessingTask` on schedule
- **Restore is destructive**: wipe + replace, no merge

### Prerequisites

- Vault implementation ready and reviewed (`jarod/convos-vault-impl`)
- Migrate QuickName/UserDefaults to GRDB (so preferences are in the backup)
- Validate restore matrix (full-phone restore vs reinstall vs second device)

---

## Phase 3: Convos Vault multi-device

> See [Convos Vault plan](convos-vault.md) for full design.

The vault is already the key-sharing mechanism. Phase 3 enables active multi-device use:

- **Pairing**: QR code + 6-digit confirmation, reuses invite system
- **Key sync**: new conversation key → `DeviceKeyShare` message to vault → other devices import
- **Initial sync**: `DeviceKeyBundle` sent at pairing time (no history replay needed)
- **Offline reconnect**: device catches up on missed `DeviceKeyShare` messages via XMTP sync
- **Device management**: Settings → Devices, remove devices (revokes installations)

### Relationship to backup

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| Phase 1 | iCloud Keychain (vault key only) | "Lost phone" vault key recovery |
| Phase 2 | Encrypted backup bundle | Full app state restore |
| Phase 3 | Vault group (XMTP messages) | Active multi-device key sharing |

These are complementary:
- iCloud Keychain is for disaster recovery
- Backup bundle is for full state restore
- Vault is for live multi-device sync
- Single-device user: backup bundle is their safety net
- Multi-device user: other devices can provide keys via vault, but backup bundle is still useful for full state

### Same Apple ID, two devices (pre-multi-device)

- Device B restoring revokes all of Device A's installations → Device A stops functioning
- Acceptable for MVP — multi-device pairing (Phase 3) is the proper solution
- Backups are per-device on iCloud to avoid cross-device interference

---

## Three restore scenarios

1. **New device pairing (Phase 3)**: existing device sends `DeviceKeyBundle` → new device has all keys immediately. No backup needed.
2. **Device offline then reconnects**: catches up on missed `DeviceKeyShare` messages via XMTP message sync. Works as long as another device was active.
3. **All devices lost (Phase 1+2)**: vault key from iCloud Keychain → decrypt backup bundle → import vault archive → extract keys → restore everything. This is the disaster recovery path.

---

## Open questions

### Resolved
- ~~Key storage model~~ → Vault is single source of truth. iCloud Keychain only holds vault key.
- ~~Revocation policy~~ → Revoke all other installations on restore
- ~~Media in backups~~ → No media in v1
- ~~Restore strategy~~ → Destructive: wipe + replace
- ~~Multi-device key sync~~ → Convos Vault
- ~~Per-conversation key backup~~ → Not needed. Vault messages contain all keys. Restoring vault archive = restoring all keys.

### Open
1. If `revokeAllOtherInstallations` fails on restore, retry strategy?
2. Message catch-up after restore: do XMTP clients automatically replay messages sent between backup and restore?
3. Incremental backup strategy for v2?
4. When to expose per-conversation backup controls vs app-level default?
5. Should v2 bundle include photos only, or photos + videos?
6. QuickName/UserDefaults → GRDB migration: scope and timeline?
7. Can we reliably detect if iCloud Keychain specifically is disabled (vs just iCloud account)?

---

## Immediate next steps

1. **Rebase `louis/icloud-keychain-sync` on `jarod/convos-vault-impl`**
   - Wire `ICloudIdentityStore` to vault key store (one key, not N conversation keys)
   - Resolve merge conflicts in `KeychainIdentityStore` (our `accessibility` param vs Jarod's `service` param)

2. **Implement installation revocation on inbox ready**
   - Add `revokeAllOtherInstallations` to `XMTPClientProvider` protocol
   - Call after inbox reaches ready state
   - Add `installationId` column to inbox table

3. **Run restore behavior matrix**
   - Full-phone restore vs app reinstall vs second-device install
   - Determine which scenarios Phase 1 handles vs needing Phase 2

4. **Migrate QuickName/UserDefaults to GRDB** (Phase 2 prerequisite)

5. **Implement backup bundle orchestrator** (Phase 2)
   - Create bundle: vault archive + conversation archives + GRDB + metadata
   - Encrypt with vault key
   - Upload to iCloud Drive
   - Restore flow: decrypt → import vault → extract keys → restore GRDB → import conversation archives

---

## Success criteria

### Phase 1 (MVP)
- Vault key syncs to iCloud Keychain via dual-store
- Restore detects vault key in iCloud and prompts user
- All previous installations revoked on restore
- User warned if iCloud is unavailable

### Phase 2
- Full app state restorable from encrypted backup bundle
- Backup runs on schedule with manual trigger
- Settings UI shows backup status and restore option
- Messages caught up via XMTP sync after restore
- Bundle versioned for future v2 (with media)
