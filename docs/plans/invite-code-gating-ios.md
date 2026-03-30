# Invite Code Gating — iOS Implementation Plan

> **Branch**: `jarod/invite-code-gating`
> **Backend PR**: xmtplabs/convos-backend#183
> **PRD**: `docs/plans/invite-code-gating.md`

## Current Architecture

### How assistants are gated today

Two independent flags control assistant visibility:

1. **`FeatureFlags.shared.isAssistantEnabled`** — environment-level kill switch (defaults to `true` on non-production, stored in UserDefaults)
2. **`GlobalConvoDefaults.shared.assistantsEnabled`** — user preference toggle in Assistant Settings (defaults to `true`, stored in UserDefaults)

Both must be `true` for assistants to appear. This check happens in three places:
- `ConversationView.showPullToAddAssistant` — controls the pull-up gesture
- `ConversationView` — passes `isAssistantEnabled` to `MessagesView`
- `AddToConversationMenu.isAssistantEnabled` — controls the "Instant assistant" menu item

### Where assistant join is triggered

1. **Pull-to-add gesture** — bottom overscroll in `ConversationView` → `viewModel.onRequestAssistantJoin()`
2. **"+" menu → "Instant assistant"** — `AddToConversationMenu` → `onInviteAssistant` → `viewModel.onRequestAssistantJoin()`
3. **First-time confirmation sheet** — `AssistantsInfoView(isConfirmation: true)` → `viewModel.requestAssistantJoin()`

### The toggle

`AssistantSettingsView` shows a `Toggle` bound to `$defaults.assistantsEnabled`. Currently toggles freely with no gating.

## Implementation Plan

### 1. Invite Code Unlock Store

**File**: `Convos/App Settings/GlobalConvoDefaults.swift`

Add a new property `assistantCodeUnlocked` to `GlobalConvoDefaults`:

```swift
var assistantCodeUnlocked: Bool {
    get { UserDefaults.standard.bool(forKey: Constant.assistantCodeUnlockedKey) }
    set { UserDefaults.standard.set(newValue, forKey: Constant.assistantCodeUnlockedKey) }
}
```

This is the **sole source of truth** for whether the user has redeemed a code. The backend has no record of who redeemed what.

The `reset()` method should also clear this key (for "Delete All Data").

### 2. API Client — Redeem Endpoint

**Files**: `ConvosAPIClient.swift`, `ConvosAPIClient+Models.swift`, `MockAPIClient.swift`

Add to `ConvosAPIClientProtocol`:
```swift
func redeemInviteCode(_ code: String) async throws -> ConvosAPI.RedeemCodeResponse
```

Models:
```swift
struct RedeemCodeRequest: Codable { let code: String }
struct RedeemCodeResponse: Codable { let success: Bool }
```

Error mapping in the client implementation:
- 200 → return response (success)
- 409 `CODE_ALREADY_REDEEMED` → treat as success (idempotency for retry-after-lost-response)
- 404 `CODE_NOT_FOUND` → throw `APIError.inviteCodeNotFound`
- 422 `CODE_INVALID_FORMAT` → throw `APIError.inviteCodeInvalidFormat`
- 429 → throw `APIError.rateLimitExceeded`

Add new `APIError` cases: `.inviteCodeNotFound`, `.inviteCodeInvalidFormat`, `.inviteCodeAlreadyRedeemed`

The 409 case needs special handling: the implementation should **not** throw — it should return success. This handles the edge case where the client redeemed the code, the server marked it used, but the response was lost. On retry the client gets 409, but it should still unlock locally.

### 3. Session Manager

**Files**: `SessionManagerProtocol.swift`, `SessionManager.swift`, `MockInboxesService.swift`

Add to protocol:
```swift
func redeemInviteCode(_ code: String) async throws
```

Implementation calls `apiClient.redeemInviteCode(code)`. On success (including 409-treated-as-success), sets `GlobalConvoDefaults.shared.assistantCodeUnlocked = true`.

### 4. Invite Code Entry View

**File**: `Convos/App Settings/InviteCodeEntryView.swift` (new)

A self-sizing sheet modal with:
- Title: "Additional assistants"
- Body text: "To invite Assistants into more convos, please enter your code below."
- Text field with placeholder "Invite code" — uppercase, 8 char max, auto-strips whitespace
- "Continue" button (disabled when empty or request in flight)
- Inline error label below the text field
- No explicit dismiss button — tapping the scrim dismisses

State management:
```swift
@State private var code: String = ""
@State private var isSubmitting: Bool = false
@State private var errorMessage: String?
```

