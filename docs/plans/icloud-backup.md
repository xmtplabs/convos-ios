# iCloud Backup Plan for Convos

## TL;DR

- **Yes, installation lifecycle is required in MVP.**
  - Restore creates a new installation.
  - With a per-conversation model, that means one new installation **per restored conversation**.
  - If XMTP installation count is capped (e.g. 10), we need cleanup/revocation for stale installations per conversation.
- **No, full multi-device UX is not required for MVP.**
  - We can ship "recover on a new device" first.
  - But we still must handle temporary multi-installation states safely.
- **Archive backup is not required for the first useful release if iPhone full backup already restores message DB files.**
  - But archive still matters for app-level restore scenarios (delete/reinstall, restore without whole-phone migration, selective export/portability).

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
- `deviceSyncEnabled: false`
- No explicit archive backup job
- App data may be present in iOS device backups, but keys are not recoverable if keychain item remains `ThisDeviceOnly`

Consequence today: user may see old local message data after certain restore paths, but still cannot reliably resume messaging without keys.

---

## Clarifying "multi-device required or not?"

### Required now (MVP)
**Installation lifecycle management is required.**

Even without full multi-device support, restore introduces multi-installation realities:
- new installation IDs are created during restore/new install flows
- old installations may remain active/stale
- installation cap risk must be managed per conversation

### Not required now
**Polished simultaneous multi-device product** (consistent preferences, read state, mute state, etc.) can remain out of scope.

---

## Proposed scope decisions (for sign-off)

### Key backup first (MVP)
Reason: no point restoring history if user cannot resume.

### Add installation cleanup to MVP scope
Reason: restore/new installs create installation growth; cap handling is mandatory.

### Archive is conditional Phase 2 (not automatic)
Reason: if full-device restore already recovers usable history, archive can be deferred.

### App-level controls first, data model ready for per-conversation controls
Reason: faster to ship now as a first step, keeps path to Shane's convo-level vision.

---

## Phase 1: Identity backup + restore + installation lifecycle (MVP)

### 1) Key backup
- Migrate keychain accessibility from `...ThisDeviceOnly` -> `kSecAttrAccessibleAfterFirstUnlock`
- Migration path: read old -> write new -> delete old
- Settings toggle: "Back up conversation keys" (default ON, opt-out allowed)

### 2) Restore UX
- On launch, if synced identities are detected, show explicit restore flow
- Do not silently auto-activate all conversations in background
- Explain clearly: resume access first, history may vary by restore path

### 3) Installation lifecycle (new required MVP work)
Per conversation, after restore:
- detect that a new installation exists
- identify stale/unused installations
- revoke stale installations when safe

Practical note:
- Max installation cap is currently set to 10, this cleanup must be proactive to prevent user lockout over time.

Implementation note:
- We already have `revokeInstallations(...)` at client API level.
- We still need a strategy to determine which installation IDs are safe to revoke per conversation.

### 4) Explode interaction
- explode must remove local + synced key material + convo history, we can consider that an exploding convo is simply not backed-up (same as disappearing messages in World)
- product copy must state backup-related limits (brief sync windows, backup semantics)

---

## Phase 2 — Archive backup

### First validate real-world restore matrix
We should verify behavior for:
1. **New phone restored from full iCloud device backup**
2. **User deletes and reinstalls app on same phone**
3. **User installs on second device without full-phone migration**

### Archive value by scenario
- Scenario 1: may already have message files from phone backup
- Scenario 2: likely needs app-level backup/restore path
- Scenario 3: likely needs app-level backup/restore path

### If Phase 2 proceeds
- Use XMTP archive APIs per conversation client
- iCloud Drive container for archive files
- Archive encryption key in iCloud Keychain
- Daily/background trigger + manual "Back up now"
- Exclude disappearing messages
- Exclude exploding conversations' messages

---

## Phase 3 — Full multi-device experience (future)

Out of MVP scope:
- device sync and coherent cross-device behavior for preferences/read/mute
- push and installation orchestration across many active devices
- performance strategy for (conversations x devices)

---

## Open questions (updated)

## Installation lifecycle
1. Installation cap is currently 10; confirm exact failure mode at cap (error surface, timing, and recovery path).
2. What source of truth do we use to enumerate per-conversation installations for cleanup?
3. Revocation policy: age-based, last-seen-based, or explicit user choice (probably not this last one)?
4. UX if cap reached before cleanup succeeds.

## Archive necessity
5. After running restore matrix tests, which scenarios remain unsolved without archive?
6. Is app-delete/reinstall recovery a must-have in MVP or acceptable in Phase 2?

## Security
7. Is iCloud Keychain-only acceptable for MVP threat model?
8. Do we require an optional PIN/passphrase in the first post-MVP release (the first backup-security hardening release after MVP)?

## Product direction
9. When to expose per-conversation backup/sync controls vs app-level default?
10. Turnkey viability for future backend abstraction (import/export UX and cost constraints), export and share conversations to other platforms like Convos Web and Convos Android.

## Additional questions to answer before implementation
11. Should we introduce a "restore mode" that blocks normal send/subscribe until installation cleanup completes, to avoid race conditions and duplicate pushes?
12. For installation cleanup, do we need a server-assisted "last seen" signal, or can we decide safely with XMTP-only metadata? Wondering if the endpoint Nick mentioned for last-message is installation or inboxId based?
14. If installation revocation fails for some conversations, do we partially restore, retry in background, or block the whole restore?
15. How do we message "history available but identity missing" and "identity restored but history incomplete" so support can quickly diagnose user issues?
16. Should we create a lightweight diagnostics screen (backup status per conversation, last backup date, installation count risk) for support and QA?
17. If user disables iCloud Keychain after enabling backup, what should Convos do on next launch (warn, degrade gracefully, or require explicit confirmation)?
18. Do we need a "backup health" metric pipeline (restore success %, cap near-miss %, time-to-resume) before broad rollout?

---

## Immediate next steps

1. **Add installation-lifecycle spike (high priority)**
   - model per-conversation installation growth on repeated restore/reinstall
   - design stale-installation revocation policy
   - test cap behavior and error handling

2. **Run restore behavior matrix (high priority)**
   - full-phone restore vs app reinstall vs second-device install
   - document exactly what messages/data survive in each path

3. **Finalize MVP boundary**
   - phase 1 includes key backup + restore + installation cleanup
   - decide whether archive is required now or can remain phase 2

4. **Write ADR update**
   - capture installation lifecycle requirement and archive gating criteria

---

## MVP success criteria

- User who loses device can recover identities and resume conversations on new iPhone
- Restore flow does not accumulate unbounded stale installations per conversation
- Installation cap risk is mitigated by policy + tooling
- Product messaging is clear on what is restored now vs later
- Architecture stays compatible with future per-conversation backup/sync controls
