# iCloud Backup Plan for Convos

## TL;DR

- **Installation lifecycle is simple in MVP: revoke all previous installations on restore.**
  - Until multi-device is supported, only one installation per inbox is valid at a time.
  - Restore creates new installations → immediately revoke all others via `revokeAllOtherInstallations`.
- **No full multi-device UX required for MVP.**
  - Two devices with the same Apple ID are treated as separate devices with separate backups.
  - Each device manages its own GRDB database and installation set independently.
- **Backup is an encrypted bundle** containing GRDB database, XMTP archives, media assets, and user preferences — synced to iCloud Drive per-device.
- **Media assets must be included in backups** because remote storage expires after 30 days.

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
- Keychain uses `SecAccessControl` with empty flags (no biometrics), which is functionally equivalent to plain `kSecAttrAccessible` but prevents in-place accessibility updates
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
- iCloud Keychain sync means both devices have the same identity keys.
- Each device creates its own XMTP installations independently.
- When device B restores and revokes all other installations, device A's installations become invalid and device A stops functioning for those conversations.
- This is **acceptable for MVP** — we don't support multi-device yet, and users should not expect simultaneous use on two devices.
- Backups are per-device on iCloud (e.g., "Jarod's iPhone 14 Backup", "Jarod's iPad Backup") to avoid cross-device interference.

---

## Proposed scope decisions (for sign-off)

### Key backup first (MVP)
Reason: no point restoring history if user cannot resume.

### Simple installation cleanup: revoke all others on restore
Reason: single-device model means only one installation is ever valid. No need for age-based or last-seen heuristics.

### Full encrypted backup bundle (Phase 2)
Backup includes everything needed to fully restore the app: GRDB database, XMTP conversation archives, media assets, and user preferences. Media must be included because remote assets expire after 30 days.

### App-level controls first, data model ready for per-conversation controls
Reason: faster to ship now as a first step, keeps path to Shane's convo-level vision.

### Per-device backups on iCloud
Reason: avoids cross-device interference when same Apple ID is used on multiple devices. Same encryption key per device for all its backups.

### Restore is destructive (wipe + replace)
No merging or conflict resolution. Restoring from backup replaces all existing local data with the backup contents. This keeps the implementation simple and avoids an entire class of sync conflicts.

---

## Phase 1: Identity backup + restore + installation lifecycle (MVP)

