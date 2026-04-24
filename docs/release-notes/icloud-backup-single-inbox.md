# Release notes — iCloud Backup for single-inbox

> For paste-in use in App Store "What's New" + Convos team changelog.

## Short form (App Store)

- Back up your conversations to iCloud — nothing on the phone gets
  lost if you replace or reinstall.
- Restore your data on a new device using the same Apple ID.
- Daily backups run automatically in the background.

## Long form (team / beta notes)

### What shipped

- **Automatic daily iCloud backups.** Convos writes an encrypted
  bundle to iCloud Drive once a day, plus on launch if the last
  successful backup is older than 24 hours. Nothing to configure.
- **Restore on a new device.** When you install Convos on a new
  phone signed into the same Apple ID, you'll see a "Restore your
  conversations" card on first launch. Tap Restore to bring back
  your pinned chats, drafts, and message history. Tap Start fresh
  if you'd rather begin with a clean slate.
- **Reset the replaced device.** If you restore on phone B, phone A
  detects it's no longer the active device and shows a "This
  device has been replaced" banner. Tap Reset to safely wipe it.
- **Settings → Backup & Restore.** Run a backup manually, see the
  last-backup timestamp, and rerun restore if the initial one
  partially failed.
- **Debug / QA build additions.** Backup debug view shows schema
  generation, restore-flag state, active transactions, and a
  "Simulate background run" button.

### What didn't change

- Your identity still syncs via iCloud Keychain — the same as
  before the single-inbox refactor. Backup only covers conversation
  + message state.
- Existing installs upgrade transparently; no migration needed.

### Known limitations

- iCloud Drive entitlements aren't fully provisioned yet for
  production builds. Until they land, backups fall back to the
  local app-group directory on-device — device-to-device restore
  won't actually work in Prod. Internal / TestFlight builds with
  the entitlement will work end-to-end.
- If the initial archive import doesn't complete, the conversation
  list restores but message history does not. The settings screen
  shows a warning row asking you to run restore again.
- If you change Apple ID, your backup stays behind with the
  previous account (this is Apple's behavior, not ours).

### References

- Plan: [docs/plans/icloud-backup-single-inbox.md](../plans/icloud-backup-single-inbox.md)
- Architecture: [docs/adr/012-icloud-backup-single-inbox.md](../adr/012-icloud-backup-single-inbox.md)
