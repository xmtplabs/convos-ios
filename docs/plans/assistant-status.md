# Assistant Join Status — Message-Based Persistence with XMTP Broadcast

## Context

When a user adds an assistant to a conversation via the "+" menu, the app calls `POST /api/v2/agents/join`. This call can take up to ~30 seconds. The initial implementation used transient ViewModel state (with a static dictionary for navigation survival) to show inline feedback. This worked but had limitations:

- **Lost on navigation**: the state lived in the ViewModel, which is deallocated when navigating away
- **Lost on app kill**: the pending state disappeared if the app was terminated mid-request
- **Local-only state**: other members had no visibility into whether an assistant was being requested

This v2 moves assistant join status into GRDB as stored messages and broadcasts via XMTP so all group members can see it.

## Goal

1. **Persist** assistant join status in GRDB as messages so it survives app kills and navigation
2. **Broadcast** all status changes via XMTP so all members see "Louis invited an assistant to join"
3. **Keep errors local** — only the requester sees error/retry states (errors are broadcast as XMTP messages but auto-dismiss quickly on other devices)

## Design Decisions

### Stored as messages, not conversation columns

Early iterations stored status as columns on `DBConversation` (`assistantJoinStatus`, `assistantJoinRequestedBy`). This required:
- Preserving status during conversation re-stores from XMTP metadata
- Pass-through in every `with()` method on `DBConversation`
- Custom `StreamProcessor` interception to write status to conversation columns
- Imperative clearing when an agent joined

The final implementation stores `AssistantJoinRequest` as regular `DBMessage` rows via the standard message pipeline. Status is derived at read time via a CTE query. This is simpler because:
- XMTP broadcasts naturally become DB messages through the existing pipeline
- No preservation logic needed during conversation re-stores
- Agent-joined clearing is declarative (hydration checks if any agent member exists)
- Time-based expiry happens at read time with no cleanup writes

### Broadcast all statuses

When a user requests an assistant, an XMTP message is sent to the group for each status change (pending, error, etc.). Error states auto-dismiss quickly (3s) so other members effectively only see the pending state. The requester also sees errors briefly.

### Status cleared by agent presence, not explicit clearing

Rather than imperatively clearing status when an agent joins, the hydration layer checks `!members.contains(where: { $0.isAgent })`. If an agent is present, no status is surfaced regardless of what messages exist. This eliminates race conditions around clearing.

### Time-based auto-dismiss

Status messages have a `displayDuration` that controls how long they appear:
- `.pending`: 15 seconds
- `.noAgentsAvailable`, `.failed`: 3 seconds

The `MessagesListProcessor` filters out expired status messages at process time. `MessagesListRepository` schedules a timer to reprocess messages when the display window expires, causing the status row to disappear without any DB writes.

## Design Spec

### States & Visual Treatment

Inline centered rows in the messages list (rendered as synthetic cells from stored messages):

#### 1. Pending — requester's view
- Text: **"Assistant is joining…"**
- Color: `color/text/tertiary`
- Not tappable

#### 2. Pending — other members' view
- Text: **"Louis invited an assistant to join"**
- Color: `color/text/tertiary`
- Not tappable

#### 3. "No assistants are available" (503 — requester only)
- **Replaces** the pending row
- Prepended with gray circle + SF Symbol `xmark`
- Not tappable

#### 4. "Assistant could not join" (502/504 — requester only)
- **Replaces** the pending row
- Prepended with gray circle + SF Symbol `arrow.clockwise`
- **Tappable** — retries the join

#### 5. Success (all members)
- The existing `ConversationUpdate` with `addedAgent == true` arrives via XMTP
- The status is no longer surfaced (agent presence detected in hydration)
- The real "joined by invitation" update + `AssistantJoinedInfoView` display as today

### State Transitions

#### Requester's device
```
User taps "Instant assistant"
  │
  ├─ 1. Broadcast AssistantJoinRequest(status: .pending) via XMTP
  ├─ 2. Fire POST /api/v2/agents/join
  │
  ▼
[Pending] "Assistant is joining…" (visible for 15s)
  │
  ├─ API returns 200 ──► Keep .pending, wait for agent to join
  │
  ├─ API returns 503 ──► Broadcast .noAgentsAvailable (visible 3s, then auto-dismiss)
  │
  ├─ API returns 502/504 ► Broadcast .failed (visible 3s, then auto-dismiss)
  │                              │
  │                              └─ User taps retry ──► Broadcast new .pending
  │
  ├─ displayDuration expires ──► Status row disappears (no DB write)
  │
  └─ Agent joins group ──► Status not surfaced (agent presence check)
```

