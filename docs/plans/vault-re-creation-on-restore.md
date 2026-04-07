# Vault Re-creation on Restore

> **Status**: Draft
> **Author**: Louis
> **Created**: 2026-04-07
> **Updated**: 2026-04-07

## Problem

After a user restores from backup on a new device (or a wiped device), all conversations **and the vault itself** are marked inactive. Regular conversations recover automatically when another member sends a message, which triggers an MLS commit re-adding the restored installation to the group.

**The vault cannot recover this way.** The vault is the user's own private group — the only members across all their devices belong to the same user. There is no "other party" to send a message and trigger the re-addition of the restored installation.

Concretely:

1. Device A creates vault, adds conversations, broadcasts keys
2. Device A backs up → bundle contains vault archive + conversation archives + GRDB
3. Device A dies, or user moves to device B
4. Device B restores from backup:
   - Imports vault archive → gets read-only view of old vault MLS state
   - Extracts conversation keys from vault messages in GRDB
   - Imports conversation archives (these will reactivate when a friend sends a message)
5. **Vault is dead.** The restored vault's MLS state lists device A's installation as a member, not device B's new installation. Device B cannot participate in the vault group.
6. Any future device the user tries to pair cannot sync via the vault, because the only active vault member is the dead installation.

This means the backup/restore story only covers conversations. Multi-device sync via the vault is broken after any restore.

## Goals

- [ ] After restore, the user has a working vault on device B that can pair with future devices and sync keys
- [ ] The old vault XMTP database is preserved (not deleted), for safety, debugging, and potential manual recovery
- [ ] The new vault key is saved to iCloud Keychain (so the next device can pick it up via the existing sync mechanism)
- [ ] The old vault key in iCloud Keychain is handled gracefully (not accidentally left as the "active" key that future devices pick up first)
- [ ] Conversation keys previously extracted from the old vault archive are broadcast to the new vault so the new vault becomes the source of truth

## Non-Goals

