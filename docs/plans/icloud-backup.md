# iCloud Backup Plan for Convos

## TL;DR

- **Keys stored in two locations**: local (`ThisDeviceOnly`, never deleted) + iCloud copy (`AfterFirstUnlock`, syncable). On save, write to both. On read, prefer local; fall back to iCloud copy on a restored device.
- **Installation lifecycle is simple in MVP: revoke all previous installations on restore.** Until multi-device is supported, only one installation per inbox is valid at a time.
- **No media in backup v1.** Media older than 30 days is lost on restore. Users can save individual photos. Revisit in a versioned v2 bundle.
- **Phase 3 is Convos Vault** — Jarod's Device Pool design using a hidden XMTP group for multi-device key sync. Confirmed by XMTP eng (Ry) that XMTP's built-in device sync can't extend to multi-convo; side-channel approach is correct.

---

## Purpose
Ship a near-term backup + restore solution for "my phone is in the river" without blocking on full multi-device architecture.

Product priority:
1. **Resume conversations** (keys/identity continuity)
2. **Restore history** (archive continuity) where needed

---

## Current state

- Per-conversation identity model (ADR 002): one XMTP inbox per conversation
- Keychain identity stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not iCloud-synced)
- QuickName and some user preferences stored in UserDefaults (not included in any backup path)
- `deviceSyncEnabled: false`
- No explicit archive backup job
- App data may be present in iOS device backups, but keys are not recoverable if keychain item remains `ThisDeviceOnly`
- Remote media assets (photos, attachments) expire after 30 days on storage server

Consequence today: user may see old local message data after certain restore paths, but still cannot reliably resume messaging without keys. Media older than 30 days is unrecoverable.

---

## Clarifying "multi-device required or not?"

### Required now (MVP)
**Installation lifecycle management is required, but the policy is simple: revoke all previous installations on restore.**

We only ever need one installation per inbox until we support multi-device. After any restore or new install, the new device's installation is the only valid one. Previous installations from the old device are immediately revoked.

### Not required now
**Polished simultaneous multi-device product** (consistent preferences, read state, mute state, etc.) can remain out of scope.

### Same Apple ID on multiple devices (pre-multi-device)

If someone opens Convos on two devices with the same Apple ID before multi-device is supported:

- Each device loads inboxes/conversations based on its **local GRDB database**, not keychain contents.
- iCloud Keychain sync means both devices have the same identity keys (via the iCloud copy).
- Each device creates its own XMTP installations independently.
- When device B restores and revokes all other installations, device A's installations become invalid and device A stops functioning for those conversations.
- This is **acceptable for MVP** — we don't support multi-device yet, and users should not expect simultaneous use on two devices.
- Backups are per-device on iCloud (e.g., "iPhone 14 Backup", "iPad Backup") to avoid cross-device interference.

---

## Proposed scope decisions (for sign-off)

### Key backup first (MVP)
Reason: no point restoring history if user cannot resume.

### Two-location key storage
Store keys in both a local `ThisDeviceOnly` service and an iCloud-syncable `AfterFirstUnlock` service. Local copy is never deleted (safety net). iCloud copy is managed based on backup settings. This enables:
- Per-conversation backup control later (some keys synced, some not)
- Clean disable: turning off backup just deletes iCloud copies
- No repeated migrations when toggling backup on/off

### Simple installation cleanup: revoke all others on restore
Reason: single-device model means only one installation is ever valid. No need for age-based or last-seen heuristics.

### No media in backup v1
Team decision: media is not included in the first version of backups. Messages that reference expired assets (>30 days) will not have images on restore. Users can save individual photos/videos. This dramatically simplifies the backup system. A versioned v2 bundle format can add media later (with user toggles for photos/videos, storage quota awareness).

### App-level controls first, data model ready for per-conversation controls
Reason: faster to ship now as a first step, keeps path to convo-level vision.

### Per-device backups on iCloud
Reason: avoids cross-device interference when same Apple ID is used on multiple devices. Same encryption key per device for all its backups.

### Restore is destructive (wipe + replace)
No merging or conflict resolution. Restoring from backup replaces all existing local data with the backup contents. This keeps the implementation simple and avoids an entire class of sync conflicts.

### Version the backup bundle
Include a version number in the bundle format so future versions (e.g., v2 with media) can coexist. Older app versions can read v1 bundles; newer versions read both.

---

## Phase 1: Identity backup + restore + installation lifecycle (MVP)

### 1) Two-location key storage
Store identity keys in two separate keychain services:

| Location | Service name | Accessibility | Purpose |
|----------|-------------|---------------|---------|
| Local (primary) | `org.convos.ios.KeychainIdentityStore.v2` | `AfterFirstUnlockThisDeviceOnly` | Always available on this device, never deleted |
| iCloud (backup) | `org.convos.ios.KeychainIdentityStore.v2.icloud` | `AfterFirstUnlock` | Syncs to iCloud Keychain for backup/restore |

