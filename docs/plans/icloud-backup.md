# iCloud Backup Plan for Convos

## Current State

Convos uses a **per-conversation identity model** (ADR 002): each conversation gets its own XMTP inbox with unique keys. Today:

- **Keys** (secp256k1 private key + 256-bit DB encryption key) stored in iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, no iCloud sync
- **XMTP device sync disabled** (`deviceSyncEnabled: false`)
- **No backup/export exists** — losing the keychain means permanently losing all conversations
- **No multi-device support** — each conversation lives on exactly one device

Key files:
- `ConvosCore/.../Auth/Keychain/KeychainIdentityStore.swift` — key storage
- `ConvosCore/.../Inboxes/InboxStateMachine.swift:928` — device sync disabled
- `docs/adr/002-per-conversation-identity-model.md` — architecture rationale

---

## Team Decisions (from last week's meeting)

1. **Prioritize key backup first** — laptop-first so users can recover identity on a new device
2. **Chat history backup is optional/secondary** — can be added or enabled later
3. **Backups likely enabled by default** with user-controlled opt-out for privacy-sensitive users
4. **Multi-device is not the immediate goal** — backup/restore is the MVP, not simultaneous multi-device

### Open concerns from the meeting
- iCloud Keychain sync could accidentally create multi-device states (keys on both devices, duplicate installations)
- Push notifications are per-installation — multiple devices with same keys would get notifications independently but wouldn't share mute/settings state
- HistorySync behavior is unclear — is it one-off device-to-device or ongoing sync?
- How to avoid duplicate/inconsistent installations when restoring archives without proper multi-device support

---

## Part 1: Backup Private Keys to iCloud Keychain (MVP)

### What gets backed up
For each conversation, a `KeychainIdentity` contains:
- `inboxId` (XMTP inbox identifier)
- `clientId` (privacy-preserving UUID for push routing)
- `privateKey` (secp256k1 signing key)
- `databaseKey` (256-bit encryption key for XMTP local DB)

### Approach
Change keychain access attribute from `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` to `kSecAttrAccessibleAfterFirstUnlock` (drops `ThisDeviceOnly`). This enables iCloud Keychain sync automatically.

### What this gives us
- Keys survive device loss, factory reset, app deletion
- Keys available on new device signed into same Apple ID
- iCloud Keychain is E2E encrypted — Apple cannot read keys
- No new infrastructure needed

### What this does NOT give us
- Message history (keys alone let you rejoin conversations, but past messages are gone)
- Multi-device simultaneously (keys on both devices could cause confusing states)
- Settings/preferences sync (mute state, notification preferences)

### Risks and complications
- **Accidental multi-device:** If a user has Convos on phone + iPad, both devices would have keys. If both try to build XMTP clients, you get duplicate installations per inbox. Need a strategy:
  - Option A: App detects "another device has these keys" and presents a transfer flow instead of auto-activating
  - Option B: Only activate on explicit user action ("Restore from backup?")
  - Option C: Accept dual-device state and handle it (harder)
- **Explode feature interaction:** Exploding a conversation deletes keys locally, but iCloud Keychain might still have a copy (sync delay). Need to explicitly delete from iCloud too, or accept that exploded conversations could theoretically be recovered from backup.
- **Keychain migration:** Existing users have keys with `ThisDeviceOnly`. Need a migration path to copy keys to the new (syncable) access level. Cannot just update the attribute in-place — must delete and re-add each keychain item.

---

## Part 2: Backup Message Archive to iCloud (Phase 2)

### XMTP Archive API (from docs.xmtp.org)
Three methods:
- **`createArchive(path, encryptionKey, options?)`** — encrypted backup file
- **`archiveMetadata(path, encryptionKey)`** — read backup info before importing
- **`importArchive(path, encryptionKey)`** — restore messages (additive, deduplicates)

Options for `createArchive`:
- Time range: `startNs` / `endNs` (nanoseconds), defaults to all time
- Content types: "Consent" or "Messages", defaults to both
- `excludeDisappearingMessages`: boolean (defaults to false)

### Restore behavior
- All imported conversations start **inactive and read-only**
- Reactivation happens when existing members interact (~up to 30 minutes)
- Attempting to send/sync on inactive conversations throws `Group is inactive`
- Import is additive: preserves existing messages, ignores duplicates

### Convos-specific complications
Since each conversation is a separate XMTP client, we'd need:
- One `createArchive` call **per conversation** (per XMTP client)
- A separate 32-byte encryption key per archive (or one shared key for all)
- Storage for potentially hundreds of small archive files