On submit:
1. Set `isSubmitting = true`, clear `errorMessage`
2. Call `session.redeemInviteCode(code)`
3. On success → dismiss sheet, callback to enable the toggle
4. On error → set `errorMessage` based on error type:
   - `.inviteCodeNotFound` → "No invite code found with that value"
   - `.inviteCodeInvalidFormat` → "Code must be 8 letters"
   - `.rateLimitExceeded` → "Too many attempts, try again later"
   - Other → "Something went wrong, try again"
5. Set `isSubmitting = false`

### 5. Gate the Toggle

**File**: `Convos/App Settings/AssistantSettingsView.swift`

Replace the direct `$defaults.assistantsEnabled` binding with a custom binding:

```swift
@State private var presentingCodeEntry: Bool = false

// Custom binding that intercepts toggle-ON when not unlocked
var assistantsToggleBinding: Binding<Bool> {
    Binding(
        get: { defaults.assistantsEnabled },
        set: { newValue in
            if newValue && !defaults.assistantCodeUnlocked {
                presentingCodeEntry = true
            } else {
                defaults.assistantsEnabled = newValue
            }
        }
    )
}
```

Add the sheet:
```swift
.selfSizingSheet(isPresented: $presentingCodeEntry) {
    InviteCodeEntryView(onUnlocked: {
        defaults.assistantsEnabled = true
    })
}
```

When the code is redeemed successfully, `onUnlocked` fires → the toggle turns ON. On subsequent uses, the toggle works freely because `assistantCodeUnlocked` is `true`.

### 6. Gate Pull-to-Add and Menu

No changes needed. The pull-to-add gesture and "+" menu already check `GlobalConvoDefaults.shared.assistantsEnabled`. If the user hasn't redeemed a code:
- The toggle defaults to `true` (current behavior)
- But wait — this means assistants work without a code by default

**This is the key design question.** The PRD says the toggle gates the feature. Two options:

**Option A**: Change `assistantsEnabled` default to `false` when `assistantCodeUnlocked` is `false`:
```swift
var assistantsEnabled: Bool {
    get {
        guard assistantCodeUnlocked else { return false }
        return UserDefaults.standard.object(forKey: Constant.assistantsEnabledKey) as? Bool ?? true
    }
    ...
}
```

**Option B**: Add a separate check at the assistant join points that gates on `assistantCodeUnlocked`, independent of the toggle.

**Recommendation**: Option A is cleaner. If the user hasn't unlocked, `assistantsEnabled` returns `false`, which disables pull-to-add and the menu item automatically. The toggle in settings still appears but intercepted when tapped ON.

### 7. Test Mocks

Update `MockInboxesService` and test session managers with stub `redeemInviteCode` implementations.

### 8. Files Changed Summary

| File | Change |
|------|--------|
| `Convos/App Settings/GlobalConvoDefaults.swift` | Add `assistantCodeUnlocked`, gate `assistantsEnabled` default |
| `Convos/App Settings/AssistantSettingsView.swift` | Custom toggle binding, present code entry sheet |
| `Convos/App Settings/InviteCodeEntryView.swift` | New file — code entry modal |
| `ConvosCore/.../API/ConvosAPIClient.swift` | Add `redeemInviteCode` method |
| `ConvosCore/.../API/ConvosAPIClient+Models.swift` | Add request/response models |
| `ConvosCore/.../API/MockAPIClient.swift` | Add mock |
| `ConvosCore/.../Sessions/SessionManagerProtocol.swift` | Add protocol method |
| `ConvosCore/.../Sessions/SessionManager.swift` | Add implementation |
| `ConvosCore/.../Inboxes/MockInboxesService.swift` | Add mock |
| `ConvosTests/ConversationViewModelGlobalDefaultsTests.swift` | Add stub |
| `ConvosTests/NewConversationViewModelRetryTests.swift` | Add stub |

### 9. Edge Cases

| Scenario | Handling |
|----------|----------|
| Network loss mid-redemption | Error shown, user retries. If server redeemed but response lost, retry gets 409 → treated as success |
| User toggles OFF after unlocking | Toggle works normally — `assistantCodeUnlocked` stays `true` |
| "Delete All Data" | `reset()` clears `assistantCodeUnlocked` — user needs a new code |
| Fresh install | UserDefaults cleared — user needs a new code (per PRD) |
| Code with lowercase input | Uppercased locally before sending (backend also normalizes) |
| Empty/whitespace code | "Continue" button disabled |
| Rapid tapping "Continue" | Button disabled while `isSubmitting` is true |

### 10. What This Does NOT Do

- No changes to `FeatureFlags` — that remains an independent environment-level kill switch
- No gating of existing conversations that already have assistants
- No server-side unlock state query
- No cross-device sync of unlock state