**On save**: write to both locations simultaneously.
**On read**: read from local service. If not found (restore scenario), fall back to iCloud service.
**On delete**: delete from both locations.
**On disable backup**: delete from iCloud service only; local copy stays.

**Migration (one-time)**: copy existing keys from the local service to the iCloud service. No deletion of originals. Tracked via UserDefaults flag.

### 2) Restore UX
- On launch, if synced identities are detected in iCloud Keychain (keys exist in iCloud service but not in local service), show explicit restore prompt
- If a backup encryption key is found in keychain but no local data exists, prompt to restore from backup
- "Restore from backup" option available in App Settings when a backup encryption key is detected
- Restore is destructive: wipes all existing local data and replaces with backup contents
- Do not silently auto-activate all conversations in background
- Explain clearly: resume access first, history may vary by restore path

### 3) Installation lifecycle
On inbox ready (after authorize), revoke all previous installations:
- Call `revokeAllOtherInstallations(signingKey:)` on the XMTP client
- This is safe because we're single-device: only the current installation should exist
- Track `installationId` per inbox in GRDB (new column on inbox table) for diagnostics and future multi-device
- Include device model in XMTP installation metadata (not user-set device name, for privacy)

Implementation details:
- `revokeAllOtherInstallations` is already available on `XMTPiOS.Client`
- Already exposed via `XMTPClientProvider.revokeInstallations` protocol
- Add `revokeAllOtherInstallations` to `XMTPClientProvider` protocol for the simpler API
- Run revocation when inbox transitions to ready state in `InboxStateMachine`
- If revocation fails, log and continue (don't block the user from messaging)

### 4) Detect iCloud Keychain status
- Warn user if iCloud Keychain is disabled (keys won't actually sync)
- Settings toggle: "Back up conversation keys" (default ON, opt-out allowed)

---

## Phase 2 — Encrypted backup bundle

### Prerequisites
- **Migrate QuickName/UserDefaults to GRDB** — user preferences must be in the database to be included in the backup bundle
- **Validate real-world restore matrix** (see below)

### Restore matrix validation
Verify behavior for:
1. **New phone restored from full iCloud device backup**
2. **User deletes and reinstalls app on same phone**
3. **User installs on second device without full-phone migration**

Results determine which scenarios are already handled by Phase 1 (key sync) and which require the full backup bundle.

### Backup bundle contents
The backup is a single encrypted bundle per device, stored in iCloud Drive. **No media in v1.**

| Component | What's included | Why |
|-----------|----------------|-----|
| GRDB database | All conversations, messages, members, inbox records, user preferences (after UserDefaults migration) | Core app state |
| XMTP conversation archives | Per-conversation XMTP archive (via XMTP archive APIs) | Enables XMTP-level message replay/catch-up |
| Device metadata | Device name, model, backup timestamp, bundle version | Identify which backup belongs to which device |

**Excluded from backup:**
- Disappearing/exploding messages (if expired at restore time, they are removed during restore)
- Media assets (v1 — revisit in v2 bundle)

### Backup encryption
- A **backup encryption key** is generated per device and stored in iCloud Keychain
- Same key encrypts all backups for that device (no per-backup key rotation needed for MVP)
- The key syncs via iCloud Keychain — if the key is present on a new device, it can decrypt that device's backups

### Backup scheduling and UI
- **App Settings**: "Backups" section with:
  - Toggle: "Back up conversations" (default ON)
  - Frequency picker: daily, weekly (default: daily)
  - "Back up now" manual trigger
  - "Last backup": timestamp of most recent successful backup
  - "Restore from backup" (visible when backup encryption key detected in keychain)
- **Background task**: runs at configured frequency using `BGProcessingTask`
- **Manual trigger**: immediate backup from Settings

### Restore flow
1. User taps "Restore from backup" (or prompted on fresh install with detected backup key)
2. Confirm destructive restore: "This will replace all current conversations and data"
3. Download and decrypt backup bundle from iCloud Drive
4. Replace local GRDB database with backup copy
5. Restore XMTP conversation archives
6. For each inbox: create new XMTP client → `revokeAllOtherInstallations` → sync
7. **Message catch-up**: XMTP clients sync messages that arrived between backup and restore
8. **Exploding conversations**: check for expired conversations and remove them during restore
9. Show restore summary: conversations restored, messages caught up

### Per-device backup organization
```
iCloud Drive/
  Convos/
    backups/
      <device-uuid>/
        metadata.json          # device name, model, last backup date, bundle version
        backup-latest.encrypted # the encrypted bundle (v1: no media)
```

---

## Phase 3 — Convos Vault (multi-device key sync)

> See [Convos Vault plan](convos-vault.md) for full design. Jarod has a working implementation branch: `jarod/convos-vault-core-integration`.
> XMTP eng (Ry) confirmed: XMTP's built-in device sync only works within a single inbox's installations. Our per-conversation model requires a side-channel approach — the Vault.

The Vault is a hidden XMTP group conversation that syncs private keys between a user's devices:

- **Architecture**: standard XMTP group with `conversationType: "vault"` metadata, custom content types (`DeviceKeyBundle`, `DeviceKeyShare`, `DeviceRemoved`), locked by default
- **Pairing**: QR code scan + 6-digit confirmation code, reuses existing invite system
- **Key sync**: whenever a device creates/joins a conversation, it sends the key to the Vault; other devices import it
- **Cross-platform**: works on any platform (not tied to iCloud), enabling web and Android support
- **Device management**: Settings → Devices, list linked devices, remove devices (revokes installations)

### Relationship to Phase 1/2

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| Phase 1 | iCloud Keychain (two-location) | "Lost phone" key recovery (Apple ecosystem) |
| Phase 2 | Encrypted backup bundle in iCloud Drive | Full app state restore (DB, archives) |
| Phase 3 | Convos Vault (XMTP group) | Active multi-device key sharing, cross-platform |

These layers are complementary:
- iCloud Keychain is for disaster recovery (phone in the river)
- Vault is for active multi-device use (iPhone + iPad + Mac)
- A user may have both: iCloud backup as safety net + Vault for daily multi-device

### Multi-device implications
- Transition from "revoke all others" (Phase 1) to selective revocation
- Installation metadata includes device identifier for grouping installations by device
- 10-installation limit per inbox — managed via device list UI (remove a device to free slots)
- Mac app possible via Catalyst (iPad app on Mac) — key sharing works via iCloud Keychain or Vault

---

## Open questions

### Resolved
- ~~Revocation policy~~ → Revoke all other installations on restore (single-device model)
- ~~Source of truth for installation enumeration~~ → not needed; `revokeAllOtherInstallations` handles it
- ~~UX if cap reached~~ → won't happen; we revoke all others immediately
- ~~Media in backups~~ → No media in v1. Versioned bundle supports v2 with media later.
- ~~Restore strategy~~ → Destructive: wipe + replace, no merge
- ~~Key storage model~~ → Two locations: local `ThisDeviceOnly` + iCloud `AfterFirstUnlock`
- ~~Multi-device key sync approach~~ → Convos Vault (hidden XMTP group), confirmed viable by XMTP eng

### Installation lifecycle
1. If `revokeAllOtherInstallations` fails (network error, signing error), what's the retry strategy? Background retry on next inbox wake?

### Backup
2. After running restore matrix tests, which scenarios remain unsolved without the full backup bundle?
3. **Message catch-up after restore**: do XMTP clients automatically replay messages sent between backup and restore when they sync?
4. **Incremental backup strategy for v2**: track by content hash, file modification date, or database row ID?

### Security
5. Is iCloud Keychain-only acceptable for MVP threat model?

### Product direction
6. When to expose per-conversation backup/sync controls vs app-level default?
7. Should v2 bundle include photos only, or photos + videos? WhatsApp lets user toggle videos separately.

### Prerequisites
8. **QuickName/UserDefaults → GRDB migration**: scope and timeline? Prerequisite for comprehensive backups.
9. **iCloud Keychain sync detection**: can we reliably detect if the user has iCloud Keychain disabled?

---

## Immediate next steps

1. **Implement two-location key storage (Phase 1)** ← current work
   - Add iCloud keychain service alongside existing local service
   - Dual-write on save, local-first read with iCloud fallback
   - One-time migration: copy existing local keys to iCloud service
   - No deletion of local keys, ever

2. **Implement installation revocation on inbox ready (Phase 1)**
   - Add `revokeAllOtherInstallations` to `XMTPClientProvider` protocol
   - Call after inbox reaches ready state
   - Add `installationId` column to inbox table

3. **Run restore behavior matrix (Phase 1/2 boundary)**
   - Full-phone restore vs app reinstall vs second-device install
   - Document exactly what messages/data survive in each path

4. **Migrate QuickName/UserDefaults to GRDB (Phase 2 prerequisite)**

5. **Implement encrypted backup bundle (Phase 2)**

---

## MVP success criteria

- User who loses device can recover identities and resume conversations on new iPhone
- All previous installations are revoked on restore (no stale installation accumulation)
- Installation cap is never reached (revoke-all-others guarantees at most 1 installation per inbox)
- Two devices with same Apple ID: second device works, first device becomes non-functional (acceptable pre-multi-device)
- User is warned if iCloud Keychain sync is disabled
- Product messaging is clear on what is restored now vs later
- Architecture stays compatible with Convos Vault (Phase 3) and per-conversation backup controls

## Phase 2 success criteria

- User can fully restore app state (conversations, messages, preferences) from iCloud backup
- Backup runs automatically on configured schedule with manual trigger option
- Settings UI shows backup status, last backup date, and restore option
- Restore is clean and deterministic (destructive replace, no merge conflicts)
- Messages sent between backup and restore are caught up via XMTP sync
- Exploding conversations that expired during backup gap are cleaned up on restore
- Bundle is versioned for future v2 (with media)