#### Other members' devices
```
Receive XMTP AssistantJoinRequest message
  │
  ├─ Stored as DBMessage via standard pipeline
  ├─ MessagesListProcessor renders synthetic cell
  │
  ▼
[Pending] "Louis invited an assistant to join" (visible for 15s)
  │
  ├─ Agent joins group ──► Status not surfaced (agent presence check)
  │
  ├─ displayDuration expires ──► Status row disappears
  │
  └─ Error broadcast received ──► Visible for 3s, then auto-dismiss
```

---

## Data Model

### GRDB migration

```swift
migrator.registerMigration("addAssistantJoinRequestIndex") { db in
    try db.create(
        index: "message_assistantJoinRequest_conversationId",
        on: "message",
        columns: ["conversationId", "contentType", "dateNs"],
        condition: Column("contentType") == MessageContentType.assistantJoinRequest.rawValue
    )
}
```

A partial index on the `message` table for efficient CTE queries. Only indexes rows with `contentType = "assistantJoinRequest"`.

### `AssistantJoinStatus` enum

```swift
public enum AssistantJoinStatus: String, Equatable, Hashable, Sendable, Codable {
    case pending
    case noAgentsAvailable = "no_agents_available"
    case failed

    public var displayDuration: TimeInterval {
        switch self {
        case .pending: 15
        case .noAgentsAvailable, .failed: 3
        }
    }
}
```

### `DBAssistantJoinRequest`

Lightweight model for CTE query results:

```swift
struct DBAssistantJoinRequest: Codable, FetchableRecord, Hashable {
    let conversationId: String
    let status: String
    let date: Date
}
```

### CTE query: `latestAssistantJoinRequestCTE`

Derives the latest assistant join request per conversation from the `message` table:

```sql
SELECT m.conversationId, m.text AS status, m.date
FROM message m
WHERE m.contentType = 'assistantJoinRequest'
AND m.dateNs = (
    SELECT MAX(m2.dateNs) FROM message m2
    WHERE m2.conversationId = m.conversationId
    AND m2.contentType = 'assistantJoinRequest'
)
```

### XMTP custom content type: `AssistantJoinRequestCodec`

Follows the `ExplodeSettingsCodec` pattern — JSON-encoded, silent (no push), registered in `InboxStateMachine`.

```swift
public struct AssistantJoinRequest: Codable, Sendable {
    public let status: AssistantJoinStatus
    public let requestedByInboxId: String
    public let requestId: String
}
```

### `MessageContent`

```swift
case assistantJoinRequest(status: AssistantJoinStatus, requestedByInboxId: String)
```

### `MessagesListItemType`

```swift
case assistantJoinStatus(AssistantJoinStatus, requesterName: String?, date: Date)
```

`requesterName` is nil for the requester (self), populated for other members. `date` is used for auto-dismiss timing.

---

## Implementation

### Message storage path

`AssistantJoinRequest` messages flow through the standard message pipeline:
1. `DecodedMessage+DBRepresentation` handles `ContentTypeAssistantJoinRequest` → stores as `DBMessage` with `contentType = .assistantJoinRequest` and `text = status.rawValue`
2. No `StreamProcessor` interception needed — messages are stored like any other content type
3. `MessagesRepository` hydrates `DBMessage` → `MessageContent.assistantJoinRequest`

### Exclusion from non-status contexts

`assistantJoinRequest` messages are excluded from:
- `lastMessageRequest` / `lastMessageWithSourceCTE` (not a visible message for conversation list)
- `DBMessage+MessagePreview` (empty text for preview)
- Push notification processing (dropped in `MessagingService+PushNotifications`)
- Reply target resolution (returns nil)
- Unread marking (`marksConversationAsUnread` returns false)

### Hydration: `DBConversationDetails+Conversation`

The conversation-level `assistantJoinStatus` is derived during hydration:
1. Read `conversationAssistantJoinRequest` from the CTE
2. Parse the status string
3. Check if any agent member exists — if so, return nil (agent already joined)
4. Check if `displayDuration` has elapsed — if so, return nil (expired)
5. Otherwise return the status

### ConversationViewModel

`requestAssistantJoin()` flow:
1. Cancel any existing task
2. Broadcast `AssistantJoinRequest(status: .pending)` via XMTP
3. Fire API call
4. On error: broadcast error status via XMTP, haptic feedback
5. On cancellation: clean up task reference

`broadcastAssistantJoinRequest()` is a static method that resolves the XMTP conversation and sends the message.

`isAssistantJoinPending` checks both the in-flight task and the conversation's derived status.

### MessagesListProcessor

