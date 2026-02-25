# Fix: Join Flow Discovery

## Problem

When a user joins a conversation via invite, the join gets stuck at "Verifying" indefinitely. The joiner's conversation stream does not deliver the new group after the host adds them. The fallback path (`discoverNewConversations`) only runs on app lifecycle resume, which does not reliably trigger for the joiner's inbox.

## Root Cause

Two issues combine to cause the stuck join:

### 1. Conversation stream cannot discover groups added after subscription

The XMTP conversation stream subscribes to the client's known group topics at stream creation time. When the joiner is added to a new group after the stream starts, the stream has no subscription for that group and never delivers it. Only `syncAllConversations` + `listGroups` can discover groups the client was added to after stream startup.

### 2. `discoverNewConversations` doesn't run reliably for the joiner's inbox

The existing fallback (`discoverNewConversations`) runs:
- Once at initial startup — before the join happens, so too early
- On app resume via `handleResume` — but this requires a clean `.paused` → `.resume` transition in the `SyncingManager`

The resume path fails for two reasons:

**a) Duplicate `MessagingService` instances:** `SessionManager.messagingServiceSync()` is not safe against concurrent calls. It checks `getAwakeService()` (nonisolated), creates a new `MessagingService` with its own `SyncingManager`, then registers asynchronously via `Task`. Two concurrent calls both see `nil`, both create services with independent `SyncingManager` instances, and only one gets tracked. The untracked service's `SyncingManager` runs orphaned streams.

**b) `SyncingManager` state not properly paused:** When the app backgrounds, the `InboxStateMachine` sends `.enterBackground` → `syncingManager.pause()`. But if the `SyncingManager` is still in `.starting` state (initial sync not yet complete), the pause is deferred via `pauseOnComplete: true`. If the foreground event arrives before sync completes, or if the `SyncingManager` is the orphaned duplicate that was never properly tracked, the pause/resume cycle breaks. The `SyncingManager` stays in `.ready` and rejects the `.resume` action with "Invalid state transition: ready -> resume". Since `discoverNewConversations` only runs inside `handleResume`, it never executes.

## Solution

### Part 1: Fix `messagingServiceSync` duplicate creation

`SessionManager.messagingServiceSync()` must not create duplicate services. Options:
- Make it synchronously check-and-set using the `OSAllocatedUnfairLock`-based cache
- Or make the registration synchronous instead of fire-and-forget `Task`

### Part 2: Add `requestDiscovery()` to `SyncingManager`

Add a method that triggers `syncAllConversations` + `discoverNewConversations` on demand, callable from outside the lifecycle/resume path.

```swift
// SyncingManagerProtocol
func requestDiscovery() async

// SyncingManager implementation
func requestDiscovery() async {
    guard case .ready(let params) = _state else { return }
    do {
        _ = try await params.client.conversationsProvider.syncAllConversations(
            consentStates: params.consentStates
        )
        await discoverNewConversations(params: params)
    } catch {
        Log.error("requestDiscovery failed: \(error)")
    }
}
```

### Part 3: Expose through `InboxStateManager`

Thread `requestDiscovery()` through the existing protocol chain so `ConversationStateMachine` can call it:

```
ConversationStateMachine → InboxStateManager → InboxStateMachine → SyncingManager
```

### Part 4: Call from `ConversationStateMachine.handleJoin`

**Root cause confirmed by XMTP SDK investigation:** The conversation stream (`StreamConversations`) does NOT call `sync_welcomes()` at startup, unlike `StreamAllMessages` which does. This means the stream will never discover groups added after the stream subscribed — it only watches already-known topics.

This isn't a race condition or timing issue — the stream is structurally unable to deliver new groups the client is added to. `syncAllConversations` (which calls `sync_welcomes` internally) is the only way to discover them.

**Approach:** Run a discovery loop alongside the DB observation in `handleJoin`. After the join request is sent, periodically call `requestDiscovery()` with increasing intervals until the observation fires or the join is cancelled/fails.

```swift
// Alongside the observationTask, start a discovery loop
discoveryTask = Task { [weak self] in
    // Initial interval accounts for host processing time
    var interval: Duration = .seconds(3)
    let maxInterval: Duration = .seconds(15)

    while !Task.isCancelled {
        try await Task.sleep(for: interval)
        try Task.checkCancellation()

        Log.info("Triggering discovery for join flow...")
        await self?.inboxStateManager.requestDiscovery()

        // Back off: 3s, 6s, 12s, 15s, 15s, ...
        interval = min(interval * 2, maxInterval)
    }
}
```

Cancel `discoveryTask` in all exit paths (success, cancellation, error) alongside `observationTask`.

This compensates for the SDK gap: since the conversation stream can't discover new groups, we periodically sync welcomes ourselves. The DB observation fires as soon as `discoverNewConversations` processes the group.

**Why this isn't polling:** This is compensating for a missing `sync_welcomes()` call in the SDK's conversation stream. `StreamAllMessages` does this automatically at startup. We're doing the equivalent for the join flow. Once the XMTP SDK adds `sync_welcomes()` to `StreamConversations`, the stream would deliver the group and the observation would fire before the first discovery interval — making the loop a harmless no-op.

### Part 5: Fix orphaned `SyncingManager` lifecycle

Ensure that when duplicate `MessagingService` instances exist, their `SyncingManager` instances are properly stopped. The `registerExternalService` guard that skips registration should also stop the orphaned service's streaming.

## Files to Change

1. `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift` — fix `messagingServiceSync` race
2. `ConvosCore/Sources/ConvosCore/Syncing/SyncingManager.swift` — add `requestDiscovery()`
3. `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` — expose `requestDiscovery()`
4. `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateManager.swift` — add protocol + implementation
5. `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift` — call discovery
6. `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift` — stop orphaned services in `registerExternalService`
7. `ConvosCore/Sources/ConvosCore/Mocks/` — update mock implementations
