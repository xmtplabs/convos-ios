# IOS-236 — Global setting for Reveal and Include Info with Invites

## Context

References:
- Linear: IOS-236 (global setting for reveal and public info)
- Existing implementation to preserve: IOS-314 (reveal switch/control UI design and copy) — Done
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
- `ConversationViewModel.loadPhotoPreferences()` falls back to `false` (reveal ON) when no DB record exists.
- App Menu has placeholder rows "Customize new convos" and "Notifications" both with `SoonLabel()`.

IOS-314 delivered updated per-conversation reveal UX. IOS-236 adds app-level defaults without regressing that behavior.

## Resolved product questions

1. Global settings apply to **new conversations only** — conversations with no existing `photoPreferences` DB record.
2. Existing conversations keep their current per-conversation DB values unchanged.
3. "Include info with invites" = the conversation's pic, name, and description are visible to anyone holding the convo code before joining (confirmed from Figma subtitle copy).
4. Copy confirmed from Figma node `18709:46747`:
   - "Reveal mode" / "Blur incoming pics" (global default: ON)
   - "Include info with invites" / "When enabled, anyone with your convo code can see its pic, name and descriptions" (global default: OFF)
5. Per Andrew's comment on IOS-314: when global Reveal is ON, per-convo toast/info sheet still shows; when global Reveal is OFF, skip it entirely.

## Behavior rules

- Global defaults are only consulted when no per-conversation DB record exists.
- Once a user interacts with the per-convo reveal toggle, that value is written to DB and permanently takes precedence.
- Global setting changes do not retroactively update existing conversations.

## Technical approach

### 1) Storage: `GlobalConvoDefaults`

New file `Convos/App Settings/GlobalConvoDefaults.swift` in the app target. Simple UserDefaults wrapper — no GRDB needed for v1.

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
- Replace the placeholder `Text("Customize new convos") + SoonLabel()` row with a live `NavigationLink` to `CustomizeSettingsView`.
- Remove the `Text("Notifications") + SoonLabel()` row entirely (per Linear issue description).
- The Customize row navigates using a back-chevron icon (matches Figma) — standard `NavigationLink` chevron is sufficient.

### 3) New Customize screen

New file `Convos/App Settings/CustomizeSettingsView.swift`:
- Navigation title: "Customize"
- Section subtitle/header: "Your new convos"
- Row 1: `FeatureRowItem` — `symbolName: "eye.circle.fill"`, title "Reveal mode", subtitle "Blur incoming pics" + `Toggle` bound to `GlobalConvoDefaults.shared.revealModeEnabled`
- Row 2: `FeatureRowItem` — appropriate info/person icon, title "Include info with invites", subtitle "When enabled, anyone with your convo code can see its pic, name and descriptions" + `Toggle` bound to `GlobalConvoDefaults.shared.includeInfoWithInvites`
- Row 3: Colors row with `SoonLabel()` (matches Figma)

No separate ViewModel needed — `GlobalConvoDefaults.shared` is accessed directly. Use `@State` wrappers for toggle bindings so SwiftUI updates reactively.

### 4) New conversation reveal default wiring

In `ConversationViewModel.loadPhotoPreferences()`:

```swift
// Before:
self.autoRevealPhotos = prefs?.autoReveal ?? false

// After:
let globalReveal = GlobalConvoDefaults.shared.revealModeEnabled
self.autoRevealPhotos = prefs?.autoReveal ?? !globalReveal
```

When `prefs` is nil (new conversation, no DB record yet), the global default is used.
- Global reveal ON → `!true = false` → `autoRevealPhotos = false` → blur active (reveal mode on)
- Global reveal OFF → `!false = true` → `autoRevealPhotos = true` → no blur (auto show)

When `prefs` is non-nil, the stored value is used unchanged.

### 5) Reveal toast: respect global reveal setting

Per Andrew's comment on IOS-314: when global Reveal is OFF, suppress the per-convo reveal toast and info sheet.

In `ConversationViewModel`, gate the reveal notification logic:

```swift
guard GlobalConvoDefaults.shared.revealModeEnabled else { return }
// existing: if !hasShownRevealInfoSheet { ... } else if !hasShownRevealToast { ... }
```

