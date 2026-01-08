# ADR 003: Inbox Lifecycle Management with LRU Eviction

## Status

Accepted

## Context

Convos uses a per-conversation identity model where each conversation has its own XMTP inbox (see ADR 002). While this provides strong privacy benefits, it creates a resource management challenge: each active XMTP inbox consumes significant system resources.

### Resource Constraints

Each active XMTP inbox requires:

1. **Database Connection**: Each XMTP client maintains its own SQLite database connection for local message storage
2. **gRPC Streams**: Each inbox maintains persistent gRPC streams to the XMTP network for real-time message delivery
3. **Memory**: In-memory state for the XMTP client, message streams, and conversation data
4. **File Descriptors**: Each database connection and network socket consumes a file descriptor

On iOS devices, these resources are finite:
- SQLite has practical limits on concurrent connections (typically 5-10 before performance degrades)
- Too many open gRPC streams cause network performance issues and increased battery drain
- Memory pressure triggers aggressive eviction by iOS
- File descriptor limits can be exceeded with many simultaneous connections

Users may have dozens or hundreds of conversations, but only a small subset are actively used at any given time. Keeping all inboxes active simultaneously is neither necessary nor feasible.

### Latency Concerns

Creating a new XMTP inbox involves:
1. Generating cryptographic keys (secp256k1)
2. Initializing an XMTP client
3. Establishing gRPC connections to XMTP network
4. Setting up local database encryption

This process takes 1-3 seconds, creating noticeable latency when users create or join conversations.

## Decision

We implemented an **Inbox Lifecycle Management** system with three key components:

1. **Capacity-Limited Active Set**: Maximum 20 "awake" inboxes at any time
2. **LRU Eviction**: Least recently used inboxes are automatically "slept" when capacity is exceeded
3. **Pre-creation Cache**: Background pre-creation of unused inboxes to eliminate perceived latency

### 1. InboxLifecycleManager: Capacity and LRU Eviction

The `InboxLifecycleManager` maintains a capacity-limited set of active ("awake") inboxes and evicts least recently used inboxes when capacity is exceeded.

**Capacity Limit:**
- Maximum 20 awake inboxes (configurable, default in production)
- Limit chosen based on resource bottlenecks:
  - Database connections: SQLite performance degrades with >10 concurrent connections
  - gRPC streams: Network and battery impact with many persistent streams
  - Memory: iOS memory limits make hundreds of active clients infeasible

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift:95`

**States:**

An inbox can be in one of three states:
- **Awake**: XMTP client active, database connection open, gRPC streams connected, consuming resources
- **Sleeping**: XMTP client stopped, all resources released, tracked in set but not consuming resources
- **Not Tracked**: No record in lifecycle manager (e.g., deleted inbox or not yet initialized)

**State Transitions:**

```
Not Tracked --> Awake (via wake() or createNewInbox())
Awake --> Sleeping (via sleep() or LRU eviction)
Sleeping --> Awake (via wake())
Awake/Sleeping --> Not Tracked (via forceRemove() during deletion)
```

**LRU Eviction:**

When the capacity limit is reached and a new inbox needs to be awoken, the lifecycle manager evicts the least recently used inbox:

1. Query `InboxActivityRepository` for all inboxes sorted by last message timestamp
2. Find the last inbox in the list (least recently used) that is:
   - Currently awake
   - Not the active inbox (conversation currently open)
   - Not protected (doesn't have pending invites)
   - Not in the exclusion set
3. Sleep that inbox to free capacity
4. Wake the new inbox

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift:394-417`

**Protected Inboxes:**

Certain inboxes are exempt from LRU eviction:
- **Active Inbox**: The inbox whose conversation is currently open in the UI
- **Pending Invites**: Inboxes with pending join requests (must stay awake to process incoming responses)

