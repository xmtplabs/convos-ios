# Conversation Creation Retry Resilience

## Problem

When the XMTP network is unavailable (DNS errors, service outages), the conversation creation flow enters a destructive retry loop:

1. User taps "+" to create a conversation
2. `NewConversationViewModel` acquires an inbox via `session.addInbox()` → `UnusedConversationCache.consumeOrCreateMessagingService()`
3. The `ConversationStateMachine` transitions: `uninitialized → creating → error`
4. Error sheet appears: "Couldn't create — Please try again"
5. User taps retry → `displayError = nil` → triggers `resetFromError()` → `uninitialized`
6. `configureWithMessagingService` is called again, re-entering the create loop
7. Meanwhile the **unused conversation cache** starts registering a new inbox in the background
8. The next attempt also fails, and the cycle repeats

### Observed in logs (user session 2026-03-17, 16:37-16:43)

- **11 unique clientIds** created in ~6 minutes
- Only **1** was cleaned up (`deleteInbox`)
- Each retry creates a new XMTP identity registration on the network
- Error messages are generic: "Couldn't create — Please try again" / "Something went wrong"
- No backoff between retries — failures at 16:37:32, 16:37:36, 16:37:43, 16:37:46, 16:38:00, 16:38:01, 16:38:09, 16:38:13 (roughly every 2-5 seconds)

### Root causes

1. **Inbox leak on retry**: When the user dismisses-and-retries or the error sheet triggers a retry, the existing `NewConversationViewModel` is deallocated (deinit logged), but the messaging service it acquired is not always deleted — only `dismissWithDeletion()` calls `deleteConversation()`, while the retry path creates a fresh inbox
2. **UnusedConversationCache creates new inboxes eagerly**: After consuming the cached unused conversation, the cache immediately starts creating a replacement, which also fails and creates another orphaned inbox registration
3. **No exponential backoff**: The `ConversationStateMachine` retries immediately after `resetFromError()`, and the UI allows instant retry taps
4. **Generic error messages**: "Something went wrong. Please try again." doesn't tell the user their network is down
5. **ConversationStateMachine retry does not reuse the same inbox**: Each `resetFromError` → `createConversation` cycle uses the same inbox, but if the user dismisses and re-opens the compose sheet, a brand new inbox is created
6. **Parallel inbox creation**: Both the unused conversation cache background task AND the foreground new-conversation flow register inboxes simultaneously, doubling the leak rate

## Plan

### Phase 1: Reuse inbox on retry (prevent leak)

**Goal**: When `createConversation` fails, retry using the same inbox/clientId instead of creating a new one.

#### Changes

**`NewConversationViewModel`** — Keep the acquired messaging service across retries:
- When `handleErrorState` is called for a `.stateMachineError` (network/DNS), do NOT deallocate the messaging service
- The retry action (`.createConversation`) should call `conversationStateManager.createConversation()` which already reuses the same inbox — this path works correctly today
- The problem is when the user **dismisses the error sheet without retrying** (taps close button), then the `NewConversationViewModel` is deallocated without calling `deleteConversation()`

**`NewConversationViewModel.deinit`** — Clean up on dealloc:
- If `conversationState` is `.error` or `.creating` (not `.ready`), call `deleteConversation()` to clean up the inbox
- This prevents orphaned inboxes when the user closes the compose sheet during an error state

**`UnusedConversationCache`** — Pause background inbox creation during network errors:
- After a `createConversationForExistingInbox` failure with a network error, do NOT immediately retry or create a new inbox
- Add a `lastNetworkError: Date?` timestamp; skip background replenishment for 30 seconds after a network error
- The `consumeOrCreate` path already handles the "no unused conversation" case by creating inline, so this is safe

### Phase 2: Exponential backoff on conversation creation

**Goal**: Prevent rapid-fire retries that hammer a down network.

#### Changes

**`ConversationStateMachine`** — Add backoff to the create action:
- Track `createRetryCount: Int` (reset on success or manual reset)
- Before executing `.create`, if `createRetryCount > 0`, wait: `min(2^retryCount, 30)` seconds
- Cap at 3-5 automatic retries before requiring user action
- On `.reset` action, do NOT reset the retry count (it resets only on success)

