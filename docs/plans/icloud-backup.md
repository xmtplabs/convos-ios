# iCloud Backup Plan for Convos

## Purpose
Ship a near-term backup + restore solution for "my phone is in the river" without blocking on full multi-device architecture.

This plan is intentionally split into two tracks:
- identity continuity (keys / inbox access / resume conversations)
- history continuity (message archive restore)

The product priority is **resume first, history second**.

---

## Updated framing (from team discussion)

### What we are solving now
1. User loses device
2. User installs Convos on new iPhone
3. User can recover identities (per-conversation keys)
4. User can be re-added / resume sending and receiving
5. Optional: user restores old message history

### What we are not solving yet
- Full simultaneous multi-device UX (phone + iPad + desktop all active and coherent)
- Cross-platform key portability (iOS -> Android) as an MVP requirement
- Full preferences sync (mute, read state, local UI state)

### Core product principle
A short-term backup solution must not block the long-term vision:
- per-conversation portability
- selective sync/backup at conversation granularity
- eventual multi-platform support

---

## Current state (codebase)

- Per-conversation identity model (ADR 002): one XMTP inbox per conversation
- Keychain identity currently stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- No cloud key backup
- `deviceSyncEnabled: false`
- No message archive backup job

Consequence: if keychain is lost, user loses ability to resume conversations.

---

## Decisions and recommendations

## Decision A: Ship key backup first (MVP)
Reason: no point restoring history if user cannot resume conversations.

## Decision B: Keep message archive as Phase 2
Reason: archive restore is useful, but less critical than identity recovery.

## Decision C: Treat multi-device as a separate project
Reason: backup/restore and multi-device share foundations, but UX + state sync + push behavior makes full multi-device materially larger.

## Decision D: Start app-level, keep path open to per-conversation controls
Recommendation:
- MVP controls at app level (simple UX)
- data model and APIs should support future per-conversation backup/sync toggles

Comment: this keeps Shane's conversation-level vision alive without blocking immediate release.

---

## Phase 1 — Identity backup to iCloud Keychain (MVP)

### Scope
Back up per-conversation identity material via iCloud-synced Keychain entries.

### Implementation approach
- Move keychain accessibility from `...ThisDeviceOnly` to `kSecAttrAccessibleAfterFirstUnlock`
- Migrate existing keychain items by read -> insert new attributes -> delete old item
- Add app setting: "Back up conversation keys" (default ON, user can disable)
- New-device restore flow: detect synced identities and ask user to restore

### UX behavior (proposed)
- On first launch with synced keys found:
  - Show restore prompt with plain language:
    - "Restore access to your conversations"
    - "Message history may be incomplete until contacts/devices re-add this installation"
- Do not silently auto-activate all conversations in background
- Warn if old device may still be active (temporary dual-installation state)

### Security notes
- iCloud Keychain is encrypted and practical for MVP
- This is still tied to Apple account compromise risk
- Future hardening option: user-known secret (PIN/passphrase) for wrapping backup keys

### Explode interaction
Required behavior:
- explode must delete local keychain item and synced keychain item
- clarify product promise: backups may be briefly recoverable during sync windows

---

## Phase 2 — Message archive backup (XMTP archive files)

### Scope
Use XMTP archive APIs for optional history restore.

### Expected XMTP behavior
- `createArchive` per client/inbox
- encrypted file output
- additive import with de-duplication
- restored conversations can be inactive/read-only until reactivation

### Convos-specific implications
Because Convos uses one client per conversation:
- archive generation is per conversation
- potentially many small files
- need robust folder strategy + metadata index

### Storage proposal (MVP)
- Archive files: iCloud Drive app container (simple to ship)
- Archive encryption key: iCloud Keychain

### Backup cadence proposal
Start with **daily + app background trigger**, with manual "Back up now" action.

Comment: aligns with World/WhatsApp-style expectations and limits performance cost.

### Disappearing messages
Default: exclude disappearing messages from archives.

---

## Phase 3 — Multi-device (future)

Out of MVP scope. Includes:
- Device sync enabled across all per-conversation inboxes
- Push routing and installation lifecycle on multiple active devices
- Cross-device preference sync strategy (mute/read/local state)
- Performance and memory controls for large conversation/device matrices

---

## Open questions (updated)

## Product / UX
1. Should key backup be default ON for all users, or gated behind onboarding consent?
2. For restore, do we offer:
   - "Restore all conversations" first, then per-conversation refinement later?
   - or immediate per-conversation selection in MVP?
3. What exact user promise do we make for explode when backups are enabled?

## Security
4. Is iCloud Keychain-only acceptable for MVP threat model?
5. Do we need optional user PIN/passphrase in v1 or v1.1?
6. What minimum messaging do we need for privacy-sensitive users opting out?

## Architecture
7. How do we prevent confusing dual-installation states during restore window?
8. What telemetry do we need to detect restore success/failure and churn?
9. Should backup capability be modeled per conversation now (even if hidden in UI)?

## Turnkey
10. Is Turnkey import/export viable at per-conversation scale without unacceptable UX friction/cost?
11. If not viable now, what abstraction should we keep so storage backend can change later?

---

## Suggested technical work breakdown

1. **Identity backup spike (2-3 days)**
   - keychain attribute migration prototype
   - verify cross-device sync in real iCloud account test
   - verify explode delete propagation

2. **Restore UX prototype (2-3 days)**
   - detection states: no keys / keys found / restore in progress / restore complete
   - copy and user education around resume vs history

3. **Archive spike (2-4 days)**
   - run `createArchive` on per-conversation clients
   - test import behavior and inactive conversation reactivation paths
   - benchmark file count and runtime with high conversation counts

4. **ADR + implementation plan**
   - capture final MVP decisions
   - lock rollout + migration + metrics plan

---

## Success criteria for MVP

- User who loses device can recover conversation identities on new iPhone
- User can resume receiving/sending once conversation membership reactivation occurs
- No irreversible data-loss regressions introduced by keychain migration
- Clear UX around what is restored immediately vs eventually
- Foundation remains compatible with future per-conversation backup/sync controls
