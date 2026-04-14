# Background Backup Scheduler + Fresh Install Restore Prompt

## Overview

Two features that complete the backup/restore UX:

1. **Background backup scheduler** — automatic daily backups via `BGProcessingTask` so users always have a recent backup without manual intervention
2. **Fresh install restore prompt** — on first launch, detect available backups and offer to restore before the user starts from scratch

## Background Backup Scheduler

### How it works

iOS `BGProcessingTask` runs long-running work (network, disk I/O) at system-chosen times — typically overnight while charging. We register a task identifier at app launch, schedule it for 24h from now, and the system picks the optimal execution window.

Our backups are ~384KB and take ~1 second, well within the ~30-second execution limit.

### Components

**`BackupScheduler`** (new, in ConvosCore or main app target):
- `register()` — called once at app launch, registers the handler with `BGTaskScheduler.shared`
- `scheduleNextBackup()` — requests execution no earlier than 24h from now, requires network connectivity
- Background handler: creates `BackupManager`, calls `createBackup()`, reschedules for the next day
- On failure (no vault, no conversations): reschedule without retry — the next daily run will try again

**Task identifier:** `org.convos.backup.daily`

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

### UX

A card on the existing empty conversations screen (no new onboarding flow):

> **Welcome back**
> A backup from [deviceName] is available
> [date] · [N] conversations
>
> [ Restore ]  [ Skip ]

- **Restore** — triggers the restore flow inline with progress, or navigates to the Backup & Restore settings screen
- **Skip** — dismisses the card permanently (persisted in `UserDefaults`)

### Implementation

- `ConversationsViewModel`: on init, if conversations are empty and no non-vault inboxes exist, check `findAvailableBackup()`. Populate `availableRestorePrompt: BackupBundleMetadata?`
- `ConversationsView`: when `availableRestorePrompt` is set and the empty state is showing, render the restore card above the welcome content
- Skip persistence: `UserDefaults.standard.bool(forKey: "hasSkippedRestorePrompt")`

## File changes

| File | Change |
|---|---|
| `Info.plist` | Add `BGTaskSchedulerPermittedIdentifiers` |
| `Convos/Backup/BackupScheduler.swift` | New — register, schedule, handle background task |
| `Convos/ConvosApp.swift` | Call `BackupScheduler.register()` on launch |
| `Convos/App Settings/BackupRestoreSettingsView.swift` | Reschedule after manual backup |
| `Convos/Conversations List/ConversationsViewModel.swift` | Add `availableRestorePrompt` |
| `Convos/Conversations List/ConversationsView.swift` | Render restore prompt card |

## Out of scope

- Backup on/off toggle (always on for v1)
- Frequency picker (daily, hardcoded)
- Quickname backup (deferred to v2, stored in UserDefaults)
- Incremental/delta backups (full backup each time)
- Backup size compression (not needed at current sizes)