**`NewConversationViewModel`** — Show retry state in UI:
- When the state machine is in backoff-wait, show a "Retrying in Xs..." message instead of the spinner
- After max retries, show error sheet with manual retry button

**Alternative (simpler)**: Instead of automatic backoff in the state machine, rely on the existing error sheet flow but add a delay:
- In `retryAction(.createConversation)`, add a 2-second delay before calling `createConversation()` again
- On the 3rd consecutive failure, change the error message to suggest checking network connectivity
- This is simpler and keeps retry logic in the ViewModel rather than the state machine

**Recommendation**: Go with the simpler alternative first. The state machine should not manage backoff — it's a UI/UX concern.

### Phase 3: Better error classification and messages

**Goal**: Show "Network unavailable" instead of "Something went wrong".

#### Changes

**`ConversationStateMachineError`** — Add network error classification:
- Add a computed property `isNetworkError: Bool` that checks the underlying XMTP error message for known patterns:
  - `"dns error"`
  - `"The service is currently unavailable"`
  - `"The request timed out"`
  - `"The Internet connection appears to be offline"`
  - `"A data connection is not currently allowed"`
- This avoids depending on specific XMTP error types (which are opaque `FfiError.Error`)

**`NewConversationViewModel.handleErrorState`** / `showRetryableError`:
- If `error.isNetworkError`, show: title="Can't connect", description="Check your internet connection and try again."
- If not network: keep current "Something went wrong" message

**`NewConversationViewModel.handleCreationError`**:
- Same classification for the `autoCreateConversation` path

### Phase 4: Unused conversation cache resilience

**Goal**: Prevent the unused conversation cache from leaking inboxes during network outages.

#### Changes

**`UnusedConversationCache.createConversationForExistingInbox`**:
- On network error (classify same as Phase 3), keep the inbox but don't clear the keychain
- Log the failure but retry on next `prepareUnusedConversationIfNeeded` call
- Currently: failure → `Log.error("Failed to create conversation for unused inbox")` → the inbox remains alive but the keychain reference may be lost depending on the error path

**`UnusedConversationCache.prepareUnusedConversationIfNeeded`**:
- Add a cooldown: if the last preparation attempt failed with a network error less than 30 seconds ago, skip
- Store `lastPrepareFailure: Date?` on the cache actor

**`InboxLifecycleManager`**:
- When `createNewInbox()` is called and the unused cache has a failed-but-reusable inbox, try to reuse it instead of creating a brand new one
- This requires the cache to distinguish between "inbox created but conversation creation failed" vs "no inbox at all"

## Implementation order

1. **Phase 3** (error classification) — smallest change, immediate UX improvement
2. **Phase 1** (deinit cleanup + reuse) — prevents the core leak
3. **Phase 2** (backoff) — prevents hammering
4. **Phase 4** (cache resilience) — prevents background leak amplification

## Testing

- Unit tests: Mock XMTP client that throws network errors, verify:
  - Same clientId reused across retries
  - Inbox deleted on deinit during error state
  - Error messages contain "network" language for DNS errors
  - Backoff delay increases between retries
- Manual QA: Put device in airplane mode, tap "+", verify error message says "Can't connect", retry a few times, verify no inbox leak in logs

## Files to modify

- `Convos/Conversation Creation/NewConversationViewModel.swift` — deinit cleanup, error messages, retry delay
- `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift` — error classification
- `ConvosCore/Sources/ConvosCore/Storage/Models/ConversationStateMachineError+Network.swift` — new file for network error detection
- `ConvosCore/Sources/ConvosCore/Messaging/UnusedConversationCache.swift` — cooldown, reuse failed inbox
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift` — reuse failed unused inbox

## Out of scope

- Server-side cleanup of orphaned XMTP inbox registrations (requires backend work)
- NWPathMonitor-based network reachability detection (useful but separate feature)
- Automatic retry when network comes back (could use NWPathMonitor, but separate PR)
