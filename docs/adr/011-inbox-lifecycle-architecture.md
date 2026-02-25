# ADR 011: Inbox Lifecycle Architecture

**Status:** Accepted  
**Date:** 2026-02-24  
**Context:** Technical debt documentation for post-1.1.0 release

## Summary

This document describes the architecture of the inbox lifecycle management system in Convos, including state machines, capacity management, and the flow between sleeping and awake inboxes.

## Context

Convos supports multiple XMTP inboxes per user (one per conversation for privacy). Managing many inboxes on a mobile device requires careful lifecycle management to balance:
- Memory usage (XMTP clients are heavy)
- Responsiveness (users expect instant conversation access)
- Background operations (push notifications, syncing)

## Architecture Overview

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                     InboxLifecycleManager                        │
│  - Manages awake/sleeping inbox pools                           │
│  - Enforces capacity limits (maxAwakeInboxes, maxPendingInvites)│
│  - LRU eviction when at capacity                                │
│  - Pending invite special handling                              │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐
│ MessagingService │  │ MessagingService │  │ UnusedConversation  │
│   (Inbox A)      │  │   (Inbox B)      │  │      Cache          │
│                  │  │                  │  │ - Pre-creates inboxes│
│ ┌──────────────┐ │  │ ┌──────────────┐ │  │ - Fast first convo  │
│ │InboxState    │ │  │ │InboxState    │ │  └─────────────────────┘
│ │Machine       │ │  │ │Machine       │ │
│ └──────────────┘ │  │ └──────────────┘ │
│ ┌──────────────┐ │  │ ┌──────────────┐ │
│ │Conversation  │ │  │ │Conversation  │ │
│ │StateMachine  │ │  │ │StateMachine  │ │
│ └──────────────┘ │  │ └──────────────┘ │
└─────────────────┘  └─────────────────┘
```

### Inbox States (InboxLifecycleManager)

```
                    ┌─────────────┐
                    │   (none)    │
                    └──────┬──────┘
                           │ createNewInbox()
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                         AWAKE                                 │
│  - MessagingService active                                   │
│  - XMTP client connected                                     │
│  - Streams subscribed                                        │
│  - Can send/receive messages                                 │
└──────────────────────────────────────────────────────────────┘
         │                                    ▲
         │ sleep() or                         │ wake()
         │ LRU eviction                       │
         ▼                                    │
┌──────────────────────────────────────────────────────────────┐
│                        SLEEPING                               │
│  - MessagingService stopped                                  │
│  - Tracked in sleepingClientIds                              │
│  - Can be woken on demand                                    │
│  - Sleep time recorded for LRU                               │
└──────────────────────────────────────────────────────────────┘
         │
         │ forceRemove() or
         │ stale cleanup
         ▼
┌──────────────────────────────────────────────────────────────┐
│                        REMOVED                                │
│  - Keychain identity deleted                                 │
│  - Database records deleted                                  │
│  - No longer tracked                                         │
└──────────────────────────────────────────────────────────────┘
```

### InboxStateMachine States

Each awake inbox has an `InboxStateMachine` managing its internal lifecycle:

```
┌─────────┐
│  idle   │ ◄─── Initial state with clientId
└────┬────┘
     │ authorize() or register()
     ▼
┌─────────────┐      ┌─────────────┐
│ authorizing │ ──── │ registering │  Building XMTP client
└──────┬──────┘      └──────┬──────┘
       │                    │
       └────────┬───────────┘
                ▼
     ┌─────────────────────┐
     │ authenticatingBackend│  Getting JWT from Convos API
     └──────────┬──────────┘
                ▼
         ┌───────────┐
         │   ready   │ ◄─── Fully operational
         └─────┬─────┘
               │ enterBackground
               ▼
        ┌──────────────┐
        │ backgrounded │ ──► enterForeground ──► ready
        └──────────────┘
               │ delete
               ▼
         ┌──────────┐
         │ deleting │ ──► stopping ──► (removed)
         └──────────┘
```

### ConversationStateMachine States

Each conversation has a state machine for creation/join flows:

```
┌───────────────┐
│ uninitialized │
└───────┬───────┘
        │ create() or validate(inviteCode)
        ▼