### 1) Key backup
- Migrate keychain accessibility from `...ThisDeviceOnly` → `kSecAttrAccessibleAfterFirstUnlock`
- Migration requires delete + re-add (current `SecAccessControl` storage prevents in-place `SecItemUpdate` of accessibility level)
- Simplify new saves to use `kSecAttrAccessible` directly instead of `SecAccessControl` (we use empty flags, so `SecAccessControl` provides no benefit — and plain `kSecAttrAccessible` allows future in-place updates)
- Detect if iCloud Keychain sync is disabled and warn the user (keys won't actually sync without it)
- Settings toggle: "Back up conversation keys" (default ON, opt-out allowed)

### 2) Restore UX
- On launch, if synced identities are detected in iCloud Keychain, show explicit restore prompt
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
- Optionally include device name in XMTP installation metadata for future multi-device UI

Implementation details:
- `revokeAllOtherInstallations` is already available on `XMTPiOS.Client`
- Already exposed via `XMTPClientProvider.revokeInstallations` protocol
- Add `revokeAllOtherInstallations` to `XMTPClientProvider` protocol for the simpler API
- Run revocation when inbox transitions to ready state in `InboxStateMachine`
- If revocation fails, log and continue (don't block the user from messaging)

---

## Phase 2 — Encrypted backup bundle

### Prerequisites
- **Migrate QuickName/UserDefaults to GRDB** — user preferences must be in the database to be included in the backup bundle. Good first step that also improves testability.
- **Validate real-world restore matrix** (see below)

### Restore matrix validation
Verify behavior for:
1. **New phone restored from full iCloud device backup**
2. **User deletes and reinstalls app on same phone**
3. **User installs on second device without full-phone migration**

Results determine which scenarios are already handled by Phase 1 (key sync) and which require the full backup bundle.

### Backup bundle contents
The backup is a single encrypted bundle per device, stored in iCloud Drive:

| Component | What's included | Why |
|-----------|----------------|-----|
| GRDB database | All conversations, messages, members, inbox records, user preferences (after UserDefaults migration) | Core app state |
| XMTP conversation archives | Per-conversation XMTP archive (via XMTP archive APIs) | Enables XMTP-level message replay/catch-up |
| Media assets | Photos, videos, attachments (actual blobs, not just references) | Remote storage expires after 30 days |
| Device metadata | Device name, model, backup timestamp | Identify which backup belongs to which device |

**Excluded from backup:**
- Disappearing messages

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

### Incremental backups
To manage storage and bandwidth (media can be large):
- Track which media assets have already been backed up (hash or modification date)
- Only upload new/changed assets on subsequent backups
- GRDB database and XMTP archives are fully replaced each time (they're smaller)
- Consider iCloud storage limits — warn user if approaching quota

### Restore flow
1. User taps "Restore from backup" (or prompted on fresh install with detected backup key)
2. Confirm destructive restore: "This will replace all current conversations and data"
3. Download and decrypt backup bundle from iCloud Drive
4. Replace local GRDB database with backup copy
5. Restore media assets to local storage
6. Restore XMTP conversation archives
7. For each inbox: create new XMTP client → `revokeAllOtherInstallations` → sync
8. **Message catch-up**: XMTP clients sync messages that arrived between backup and restore (messages sent to the group after the backup should be replayed via XMTP's sync process — needs validation)
9. Show restore summary: conversations restored, messages caught up

### Per-device backup organization
```
iCloud Drive/
  Convos/
    backups/
      <device-uuid>/
        metadata.json          # device name, model, last backup date
        backup-latest.encrypted # the encrypted bundle
```

---

## Phase 3 — Full multi-device experience (future)

Out of MVP scope. When we get here:
- Device sync and coherent cross-device behavior for preferences/read/mute
- Push and installation orchestration across many active devices
- Performance strategy for (conversations × devices)
- Installation metadata with device name for user-facing device management UI
- Transition from "revoke all others" to selective revocation with user choice
- Per-device backup differentiation (already prepared in Phase 1/2)

---

## Open questions (updated)

### Resolved
- ~~Revocation policy~~ → Revoke all other installations on restore (single-device model)
- ~~Source of truth for installation enumeration~~ → Not needed; `revokeAllOtherInstallations` handles it
- ~~UX if cap reached~~ → Won't happen; we revoke all others immediately
- ~~Server-assisted "last seen" signal~~ → Not needed for MVP
- ~~Media in backups~~ → Yes, must include actual blobs (30-day remote expiry)
- ~~Restore strategy~~ → Destructive: wipe + replace, no merge

### Installation lifecycle
1. Installation cap is currently 10; confirm exact failure mode at cap (error surface, timing, and recovery path) — still useful to document even though we prevent it.
2. If `revokeAllOtherInstallations` fails (network error, signing error), what's the retry strategy? Background retry on next inbox wake?

### Backup
3. After running restore matrix tests, which scenarios remain unsolved without the full backup bundle?
4. Is app-delete/reinstall recovery a must-have in MVP or acceptable in Phase 2?
5. **Message catch-up after restore**: do XMTP clients automatically replay messages sent between backup and restore when they sync? Need to validate this behavior.
6. **iCloud storage limits**: what's a reasonable backup size estimate (GRDB + media for a typical user)? Do we need to warn about iCloud quota?
7. **Incremental backup strategy**: track by content hash, file modification date, or database row ID?
8. **Photos/media format**: do we back up original encrypted blobs, or decrypt-then-re-encrypt with backup key? (Original blobs are simpler but require the per-conversation XMTP keys to decrypt on restore.)

### Security
9. Is iCloud Keychain-only acceptable for MVP threat model?
10. Do we require an optional PIN/passphrase in the first post-MVP release?

### Product direction
11. When to expose per-conversation backup/sync controls vs app-level default?
12. Turnkey viability for future backend abstraction (import/export UX and cost constraints), export and share conversations to other platforms like Convos Web and Convos Android.

### Prerequisites
13. **QuickName/UserDefaults → GRDB migration**: scope and timeline? This is a prerequisite for comprehensive backups.
14. **iCloud Keychain sync detection**: can we reliably detect if the user has iCloud Keychain disabled? (`SecKeychain` API or checking for known synced item?)

### Multi-device preparation
15. Should installation metadata include device name now (cheap to add, useful later)?
16. Per-device backup naming convention — use device name, device model, or UUID?

---

## Immediate next steps

1. **Implement installation revocation on inbox ready (Phase 1)**
   - Add `revokeAllOtherInstallations` to `XMTPClientProvider` protocol
   - Call after inbox reaches ready state
   - Add `installationId` column to inbox table
   - Track current installation ID per inbox

2. **Implement keychain migration (Phase 1)**
   - Migrate from `SecAccessControl` + `ThisDeviceOnly` to plain `kSecAttrAccessible` + `AfterFirstUnlock`
   - Delete + re-add for existing items (in-place update not possible with current `SecAccessControl` storage)
   - Simplify new saves to use `kSecAttrAccessible` directly
   - Add iCloud Keychain sync detection + user warning

3. **Run restore behavior matrix (Phase 1/2 boundary)**
   - Full-phone restore vs app reinstall vs second-device install
   - Document exactly what messages/data survive in each path
   - Validate XMTP message catch-up behavior after restore

4. **Migrate QuickName/UserDefaults to GRDB (Phase 2 prerequisite)**
   - Move user preferences into the database so they're included in backups

5. **Write ADR update**
   - Capture installation lifecycle decision (revoke-all-others), keychain migration approach, and backup bundle architecture

---

## MVP success criteria

- User who loses device can recover identities and resume conversations on new iPhone
- All previous installations are revoked on restore (no stale installation accumulation)
- Installation cap is never reached (revoke-all-others guarantees at most 1 installation per inbox)
- Two devices with same Apple ID: second device works, first device becomes non-functional (acceptable pre-multi-device)
- User is warned if iCloud Keychain sync is disabled
- Product messaging is clear on what is restored now vs later
- Architecture stays compatible with future per-conversation backup/sync controls and multi-device

## Phase 2 success criteria

- User can fully restore app state (conversations, messages, media, preferences) from iCloud backup
- Media assets survive beyond the 30-day remote storage expiry
- Backup runs automatically on configured schedule with manual trigger option
- Settings UI shows backup status, last backup date, and restore option
- Restore is clean and deterministic (destructive replace, no merge conflicts)
- Messages sent between backup and restore are caught up via XMTP sync