This means: if the user has globally opted out of reveal mode, they never see the "Reveal mode" onboarding toast in any conversation.

### 6) "Include info with invites" wiring

For v1: the preference is stored and displayed in the Customize UI. The enforcement mechanism — how the invite resolver exposes or hides conversation metadata (pic, name, description) to joiners — depends on the invite/XMTP infrastructure layer and is documented as a follow-up integration point.

The iOS-side wiring point is: when creating a new conversation, read `GlobalConvoDefaults.shared.includeInfoWithInvites` and pass it to whatever conversation-creation API exposes this metadata visibility. That call site will be identified during implementation.

### 7) Reset on delete all data

In `AppSettingsViewModel.deleteAllData()`, add:

```swift
GlobalConvoDefaults.shared.reset()
```

alongside the existing `ConversationViewModel.resetUserDefaults()` and other resets.

## Exact copy (confirmed from Figma)

| Row | Title | Subtitle |
|-----|-------|----------|
| 1 | Reveal mode | Blur incoming pics |
| 2 | Include info with invites | When enabled, anyone with your convo code can see its pic, name and descriptions |

Customize screen page title: "Customize"
Customize screen subtitle: "Your new convos"

## Acceptance criteria

1. Tapping "Customize" in App Menu navigates to the Customize screen (no "Soon" label).
2. The "Notifications" row is removed from App Menu.
3. Customize screen shows both toggles with the exact copy above.
4. Reveal mode defaults to ON; Include info with invites defaults to OFF.
5. New conversations (no prior DB pref) start with the global reveal default.
6. Existing conversations are unaffected by changes to the global setting.
7. When global Reveal is OFF, the per-convo reveal toast and info sheet are suppressed.
8. "Delete all app data" resets global preferences to defaults.
9. IOS-314 per-conversation reveal toggle and copy remain intact.

## Test plan

### Unit tests
- `GlobalConvoDefaults` returns correct defaults when no UserDefaults value is set.
- `GlobalConvoDefaults` persists and reads back set values.
- `ConversationViewModel.loadPhotoPreferences()`: when DB pref is nil, `autoRevealPhotos` reflects global default (both ON and OFF cases).
- `ConversationViewModel.loadPhotoPreferences()`: when DB pref exists, the DB value is used and global default is ignored.
- Reveal toast gate: when global reveal is OFF, toast/info sheet is not shown.

### Manual / Integration
- Customize screen toggles persist across app restarts.
- New conversation `autoRevealPhotos` reflects global setting.
- Existing conversation `autoRevealPhotos` unchanged after toggling global setting.
- Reveal toast suppressed in new conversations when global reveal is OFF.

### Regression
- Per-convo reveal toggle in `ConversationInfoView` still functions correctly.
- Reveal info sheet / toast behavior unchanged when global reveal is ON.
- "Delete all app data" resets global prefs along with all other state.

## PR stack

1. **Plan PR** — this document (commits on its own branch, already in progress)
2. **Implementation PR** (stacked on plan):
   - `GlobalConvoDefaults.swift` (new)
   - `CustomizeSettingsView.swift` (new)
   - `AppSettingsView.swift` — enable Customize NavigationLink, remove Notifications row
   - `AppSettingsViewModel.swift` — add `GlobalConvoDefaults.shared.reset()` to `deleteAllData()`
   - `ConversationViewModel.swift` — global reveal default in `loadPhotoPreferences()`, reveal toast gate
3. **Include info with invites wiring PR** (stacked, or follow-up) — wire `includeInfoWithInvites` to invite/conversation creation once the infrastructure integration point is identified.

## Files involved (confirmed)

- `Convos/App Settings/GlobalConvoDefaults.swift` (new) — UserDefaults-backed storage
- `Convos/App Settings/CustomizeSettingsView.swift` (new) — Customize screen
- `Convos/App Settings/AppSettingsView.swift` — enable Customize row, remove Notifications row
- `Convos/App Settings/AppSettingsViewModel.swift` — reset global defaults on delete
- `Convos/Conversation Detail/ConversationViewModel.swift` — global reveal default in `loadPhotoPreferences()`, reveal toast gate