Processes `assistantJoinRequest` messages as synthetic cells:
1. Pre-scan: find the index of the last assistant join request, check if an agent joined after it
2. During processing: only render the latest request, skip if expired or superseded by agent join
3. Resolve requester name from sender profile (nil = self, display name = other member)
4. Flush any open message group before inserting the status cell

### MessagesListRepository

Schedules auto-dismiss timers:
1. After processing, scan for any `.assistantJoinStatus` items
2. Calculate remaining display time
3. Schedule a `Just().delay()` to reprocess messages when the earliest one expires
4. Reprocessing causes the expired status to be filtered out

---

## Rendering Pipeline

```
ConversationViewModel.requestAssistantJoin()
  → broadcastAssistantJoinRequest() sends XMTP message
  → StreamProcessor receives message (or local echo)
  → DecodedMessage+DBRepresentation stores as DBMessage
  → MessagesRepository observes message table change
  → MessagesListProcessor.process() renders synthetic cell
  → MessagesListRepository schedules auto-dismiss timer
  → CellFactory → AssistantJoinStatusView rendered in collection view
```

For conversation-level status (used by `isAssistantJoinPending`):
```
latestAssistantJoinRequestCTE derives status from message table
  → DBConversationDetails includes CTE result
  → Hydration applies agent-presence + time-based expiry
  → Conversation.assistantJoinStatus populated
  → ConversationViewModel.conversation updated via observation
```

---

## Files Modified

| File | Change |
|------|--------|
| `ConvosCore/.../SharedDatabaseMigrator.swift` | Partial index on message table |
| `ConvosCore/.../DBConversation.swift` | CTE query, exclude from last message queries |
| `ConvosCore/.../DBAssistantJoinRequest.swift` | **New** — CTE result model |
| `ConvosCore/.../DBConversationDetails.swift` | Added CTE association |
| `ConvosCore/.../DBConversationDetails+Conversation.swift` | Hydration with agent-presence + time-based expiry |
| `ConvosCore/.../Conversation.swift` | Added `assistantJoinStatus` property |
| `ConvosCore/.../AssistantJoinStatus.swift` | **New** — enum with `displayDuration` |
| `ConvosCore/.../MessageContent.swift` | Added `.assistantJoinRequest` case |
| `ConvosCore/.../MessageContentType.swift` | Added `.assistantJoinRequest` case |
| `ConvosCore/.../AssistantJoinRequestCodec.swift` | **New** — XMTP codec |
| `ConvosCore/.../XMTPClientProvider.swift` | `sendAssistantJoinRequest()` extension |
| `ConvosCore/.../InboxStateMachine.swift` | Register codec |
| `ConvosCore/.../ConvosAPIClient.swift` | `forceErrorCode` param, 35s timeout, public `APIError` |
| `ConvosCore/.../SessionManager[Protocol].swift` | `forceErrorCode` param |
| `ConvosCore/.../MockInboxesService.swift` | Mock `forceErrorCode` handling |
| `ConvosCore/.../MessagingService+PushNotifications.swift` | Drop assistant join request push notifications |
| `ConvosCore/.../DecodedMessage+DBRepresentation.swift` | Handle new content type |
| `ConvosCore/.../DBMessage+MessagePreview.swift` | Empty preview text |
| `ConvosCore/.../ConversationsRepository.swift` | Include CTE in detailed query |
| `ConvosCore/.../MessagesRepository.swift` | Hydrate `.assistantJoinRequest` content |
| `Convos/.../ConversationViewModel.swift` | Broadcast flow, `isAssistantJoinPending` |
| `Convos/.../AddToConversationMenu.swift` | Use `isAssistantJoinPending` |
| `Convos/.../AssistantJoinStatusView.swift` | **New** — status row UI |
| `Convos/.../MessagesListItemType.swift` | Added `.assistantJoinStatus` case |
| `Convos/.../MessagesListProcessor.swift` | Synthetic cell rendering with expiry |
| `Convos/.../MessagesListRepository.swift` | Auto-dismiss timer scheduling |
| `Convos/.../MessagesListView.swift` | Render status cell |
| `Convos/.../MessagesViewController.swift` | Register cell type |
| `Convos/.../MessagesView[Representable].swift` | Pass through state |

---

## Backend Requirements

No backend changes needed. Current endpoint behavior:

- `POST /api/v2/agents/join`
  - **200** → agent is joining
  - **502** → provisioning failed
  - **503** → no idle agents
  - **504** → 30s timeout (client timeout set to 35s to let backend respond first)

The `X-Force-Error` header is supported for QA testing (forces a specific error code).

## Out of Scope

- Pre-checking agent availability before showing the menu
- Showing status in the conversations list
- Retry with exponential backoff
- Server-side duplicate rejection