- Recovering vault message history from the old vault (messages in the old vault are locked behind MLS membership we don't have)
- Migrating the vault `inboxId` — the new vault has a new inboxId by design
- Merging the old and new vault into one — they're separate MLS groups
- Trying to "reactivate" the old vault via some protocol trick — not possible per MLS design

## Proposed flow

### High-level sequence

```
Restore flow:
  1. Decrypt backup bundle (existing)
  2. Import vault archive → extract conversation keys (existing)
  3. Wipe conversation XMTP DBs + keychain (existing)
  4. Save conversation keys to keychain (existing)
  5. Replace GRDB (existing)
  6. Import conversation archives (existing)
  7. Mark all conversations inactive (existing)
  8. *** NEW: Re-create vault ***
  9. Resume sessions (existing)
```

### Step 8 in detail

**8a. Revoke device A's installation from the old vault**

Before disconnecting the old vault client, call `revokeAllOtherInstallations` on it using the old vault's signing key (still in the keychain at this point). This kills device A's installation on the old vault inboxId via the XMTP network, matching the same behavior already applied to restored conversation inboxes.

Why this matters: without revocation, device A keeps a zombie installation on the old vault forever. Combined with the per-conversation revocations that already happen, this ensures device A is fully replaced, not just partially.

If revocation fails (network down, key unavailable), log and continue — not fatal. The user can retry the restore or manually clean up later.

**8b. Disconnect the old vault client**

Tear down the XMTP client for the old vault. The bootstrap state resets to `.notStarted`.

**8c. Clear old vault key from keychain**

Delete the old vault key from both local and iCloud keychain stores. The old key corresponds to an inboxId whose installation is now revoked — leaving it in iCloud would cause future devices to pick up the dead vault.

Open question: do we want to preserve the old key in a *separate* iCloud keychain service (e.g., `org.convos.vault-identity.restored`) as an audit trail? Probably not worth it for v1.

**8d. Clear old DBInbox row**

Delete the old vault's `DBInbox` row so the bootstrap doesn't pick it up and fail the clientId-mismatch check.

**8e. Create new vault**

Call `VaultManager.bootstrapVault()` with a fresh identity (new inboxId, new signing/db keys). This follows the existing "first-time creation" path:
- Generate new keys
- Create XMTP client
- Save to both local and iCloud keychain (via `VaultKeyStore`)
- Save DBInbox row with `isVault: true`

**8f. Broadcast restored conversation keys to new vault**

Call `VaultManager.shareAllKeys()` to publish every restored conversation key as a `DeviceKeyBundle` message in the new vault group. This makes the new vault the source of truth for future devices.

**8g. Mark restore complete**

State transitions to `.completed`, sessions resume.

### Data model / storage

No schema changes. The existing `DBInbox` table and `VaultKeyStore` cover everything. The renamed-on-disk old vault DB is purely a filesystem artifact.

### Failure modes

**Old vault revocation fails**: log warning, continue. Device A's vault installation lingers as a zombie, but the new vault on device B still works. Not a blocker.

**New vault creation fails**: restore state transitions to `.failed`. User is in a half-restored state (conversations restored, no active vault). Recovery: retry. Keychain deletion should be idempotent.

**shareAllKeys fails after new vault created**: log warning, continue. The conversations are still usable — the vault will have keys broadcast to it on the next normal sync cycle (when new messages arrive). Not fatal.

**Edge case: no conversations in backup**: step 8f is a no-op. New vault is created empty. Fine.

### Interaction with existing code

- `RestoreManager.restoreFromBackup()` grows a new step after `markAllConversationsInactive()`
- `VaultManager` probably needs a `reset(preservingOldDatabase:)` or `reCreate()` method to cleanly tear down the old vault client before creating a new one
- `VaultKeyStore.deleteAll()` or `delete(inboxId:)` is called to clear the old key
- `broadcastAllKeys` already exists (called from `BackupManager.createBackup()`) — reuse it

### What stays the same

- The inactive conversation mode still applies to restored conversations — they're still inactive until a real message from another member arrives
- The iCloud Keychain sync flag on the new vault key is still `synchronizable: true` (from PR #626)
- Backup bundle decryption still uses all available vault keys (already handles key divergence)

## Open Questions

1. **Where should the old vault DB be moved to?** Options:
   - Same directory, different name (e.g., `vault-xmtp.restored-20260407-153000.db3`)
   - A subdirectory `restored-vaults/` for clarity
   - Leave it alone — rely on `isVault = 0` in the new DBInbox row so the bootstrap picks the new one
   - Leaning toward: rename with timestamp suffix so there's no ambiguity about which file is "current"

2. **Should we delete the old vault key or rename it?** Leaning toward delete — fewer moving parts, and if we ever want to recover we still have the backup bundle.

3. **What if the user has paired devices that are still alive?** In theory, the user should pair with an existing device to resync, not create a new vault. But we can't detect "has other active device" reliably without trying to pair. For v1, always re-create on restore. If the user has an active paired device, they can manually re-pair after restore and the new vault becomes the shared one.
   - This means a user with multi-device setup who restores will have TWO active vaults (the surviving device's and the restored device's new one) until they re-pair. Not ideal but not catastrophic.

4. **Should we show UI feedback for the vault re-creation step?** Probably yes — the restore progress UI should show "Setting up vault…" between "Importing conversations…" and "Done".

5. **What about the backup debug panel?** The "Restore from backup" flow should transparently do this. The vault debug panel should show the new vault and the "restored" annotation on the old one.

## Testing Strategy

- Unit test: `RestoreManager.restoreFromBackup()` creates a new vault with new inboxId distinct from the one in the backup
- Unit test: old vault DB file is preserved on disk after restore
- Unit test: old vault key is removed from keychain after restore
- Unit test: restored conversation keys are broadcast to the new vault (verify via `VaultManager` state)
- Integration test: full restore → new vault is operational (can create new conversations, can pair a new device)
- Manual: restore on device B, observe debug panel shows a fresh vault inboxId, verify backup on device B produces a bundle with the new vault

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| User with paired devices ends up with two vaults | Medium | Document the "re-pair after restore" flow; consider detecting pairing history in the future |
| Old vault DB file accumulates on disk over multiple restores | Low | Cleanup job or manual debug action to purge old files |
| New vault creation fails mid-restore | Medium | Transition to `.failed` state, surface error, support retry |
| Key broadcast to new vault fails silently | Low | Log warning, next sync cycle will re-broadcast naturally |
| User expects old vault history to be recoverable | Low | Not a goal — messages in the vault are not user-facing history anyway (they're key bundles) |

## Sequencing

1. **Phase 1**: `VaultManager.reCreate()` method — teardown + new vault creation, with old DB rename
2. **Phase 2**: Wire into `RestoreManager.restoreFromBackup()` after `markAllConversationsInactive()`
3. **Phase 3**: Broadcast restored keys to new vault
4. **Phase 4**: UI feedback in restore progress (cosmetic)
5. **Phase 5**: Tests

Estimated: 1–2 days for Phases 1–3, plus testing.

## References

- `docs/plans/convos-vault.md` — overall vault architecture (acknowledges this limitation)
- `docs/plans/icloud-backup.md` — backup/restore flow
- `docs/plans/icloud-backup-inactive-conversation-mode.md` — inactive mode for conversations
- `ConvosCore/Sources/ConvosCore/Vault/VaultManager.swift` — existing vault lifecycle
- `ConvosCore/Sources/ConvosCore/Backup/RestoreManager.swift` — restore entry point