┌─────────────┐      ┌─────────────┐
│  creating   │      │ validating  │ Parsing invite code
└──────┬──────┘      └──────┬──────┘
       │                    │
       │                    ▼
       │             ┌───────────┐
       │             │ validated │ Invite verified, placeholder created
       │             └─────┬─────┘
       │                   │ join()
       │                   ▼
       │             ┌───────────┐
       │             │  joining  │ Waiting for XMTP group discovery
       │             └─────┬─────┘
       │                   │
       └─────────┬─────────┘
                 ▼
          ┌───────────┐
          │   ready   │ Conversation operational
          └───────────┘
```

## Capacity Management

### Limits

| Limit | Default | Purpose |
|-------|---------|---------|
| `maxAwakeInboxes` | 10 | Total awake inboxes (memory bound) |
| `maxAwakePendingInvites` | 3 | Pending invite inboxes (subset of above) |
| `stalePendingInviteInterval` | 24 hours | Auto-cleanup threshold |

### LRU Eviction

When at capacity and a new inbox needs to wake:

1. Find the least recently used inbox (by `sleepTime`)
2. Exclude: active inbox, pending invite inboxes (if under cap)
3. Sleep the selected inbox
4. Wake the requested inbox

### Pending Invite Protection

Inboxes with pending invites (shared link waiting for someone to join) get special treatment:
- Protected from LRU eviction up to `maxAwakePendingInvites`
- Automatically cleaned up after `stalePendingInviteInterval` (24 hours)
- Can exceed normal capacity if needed for UX

## Wake Reasons

```swift
public enum WakeReason: String {
    case userInteraction   // User opened a conversation
    case pushNotification  // Push notification received
    case activityRanking   // Rebalance based on recent activity
    case pendingInvite     // Inbox has pending invite
    case appLaunch         // Initial app launch wake
}
```

## Key Flows

### Opening a Conversation

```
User taps conversation
        │
        ▼
InboxLifecycleManager.getOrWake(clientId, inboxId)
        │
        ├─► Already awake? Return service
        │
        ├─► At capacity? sleepLeastRecentlyUsed()
        │
        └─► attemptWake()
                │
                ├─► Check pending invite status
                ├─► Create MessagingService
                ├─► Add to awakeInboxes
                └─► Return service
```

### Creating a New Conversation

```
User taps "New Conversation"
        │
        ▼
InboxLifecycleManager.createNewInbox()
        │
        ├─► At capacity? sleepLeastRecentlyUsed()
        │
        └─► UnusedConversationCache.consumeOrCreateMessagingService()
                │
                ├─► Has pre-warmed inbox? Use it
                │
                └─► Create new inbox + conversation
                        │
                        └─► Return (service, conversationId)
```

### App Launch Initialization

```
App launches
        │
        ▼
InboxLifecycleManager.initializeOnAppLaunch()
        │
        ├─► cleanupStalePendingInvites() // Remove >24h old
        │
        ├─► Fetch all inbox activities from DB
        │
        ├─► Wake pending invite inboxes (up to cap)
        │
        ├─► Wake most recently active inboxes (up to cap)
        │
        └─► Mark remaining as sleeping
```

## Edge Cases

### Race Conditions

- **Re-wake during sleep**: If an inbox is woken while `service.stop()` is running, we detect this and don't mark it as sleeping
- **Duplicate registration**: `registerExternalService` checks if already tracked before adding
- **Concurrent eviction**: Double-check state after eviction completes

### Stale Data

- **Orphaned identities**: Cleaned up on app launch if no matching inbox in DB
- **Stale pending invites**: Auto-deleted after 24 hours on app launch

## Testing Considerations

- Use deterministic time for sleep time comparisons
- Inject mock repositories for pending invite checks
- Test capacity edge cases (at limit, over limit, eviction)
- Test race conditions with concurrent operations

## Related Files

- `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift`
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift`
- `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift`
- `ConvosCore/Sources/ConvosCore/Messaging/UnusedConversationCache.swift`
- `ConvosCore/Sources/ConvosCore/Messaging/MessagingService.swift`

## References

- [ADR 003: Inbox Lifecycle Management](003-inbox-lifecycle-management.md) - Original ADR for multi-inbox support