These inboxes can cause the awake count to exceed `maxAwakeInboxes`, which is acceptable because they represent user-facing operations that must not be interrupted.

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift:178-191`

### 2. Activity Tracking

The `InboxActivityRepository` tracks inbox usage based on message timestamps, providing the data needed for LRU eviction decisions.

**Activity Metric:**

Activity is measured by the timestamp of the most recent message in any conversation for that inbox:

```sql
SELECT
    i.clientId,
    i.inboxId,
    MAX(m.date) as lastActivity,
    COUNT(DISTINCT c.id) as conversationCount
FROM inbox i
LEFT JOIN conversation c ON c.clientId = i.clientId
LEFT JOIN message m ON m.conversationId = c.id
GROUP BY i.clientId, i.inboxId
ORDER BY lastActivity DESC NULLS LAST
```

Inboxes are ordered by `lastActivity` descending, so the most recently active inboxes appear first and the least recently active appear last.

**Null Handling:**

Inboxes with no messages have `lastActivity = NULL` and are sorted to the end (least recently used), making them prime candidates for eviction.

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Repositories/InboxActivityRepository.swift:88-111`

### 3. UnusedInboxCache: Pre-creation Optimization

The `UnusedInboxCache` maintains a pool of pre-created "unused" inboxes that can be instantly consumed when users create or join conversations.

**How It Works:**

1. **Background Creation**: When the cache is empty, a new XMTP inbox is created in the background (typically on app launch or after consuming the previous unused inbox)
2. **Keychain Storage**: The unused inbox ID is stored in keychain (not in the database, to prevent it from appearing in the inbox list)
3. **Instant Consumption**: When a user creates or joins a conversation, the pre-created inbox is immediately available
4. **Automatic Replenishment**: After consuming an unused inbox, a new one is created in the background for next time

**Latency Benefit:**

- **Without cache**: 1-3 seconds to create inbox (blocking UI)
- **With cache**: <100ms to consume pre-created inbox (feels instant)

**Cache Size:**

The cache maintains only 1 pre-created inbox at a time:
- Larger cache would waste resources (keychain storage, unused database connections)
- Single inbox is sufficient since background creation is fast enough to replenish between user actions
- Keeps implementation simple

**Storage:**

Unused inboxes are stored in two places:
- **In-Memory**: `unusedMessagingService` holds the active XMTP client (if ready)
- **Keychain**: `KeychainAccount.unusedInbox` stores the inbox ID (if client not yet ready)

This dual storage ensures the cache survives app restarts while still providing instant access when the XMTP client is already initialized.

**Location:** `ConvosCore/Sources/ConvosCore/Messaging/UnusedInboxCache.swift:322-379`

### 4. Rebalance and App Launch

**Rebalance:**

The `rebalance()` method reconciles the awake inbox set with the ideal state based on activity:

1. Identify protected inboxes (active + pending invites)
2. Calculate available slots: `maxAwakeInboxes - protectedCount`
3. Select top N most active inboxes (by last message timestamp) to fill remaining slots
4. Sleep inboxes that shouldn't be awake
5. Wake inboxes that should be awake but aren't

Rebalance is called periodically or after significant state changes to ensure optimal resource usage.

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift:261-308`

**App Launch Initialization:**

On app launch, the lifecycle manager initializes the awake set:

1. Query all inbox activities from the database
2. Query all pending invites
3. Wake inboxes with pending invites (always, can exceed capacity)
4. Wake top N most active inboxes (up to `maxAwakeInboxes`)
5. Mark remaining inboxes as sleeping

This ensures users see their most recent conversations immediately while respecting resource limits.

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift:310-362`

### 5. Wake Reasons

The system tracks why inboxes are woken for observability and debugging:

```swift
public enum WakeReason: String {
    case userInteraction    // User opened conversation
    case pushNotification   // Incoming push notification
    case activityRanking    // Rebalance based on activity
    case pendingInvite      // Inbox has pending join requests
    case appLaunch          // App launch initialization
}
```

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift:4-10`

## Consequences

### Positive

- **Scalable**: Users can have hundreds of conversations without resource exhaustion
- **Performant**: Only active conversations consume system resources
- **Instant UX**: Pre-creation cache eliminates perceived latency for conversation creation
- **Automatic**: LRU eviction requires no user intervention or manual management
- **Resource-Efficient**: Database connections and gRPC streams limited to 20 simultaneous
- **Battery-Friendly**: Fewer persistent connections reduce battery drain
- **Predictable**: Protected inboxes ensure critical operations never fail due to eviction

### Negative

- **Complexity**: Sophisticated state management with sleep/wake transitions
- **Waking Latency**: Sleeping inboxes take ~500ms-1s to wake (re-establish gRPC streams)
- **Edge Cases**: Race conditions possible during concurrent wake/sleep operations (mitigated by Swift actor isolation)
- **Memory Overhead**: Tracking state for all inboxes (awake, sleeping, activity) consumes memory
- **Cache Waste**: Unused inbox may never be consumed if user doesn't create conversations

### Mitigations

1. **Actor Isolation**: `InboxLifecycleManager` is a Swift actor, preventing data races
2. **Protected Inboxes**: Active inbox and pending invites exempt from eviction
3. **Fail-Open**: Pending invite checks fail open (assume true) to prevent breaking critical flows
4. **Background Creation**: Pre-creation happens in background, never blocking user actions
5. **Graceful Degradation**: If cache is empty, falls back to synchronous creation

### Trade-offs

| Aspect | Chosen Approach | Alternative | Rationale |
|--------|----------------|-------------|-----------|
| Capacity limit | 20 awake inboxes | No limit (all awake) | Resource constraints make unlimited infeasible |
| Eviction policy | LRU (last message) | Random or FIFO | LRU preserves user's most recent conversations |
| Cache size | 1 unused inbox | Multiple or none | Single inbox balances latency reduction with resource usage |
| Protection | Active + pending invites | Active only | Pending invites must stay awake to process responses |
| Activity metric | Last message timestamp | Last open time | Message timestamp is durable (survives app restarts) |

## Performance Characteristics

### Capacity Limits and Resource Usage

| Scenario | Awake Inboxes | Database Connections | gRPC Streams | Memory Estimate |
|----------|---------------|---------------------|--------------|-----------------|
| Idle user (no conversations) | 1 (unused) | 1 | 1 | ~5 MB |
| Typical user (10 conversations) | 10 | 10 | 10 | ~30 MB |
| Heavy user (100 conversations) | 20 (capacity limit) | 20 | 20 | ~60 MB |
| Edge case (pending invites) | 25 (exceeds capacity) | 25 | 25 | ~75 MB |

### Latency

| Operation | With Cache | Without Cache | Improvement |
|-----------|-----------|---------------|-------------|
| Create conversation | <100 ms | 1-3 seconds | 10-30x faster |
| Join via invite | <100 ms | 1-3 seconds | 10-30x faster |
| Wake sleeping inbox | 500 ms - 1 s | N/A | Reconnect gRPC streams |
| Rebalance | <50 ms | N/A | Query + state updates |

## Related Files

**Lifecycle Management:**
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift` - Core lifecycle manager with LRU eviction
- `ConvosCore/Sources/ConvosCore/Messaging/UnusedInboxCache.swift` - Pre-creation cache

**Activity Tracking:**
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/InboxActivityRepository.swift` - Activity queries

**Related ADRs:**
- ADR 002: Per-Conversation Identity Model (explains why lifecycle management is needed)
- ADR 004: Explode Feature (uses inbox deletion process for conversation explosions)
- ADR 005: Profile Storage in Conversation Metadata (per-conversation profiles rely on per-conversation identities)

## References

- SQLite Concurrency: https://www.sqlite.org/threadsafe.html
- gRPC Performance Best Practices: https://grpc.io/docs/guides/performance/
- iOS Memory Management: https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use
- Swift Actors: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
