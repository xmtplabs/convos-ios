# IOS-236 — Global setting for Reveal and Include Info with Invites

## Context

References:
- Linear: IOS-236 (global setting for reveal and public info)
- Existing implementation to preserve: IOS-314 (reveal switch/control UI design and copy) — done
- Figma: node `18709:46747`

## What is already implemented

- Per-conversation Reveal mode exists in conversation settings.
  - `Convos/Conversation Detail/ConversationInfoView.swift`
- Reveal toast and info sheet exist, including copy and toggle behavior.
  - `Convos/Shared Views/IndicatorToast.swift`
  - `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/RevealMediaInfoSheet.swift`
- Reveal preferences are persisted per conversation.
  - `photoPreferences` table in GRDB (`autoReveal`, `hasRevealedFirst`)
  - `DBPhotoPreferences`, `PhotoPreferencesRepository`, `PhotoPreferencesWriter`
- `ConversationViewModel.loadPhotoPreferences()` currently falls back to `false` (reveal on) when no DB record exists.
- Per-conversation "Include info with invites" is already implemented.
  - Toggle in `ConversationInfoEditView` (`include-info-toggle`)
  - Persistence + metadata update in `ConversationViewModel.updateIncludeInfoInPublicPreview(_:)`
  - Invite payload inclusion already depends on `conversation.includeInfoInPublicPreview` in `SignedInvite+Signing.swift`
- App Menu has placeholder rows "Customize new convos" and "Notifications" both with `SoonLabel()`.

IOS-236 adds app-level defaults and uses existing per-conversation mechanisms without regressing IOS-314 behavior.

## Resolved product questions

1. Global settings apply to **new conversations only**.
2. Existing conversations keep their current per-conversation values unchanged.
3. "Include info with invites" = the conversation's pic, name, and description are visible to anyone holding the convo code before joining.
4. Copy from Figma node `18709:46747`:
   - "Reveal mode" / "Blur incoming pics" (global default: ON)
   - "Include info with invites" / "When enabled, anyone with your convo code can see its pic, name and description" (global default: OFF)
5. Per Andrew's IOS-314 comment: when global Reveal is ON, per-convo toast/info sheet still shows; when global Reveal is OFF, suppress it.

## Behavior rules

- Global defaults are only used as **initial defaults for new conversations**.
- Per-conversation values always take precedence once explicitly stored.
- Global changes are not retroactive.

### Clarification to avoid ambiguity

"No DB record" cannot be used as the sole definition of "new conversation" because some existing conversations may also have no `photoPreferences` row. Implementation must use an explicit new-conversation initialization path, or a backfill marker/migration strategy, so existing conversations do not change unexpectedly.

## Technical approach

### 1) Storage: `GlobalConvoDefaults`

New file `Convos/App Settings/GlobalConvoDefaults.swift` in the app target. UserDefaults-backed wrapper.

```swift
final class GlobalConvoDefaults {
    static let shared = GlobalConvoDefaults()

    var revealModeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "globalRevealMode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "globalRevealMode") }
    }

    var includeInfoWithInvites: Bool {
        get { UserDefaults.standard.object(forKey: "globalIncludeInfoWithInvites") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "globalIncludeInfoWithInvites") }
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: "globalRevealMode")
        UserDefaults.standard.removeObject(forKey: "globalIncludeInfoWithInvites")
    }
}
```

### 2) App Menu changes

In `AppSettingsView.swift`:
- Replace placeholder `Customize new convos` row with a real `NavigationLink` to `CustomizeSettingsView`.
- Remove placeholder `Notifications` row (per issue scope).
- Use standard navigation chevron.

### 3) New Customize screen

New file `Convos/App Settings/CustomizeSettingsView.swift`:
- Navigation title: "Customize"
- Section subtitle/header: "Your new convos"
- Row 1: Reveal mode toggle bound to `GlobalConvoDefaults.shared.revealModeEnabled`
- Row 2: Include info with invites toggle bound to `GlobalConvoDefaults.shared.includeInfoWithInvites`
- Row 3: Colors row with `SoonLabel()` (per Figma)

No dedicated view model required for v1.

### 4) Reveal default wiring (new-conversation path)

Use global reveal default as the initial value for a new conversation's reveal behavior.

Current fallback logic in `loadPhotoPreferences()`:
```swift
self.autoRevealPhotos = prefs?.autoReveal ?? false
```

Target mapping:
- global reveal ON => `autoRevealPhotos = false`
- global reveal OFF => `autoRevealPhotos = true`

### Important implementation note (persistence side effect)

