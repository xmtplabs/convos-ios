# Background Backup Scheduler + Fresh Install Restore Prompt

## Overview

Two features that complete the backup/restore UX:

1. **Background backup scheduler** — automatic daily backups via `BGProcessingTask` so users always have a recent backup without manual intervention
2. **Fresh install restore prompt** — on first launch, detect available backups and offer to restore before the user starts from scratch

## Background Backup Scheduler

### How it works

iOS `BGProcessingTask` runs long-running work (network, disk I/O) at system-chosen times — typically overnight while charging. We register a task identifier at app launch, schedule it for 24h from now, and the system picks the optimal execution window.

`BGProcessingTask` can run for several minutes (unlike `BGAppRefreshTask` which is limited to ~30 seconds). Our backups are ~384KB and take ~1 second, so execution time is not a concern.

### Architecture

**`BackupScheduler`** lives in the **main app target**. It uses `BGTaskScheduler`, `UIApplication`, and app lifecycle APIs that are iOS-only. ConvosCore stays cross-platform.

The scheduler calls `BackupManager` (in ConvosCore) to perform the actual backup. Dependency flows: app target → ConvosCore.

### Capability and build settings

Two things are needed:

1. **Background Modes capability** — enable "Background processing" in the Xcode target capabilities. This adds `processing` to `UIBackgroundModes` in the generated Info.plist. Without this, `BGTaskScheduler.submit` throws at runtime.

2. **Task identifier registration** — since the project uses `GENERATE_INFOPLIST_FILE = YES` (no checked-in Info.plist), add the identifier via build settings. `INFOPLIST_KEY_*` treats array-typed plist keys as space-separated string lists:
   ```
   INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers = org.convos.backup.daily
   ```
   Add this to all xcconfig files (Dev, Local, Prod) since we build different apps from the same codebase.

   **Verify after first build** — Xcode's generation of array-typed plist keys from `INFOPLIST_KEY_*` can be quirky. After the first build, inspect the emitted Info.plist to confirm the key is an array of strings, not a single string:
   ```
   plutil -p .derivedData/.../Info.plist | grep -A2 BGTaskScheduler
   ```
   If the value is a string rather than an array, fall back to a checked-in Info.plist (set `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE = Convos/Info.plist`) with the key declared explicitly.

### Components

**`BackupScheduler`**:
- `register()` — called once at app launch (`ConvosApp.init`), registers the handler with `BGTaskScheduler.shared`
- `scheduleNextBackup()` — requests execution no earlier than 24h from now, requires network connectivity. Idempotent: `BGTaskScheduler.submit` replaces any existing request with the same identifier, so calling it multiple times is safe.
- Background handler: creates `BackupManager`, calls `createBackup()`, reschedules for the next day

**Task identifier:** `org.convos.backup.daily`

### BGTask lifecycle requirements

Every background task handler must:

1. **Set `task.expirationHandler`** — called if the system reclaims time before completion. Cancel in-flight work and call `task.setTaskCompleted(success: false)`.
2. **Always call `task.setTaskCompleted(success:)`** — in every code path (success, failure, cancellation, expiration). Failing to call this causes the system to throttle future scheduling.
3. **Reschedule in all paths** — success, failure, and expiration must all call `scheduleNextBackup()` so the daily cadence continues.
4. **Guard against concurrent runs** — if a manual "Back up now" is in progress when the background task fires, mark the task as completed immediately and reschedule. Don't run two backups simultaneously.

### Behavior when no vault key exists

If the vault hasn't been bootstrapped yet (no conversations, fresh install), the backup will fail at `vaultKeyStore.loadAny()`. The scheduler should:
- Log the skip reason via `Log.info` and emit `QAEvent.emit(.backup, "skipped_no_vault")` so QA can verify during test runs
- Call `task.setTaskCompleted(success: true)` (not a real failure, just nothing to back up)
- Reschedule — the next run will succeed after the user creates their first conversation

### Trigger points

| Trigger | Action |
|---|---|
| App launch | `register()` + `scheduleNextBackup()` if not already scheduled |
| Manual "Back up now" | Reschedule (resets the 24h window) |
| First conversation created | Schedule with shorter `earliestBeginDate` (15 minutes — see Design decisions) to capture the first backup promptly, rather than waiting up to 24h |
| Restore completes | Post-restore backup already runs inline; call `scheduleNextBackup()` afterward to restart the daily cadence |

### No toggle for v1

Backup is always on. Matches user expectations — iCloud backups "just work". A toggle can be added later if users request it.

### Simulator testing

`BGProcessingTask` only fires on real devices or via LLDB:
```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"org.convos.backup.daily"]
```

Add a debug-only "Run background backup now" button in `BackupRestoreSettingsView` (non-production builds) so QA can trigger the scheduler path without LLDB.

## Fresh Install Restore Prompt

### When to show

On first launch (or after delete-all-data), before the user creates their first conversation:

1. No non-vault **used** inboxes in GRDB (fresh state) — use the same `isUnused` filter as elsewhere to avoid precreated/draft inboxes suppressing the prompt
2. `RestoreManager.findAvailableBackup()` returns a backup (vault key in iCloud Keychain + backup file in iCloud container)

If both conditions are true, show a restore prompt.

**Re-check on foreground:** iCloud Keychain sync can lag on fresh install. Re-check `findAvailableBackup()` on each `sceneDidBecomeActive` while the prompt hasn't been shown and no conversations exist. This handles the case where the vault key syncs a few seconds after first launch.

**After restore completes:** the prompt should not reappear. Once a non-vault inbox exists in GRDB (from the restored data), condition 1 is no longer met.

### UX

A card on the existing empty conversations screen (integration point: `emptyConversationsViewScrollable` / `ConversationsListEmptyCTA` in `ConversationsView.swift`):

> **Welcome back**
> A backup from [deviceName] is available
> [date] · [N] conversations
>
> [ Restore ]  [ Skip ]

**Note on "N conversations":** `BackupBundleMetadata.inboxCount` counts inboxes (accounts), not conversations. The card should say "N account(s)" or we should add a conversation count to `BackupBundleMetadata` in a follow-up. For v1, use the inbox count with appropriate copy (e.g. "5 conversations" is close enough for single-inbox users, which is the common case).

- **Restore** — navigates to `BackupRestoreSettingsView` or triggers restore inline with progress
- **Skip** — dismisses the card for this specific backup

### Skip persistence

Persist the skipped backup's creation date, not a permanent boolean:

```
UserDefaults key: "skippedRestoreBackupDate"
Value: ISO8601 string of the skipped backup's metadata.createdAt
```

On next check: if `findAvailableBackup()` returns a backup with `createdAt` newer than the skipped date, show the prompt again. This way, skipping today's backup doesn't hide tomorrow's.

`UserDefaults` is wiped on app reinstall. On delete-all-data, `AppSettingsViewModel.deleteAllData` resets UserDefaults keys via a hand-maintained allowlist (it calls targeted `resetUserDefaults()` helpers on each view model — it does not wipe all defaults). The new `skippedRestoreBackupDate` key must be removed in `ConversationsViewModel.resetUserDefaults()` (already called from the delete-all flow) so the prompt reappears after a data wipe.

### Implementation

- `ConversationsViewModel`: check in a `Task` from `start()` or `.onAppear` (not `init`, which runs synchronously and could block on `FileManager` iCloud ubiquity container access on cold launch). Populate `availableRestorePrompt: BackupBundleMetadata?` if the backup is newer than the skipped date.
- `ConversationsView`: when `availableRestorePrompt` is set and the empty state is showing, render the restore card above `ConversationsListEmptyCTA`.
- Skip action: persist `metadata.createdAt` to UserDefaults, clear `availableRestorePrompt`.

## File changes

| File | Change |
|---|---|
| `Convos/Config/Dev.xcconfig` | Add `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers` |
| `Convos/Config/Local.xcconfig` | Same |
| `Convos/Config/Prod.xcconfig` | Same |
| Xcode project | Enable Background Modes → Background processing capability |
| `Convos/Backup/BackupScheduler.swift` | New — register, schedule, handle background task |
| `Convos/ConvosApp.swift` | Call `BackupScheduler.register()` on launch |
| `Convos/App Settings/BackupRestoreSettingsView.swift` | Reschedule after manual backup + debug trigger button |
| `Convos/Conversations List/ConversationsViewModel.swift` | Add `availableRestorePrompt` + foreground re-check |
| `Convos/Conversations List/ConversationsView.swift` | Render restore prompt card on empty state |

## Design decisions

### No backup toggle

Backups are always on. The backup is tiny (~384KB), runs once a day in the background, and uses negligible battery/data. A toggle lets users disable their own safety net — they won't know until they lose their phone and have nothing to restore. If there's user demand later, a toggle can be added without architectural changes.

### No frequency picker

Daily is hardcoded. Weekly means up to 7 days of lost messages on restore. Hourly is wasteful for text-only conversations that change slowly. Daily covers the common case without a knob to confuse users.

### Concurrency guard

`BackupManager` is an actor, but manual and background paths may create separate instances — actor isolation only serializes within a single instance. The scheduler holds a **process-global** `isBackupInProgress` flag (e.g. a static `AtomicBool` or a shared singleton) that both the manual "Back up now" path and the BGTask handler check before starting. If a backup is already in progress, the second caller short-circuits — the BGTask handler marks complete and reschedules.

### First-conversation trigger timing

15 minutes `earliestBeginDate` (not 5). `BGProcessingTask` often requires network + idle/power, so very short windows on fresh installs without charge may be ignored by iOS. 15 minutes gives the system more flexibility.

## Out of scope

- Quickname data is stored in UserDefaults and is not included in the backup bundle; out of scope for this PR
- Incremental/delta backups (full backup each time)
- Backup size compression (not needed at current sizes)
- Conversation count in `BackupBundleMetadata` — trivial follow-up to replace inboxCount in card copy