### Storage options for archive files
| Option | Pros | Cons |
|--------|------|------|
| iCloud Drive (ubiquity container) | Simple, user-visible, iOS-native | User could delete files, visible in Files app |
| CloudKit private database | Not user-visible, more control | More complex, quota limits |
| iCloud key-value store | Simplest API | 1MB total limit — way too small |

### Archive encryption key storage
The 32-byte archive encryption key needs to live somewhere durable:
- iCloud Keychain (alongside identity keys) — simplest, already synced
- Derived from a user passphrase — more secure, but UX friction
- Stored in CloudKit alongside archives — convenient but less secure

---

## The Multi-Device Question (deferred)

### Why it's hard for Convos specifically
Standard XMTP: 1 inbox per user, N devices = N installations of that inbox.
Convos: N inboxes per user (one per conversation). Multi-device = N inboxes x M devices installations.

This means:
- Each conversation's XMTP inbox needs installations on every device
- `deviceSyncEnabled: true` for all inboxes
- Push notification routing to multiple devices per conversation
- Memory/performance scales with conversation count x device count
- Mute/settings state doesn't propagate via XMTP — needs separate sync

### Recommended: defer multi-device, ship backup/restore
The meeting consensus aligns with this. Ship key backup first. When a user gets a new device:
1. Keys sync via iCloud Keychain
2. App detects synced keys, offers "Restore conversations?"
3. Optionally import archives for message history
4. Old device should be decommissioned (or at minimum, app warns about dual-device)

True multi-device (phone + iPad simultaneously) is a separate, larger project.

---

## Questions for Nick (CTO)

### On World's approach
1. How did World handle key backup? iCloud Keychain, seed phrases, server-side escrow, or something else?
2. Did World support multi-device simultaneously, or was it single-device with backup/restore?
3. What was World's HistorySync behavior — one-off device-to-device transfer (requiring old device), or ongoing background sync?
4. What backup frequency/trigger did World use? On-demand, periodic, event-driven?
5. Any pain points or lessons learned from World's backup implementation?

### On Convos-specific concerns
6. **Explode + backup interaction:** If a user explodes a conversation but keys are backed up to iCloud, should we aggressively purge from iCloud too? Or accept that backup weakens the explode guarantee?
7. **Dual-device detection:** If keys sync to a second device, should we block auto-activation and require explicit restore, or try to handle dual-device gracefully?
8. **Keychain migration:** For existing users, migrating from `ThisDeviceOnly` to syncable keychain items requires delete + re-add. Any concerns with this approach?
9. **Users without iCloud:** Do we need a fallback (e.g., encrypted export file via AirDrop/share sheet) for users who don't use iCloud?

### On the XMTP SDK
10. Does `createArchive` work per-client in our per-conversation model, or does it assume a single client with many conversations?
11. Has the XMTP team given guidance on backup with per-conversation identities?
12. What's the current state of HistorySync in the SDK? Is it stable enough to rely on?

---

## Proposed Phases

### Phase 1: Key Backup (MVP)
- Change keychain attribute to enable iCloud Keychain sync
- Migration for existing users (delete + re-add keychain items)
- Add backup opt-out toggle in settings
- On new device: detect synced keys, present restore flow
- Handle explode: explicitly delete from iCloud Keychain on explode
- Handle dual-device: require explicit "Restore" action, don't auto-activate

### Phase 2: Message Archive Backup
- Implement per-conversation `createArchive` using XMTP SDK
- Store archives in iCloud Drive or CloudKit
- Store archive encryption key in iCloud Keychain
- Backup trigger: on app background, periodic, or manual
- Restore flow: import archives after key restore, show inactive state while conversations reactivate

### Phase 3: Multi-Device (future)
- Enable `deviceSyncEnabled: true`
- Push notification routing to multiple devices
- Settings/mute state sync (custom, not via XMTP)
- Memory management for N clients x M devices

---

## Next Steps

1. **Meeting with Nick** — get answers to the questions above
2. **Prototype iCloud Keychain sync** — change the attribute, verify keys sync across devices, test migration path
3. **Spike on XMTP archive APIs** — test `createArchive`/`importArchive` with per-conversation model
4. **Record World's backup flow** — screen recording for reference (action item from meeting)
5. **Design restore UX** — mockups for the new-device restore flow
6. **Write ADR** for the chosen approach before implementation