`autoRevealPhotos` has `didSet` and currently persists via `persistAutoReveal(_:)`. If we assign fallback values during load, we may accidentally write DB records just by opening a conversation.

Mitigation required:
- add a non-persisting load path (e.g. `isLoadingPhotoPreferences` guard), or
- split setter methods (`setAutoRevealSilently` for initialization vs user action),
- persist only on explicit user-driven changes.

### 5) Reveal toast gating

In `ConversationViewModel.onPhotoRevealed(_:)`, gate toast/info-sheet behavior:

```swift
guard GlobalConvoDefaults.shared.revealModeEnabled else { return }
```

When global reveal is OFF, suppress reveal onboarding toast/info sheet.

### 6) Include info with invites wiring (use existing implementation)

This is not a new backend feature in v1. Existing per-conversation pipeline already exists:
- local state: `conversation.includeInfoInPublicPreview`
- updates: `updateIncludeInfoInPublicPreview(_:)`
- signed invite payload inclusion: `SignedInvite+Signing.swift`

IOS-236 work here is to apply the **global default** at new-conversation initialization so the initial per-conversation value is set correctly (default OFF), while preserving manual override in conversation settings.

### 7) Reset on delete all data

In `AppSettingsViewModel.deleteAllData()`, add:

```swift
GlobalConvoDefaults.shared.reset()
```

Also update debug reset flow (`DebugView.resetAllSettings()`) to reset global defaults so QA/dev reset behavior stays consistent.

## Exact copy (from Figma)

| Row | Title | Subtitle |
|-----|-------|----------|
| 1 | Reveal mode | Blur incoming pics |
| 2 | Include info with invites | When enabled, anyone with your convo code can see its pic, name and description |

Customize screen title: "Customize"  
Customize screen subtitle: "Your new convos"

## Acceptance criteria

1. Tapping "Customize" in App Menu navigates to Customize screen (no soon label).
2. "Notifications" placeholder row is removed from App Menu.
3. Customize screen shows both toggles with the exact copy above.
4. Reveal mode default is ON; Include info with invites default is OFF.
5. New conversations initialize reveal behavior from global setting.
6. New conversations initialize include-info behavior from global setting.
7. Existing conversations remain unchanged when global defaults are changed.
8. When global Reveal is OFF, per-convo reveal toast/info sheet is suppressed.
9. Delete all app data resets global defaults.
10. IOS-314 per-conversation reveal behavior and copy remain intact.

## Test plan

### Unit tests
- `GlobalConvoDefaults` returns defaults when no values exist.
- `GlobalConvoDefaults` persists and reads values.
- New-conversation reveal initialization maps correctly for global ON/OFF.
- Existing per-conversation reveal value overrides global.
- New-conversation include-info initialization maps correctly for global ON/OFF.
- Existing per-conversation include-info value overrides global.
- Reveal toast gate works when global reveal is OFF.
- No unintended persistence during preference load path.

### Manual / Integration
- Customize toggles persist across app restarts.
- New conversation reflects global reveal default.
- New conversation reflects global include-info default.
- Existing conversations unchanged after toggling global settings.
- Reveal toast suppressed when global reveal is OFF.

### Regression
- Per-convo reveal toggle in `ConversationInfoView` still works.
- Per-convo include-info toggle in `ConversationInfoEditView` still works.
- Reveal info sheet/toast behavior unchanged when global reveal is ON.
- Delete-all-data and debug reset both restore global defaults.

## PR stack

1. **Plan PR** — this document
2. **Implementation PR** (stacked):
   - `GlobalConvoDefaults.swift` (new)
   - `CustomizeSettingsView.swift` (new)
   - `AppSettingsView.swift` — enable Customize link, remove Notifications placeholder
   - `AppSettingsViewModel.swift` — reset global defaults on delete
   - `DebugView.swift` — include global defaults in reset path
   - `ConversationViewModel.swift` — global reveal default wiring + toast gate + no-load-persist guard
   - new-conversation initialization wiring for `includeInfoInPublicPreview`
3. **Optional hardening PR**:
   - protocol/injection wrapper for `GlobalConvoDefaults` to improve unit testability

## Files involved (confirmed)

- `Convos/App Settings/GlobalConvoDefaults.swift` (new)
- `Convos/App Settings/CustomizeSettingsView.swift` (new)
- `Convos/App Settings/AppSettingsView.swift`
- `Convos/App Settings/AppSettingsViewModel.swift`
- `Convos/Debug View/DebugView.swift`
- `Convos/Conversation Detail/ConversationViewModel.swift`
- `Convos/Conversation Detail/ConversationInfoEditView.swift` (validation/regression only)
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Signing.swift` (existing behavior reference)
