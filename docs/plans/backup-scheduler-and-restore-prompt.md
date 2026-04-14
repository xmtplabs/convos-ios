# Background Backup Scheduler + Fresh Install Restore Prompt

## Overview

Two features that complete the backup/restore UX:

1. **Background backup scheduler** — automatic daily backups via `BGProcessingTask` so users always have a recent backup without manual intervention
2. **Fresh install restore prompt** — on first launch, detect available backups and offer to restore before the user starts from scratch

## Background Backup Scheduler

### How it works

iOS `BGProcessingTask` runs long-running work (network, disk I/O) at system-chosen times — typically overnight while charging. We register a task identifier at app launch, schedule it for 24h from now, and the system picks the optimal execution window.

Our backups are ~384KB and take ~1 second, well within the ~30-second execution limit.

### Architecture

**`BackupScheduler`** lives in the **main app target** (not ConvosCore). It uses `BGTaskScheduler`, `UIApplication`, and app lifecycle APIs that are iOS-only and don't belong in the cross-platform core package.

The scheduler calls `BackupManager` (which is in ConvosCore) to perform the actual backup. The dependency flows: app target → ConvosCore, not the other way around.

### Capability requirement

Enable **Background Modes → Background processing** in the Xcode project capabilities. Without this, `BGTaskScheduler` registration silently fails.

### Components

**`BackupScheduler`**:
- `register()` — called once at app launch, registers the handler with `BGTaskScheduler.shared`
- `scheduleNextBackup()` — requests execution no earlier than 24h from now, requires network connectivity
- Background handler: creates `BackupManager`, calls `createBackup()`, reschedules for the next day

**Task identifier:** `org.convos.backup.daily`

### BGTask lifecycle requirements

Every background task handler must:

1. **Set `task.expirationHandler`** — called if the system reclaims time before completion. Must call `task.setTaskCompleted(success: false)` and cancel in-flight work.
2. **Always call `task.setTaskCompleted(success:)`** — in every code path (success, failure, cancellation). Failing to call this causes the system to throttle future scheduling.
3. **Reschedule in all paths** — success, failure, and expiration must all call `scheduleNextBackup()` so the daily cadence continues.
4. **Guard against concurrent runs** — if a manual "Back up now" is in progress when the background task fires, mark the task as completed immediately and reschedule. Don't run two backups simultaneously.

### Behavior when no vault key exists

If the vault hasn't been bootstrapped yet (no conversations, fresh install), the backup will fail at `vaultKeyStore.loadAny()`. The scheduler should:
- Log the skip reason at info level
- Call `task.setTaskCompleted(success: true)` (not a real failure, just nothing to back up)
- Reschedule — the next run will succeed after the user creates their first conversation

### Trigger points

| Trigger | Action |
|---|---|
| App launch | `register()` + `scheduleNextBackup()` if not already scheduled |
| Manual "Back up now" | Reschedule (resets the 24h window) |
| First conversation created | Schedule if no backup exists yet |
| Restore completes | Already handled (post-restore backup) |

### No toggle for v1

Backup is always on. Matches user expectations — iCloud backups "just work". A toggle can be added later if users request it.

### Info.plist change

Add `org.convos.backup.daily` to `BGTaskSchedulerPermittedIdentifiers`.

## Fresh Install Restore Prompt

### When to show

On first launch (or after delete-all-data), before the user creates their first conversation:

1. No existing non-vault inboxes in GRDB (fresh state)
2. `RestoreManager.findAvailableBackup()` returns a backup (vault key in iCloud Keychain + backup file in iCloud container)

If both conditions are true, show a restore prompt.

**Re-check on foreground:** iCloud Keychain sync can lag on fresh install. Re-check `findAvailableBackup()` on each `sceneDidBecomeActive` while the prompt hasn't been shown and no conversations exist. This handles the case where the vault key syncs a few seconds after first launch.

### UX

A card on the existing empty conversations screen (no new onboarding flow):

> **Welcome back**
> A backup from [deviceName] is available
> [date] · [N] conversations
>
> [ Restore ]  [ Skip ]

- **Restore** — triggers the restore flow inline with progress, or navigates to the Backup & Restore settings screen
- **Skip** — dismisses the card for this specific backup (not permanently)

### Skip persistence

A single `hasSkippedRestorePrompt = true` boolean would hide future valid backups forever. Instead, persist the skipped backup's identity so newer backups can surface the prompt again:

```
UserDefaults key: "skippedRestoreBackupDate"
Value: ISO8601 string of the skipped backup's metadata.createdAt
```

On next check: if `findAvailableBackup()` returns a backup with a `createdAt` newer than the skipped date, show the prompt again. This way, skipping today's backup doesn't hide tomorrow's.

### Implementation

- `ConversationsViewModel`: on init and on foreground, if conversations are empty and no non-vault inboxes exist, check `findAvailableBackup()`. Populate `availableRestorePrompt: BackupBundleMetadata?` if the backup is newer than the skipped date.
- `ConversationsView`: when `availableRestorePrompt` is set and the empty state is showing, render the restore card above the welcome content.
- Skip action: persist `metadata.createdAt` to UserDefaults, clear `availableRestorePrompt`.

## File changes

| File | Change |
|---|---|
| `Info.plist` | Add `BGTaskSchedulerPermittedIdentifiers` + Background processing capability |
| `Convos/Backup/BackupScheduler.swift` | New — register, schedule, handle background task |
| `Convos/ConvosApp.swift` | Call `BackupScheduler.register()` on launch |
| `Convos/App Settings/BackupRestoreSettingsView.swift` | Reschedule after manual backup |
| `Convos/Conversations List/ConversationsViewModel.swift` | Add `availableRestorePrompt` + foreground re-check |
| `Convos/Conversations List/ConversationsView.swift` | Render restore prompt card |

## Out of scope

- Backup on/off toggle (always on for v1)
- Frequency picker (daily, hardcoded)
- Quickname backup (deferred to v2, stored in UserDefaults)
- Incremental/delta backups (full backup each time)
- Backup size compression (not needed at current sizes)
