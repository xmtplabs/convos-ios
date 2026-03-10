# Assistant Join Status — Persistent State with Pending Broadcast

## Context

When a user adds an assistant to a conversation via the "+" menu, the app calls `POST /api/v2/agents/join`. This call can take up to ~30 seconds. The initial implementation used transient ViewModel state (with a static dictionary for navigation survival) to show inline feedback. This worked but had limitations:

- **Lost on navigation**: the state lived in the ViewModel, which is deallocated when navigating away
- **Lost on app kill**: the pending state disappeared if the app was terminated mid-request
- **Local-only state**: other members had no visibility into whether an assistant was being requested

This v2 plan moves the assistant join status into GRDB (persists across navigation and app restarts) and broadcasts the pending state via XMTP so all group members can see it.

## Goal

1. **Persist** assistant join status in GRDB at the conversation level so it survives app kills and navigation
2. **Broadcast** the pending state via XMTP so all members see "Louis invited an assistant to join"
3. **Keep errors local** — only the requester sees error/retry states

## Design Decisions

### Broadcast pending, not errors

When a user requests an assistant, an XMTP message is sent to the group so all members see "Louis invited an assistant to join." Error states (503, 502/504) are **not** broadcast — they're only visible to the requester as local GRDB state. Rationale:

- **Errors are the requester's concern** — retry is only actionable by the requester
- **Other members can request independently** — if they want an assistant and have permission
- **Edge case accepted**: if the request fails, other members see a dangling "Louis invited an assistant to join" with no resolution. This is slightly weird but rare, and not worth the complexity of broadcasting error/clear states. The status clears if an assistant is eventually added by anyone.

### Status cleared by agent join, not API success

The API returning 200 means the request was accepted, not that the agent has joined. The status stays `.pending` until the XMTP group update with `addedAgent == true` arrives, confirming the agent actually joined the group.

### Error states persist until retry or auto-dismiss

Error rows ("No assistants available", "Could not join") persist in the messages list. They are not dismissed by sending a message or navigating away. They are cleared by:
- User tapping retry (resets to `.pending`)
- 45-second auto-dismiss timer
- Agent successfully joining (clears any status)

### Not stored as a message

The XMTP broadcast message updates conversation-level GRDB state, following the same pattern as `ExplodeSettings`. It is **not** stored as a `DBMessage` row. The status renders as a synthetic cell in the messages list (like date separators), derived from `conversation.assistantJoinStatus`.

## Design Spec

### States & Visual Treatment

Inline centered rows at the bottom of the messages list (synthetic cells, not real messages):

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
- The pending/error status is **cleared** from the conversation
- The real "joined by invitation" update + `AssistantJoinedInfoView` display as today

### State Transitions

#### Requester's device
```
User taps "Instant assistant"
  │
  ├─ 1. Write assistantJoinStatus = .pending to GRDB conversation
  ├─ 2. Broadcast AssistantJoinRequest(status: .pending) via XMTP
  ├─ 3. Fire POST /api/v2/agents/join
  │
  ▼
[Pending] "Assistant is joining…"
  │
  ├─ API returns 200 ──► Keep .pending, wait for XMTP group update
  │
  ├─ API returns 503 ──► Update local GRDB to .noAgentsAvailable (no broadcast)
  │
  ├─ API returns 502/504 ► Update local GRDB to .failed (no broadcast)
  │                              │
  │                              └─ User taps retry ──► Reset to .pending + broadcast again
  │
  ├─ 45s auto-dismiss ──► Clear local status
  │
  └─ XMTP member-added (agent) ──► Clear status
```

#### Other members' devices
```
Receive XMTP AssistantJoinRequest message
  │
  ├─ StreamProcessor decodes it
  ├─ Writes .pending + requestedBy to GRDB conversation
  │
  ▼
[Pending] "Louis invited an assistant to join"
  │
  ├─ XMTP member-added (agent) ──► Clear status
  │
  └─ (Error on requester's side) ──► Status stays as .pending (accepted edge case)
```

---

## Data Model

### GRDB migration

```swift
migrator.registerMigration("addAssistantJoinStatusToConversation") { db in
    try db.alter(table: "conversation") { t in
        t.add(column: "assistantJoinStatus", .text)
        t.add(column: "assistantJoinRequestedBy", .text)
    }
}
```

- `assistantJoinStatus`: nullable TEXT — nil, "pending", "noAgentsAvailable", "failed"
- `assistantJoinRequestedBy`: the inboxId of the user who initiated the request

### `AssistantJoinStatus` enum

`String`-backed `Codable` for GRDB column storage:

```swift
public enum AssistantJoinStatus: String, Equatable, Hashable, Sendable, Codable {
    case pending
    case noAgentsAvailable
    case failed
}
```

### `DBConversation` additions

```swift
let assistantJoinStatus: AssistantJoinStatus?
let assistantJoinRequestedBy: String?
```

Plus `with(assistantJoinStatus:assistantJoinRequestedBy:)` method. All existing `with()` methods pass through both fields. Values preserved during conversation re-stores from XMTP metadata (same pattern as `imageLastRenewed`).

### XMTP custom content type: `AssistantJoinRequestCodec`

Follows the `ExplodeSettingsCodec` pattern — JSON-encoded, silent (no push), registered in `InboxStateMachine`.

```swift
public struct AssistantJoinRequest: Codable, Sendable {
    public let status: AssistantJoinStatus
    public let requestedByInboxId: String
    public let requestId: String
}
```

### `MessagesListItemType`

```swift
case assistantJoinStatus(AssistantJoinStatus, requesterName: String?)
```

`requesterName` is nil for the requester (self), populated for other members.

---

## Implementation

### ConversationLocalStateWriter

```swift
func updateAssistantJoinStatus(_ status: AssistantJoinStatus?, requestedBy: String?, for conversationId: String) async throws
```

Updates the conversation-level columns. Conceptually local state (not synced via XMTP group metadata), even though it writes to the `conversation` table.

### ConversationWriter

Preserves `assistantJoinStatus` and `assistantJoinRequestedBy` during conversation re-stores from XMTP metadata, preventing metadata syncs from clearing pending/error status.

### StreamProcessor

Handles incoming `AssistantJoinRequest` XMTP messages:
1. Decodes the `AssistantJoinRequest` payload
2. Writes `assistantJoinStatus` and `assistantJoinRequestedBy` to the conversation in GRDB
3. Does **not** store it as a `DBMessage`
4. Returns early (message is consumed, not passed to normal message processing)

### ConversationViewModel

`requestAssistantJoin()` flow:
1. Write `.pending` to GRDB
2. Broadcast `AssistantJoinRequest(status: .pending)` via XMTP
3. Fire API call
4. On error: update local GRDB status (no broadcast), schedule 45s auto-dismiss

Agent join detection:
- Observes `conversationPublisher` for conversation changes
- `clearAssistantJoinStatusIfAgentJoined()` checks if `conversation.hasAssistant` became true while status is non-nil
- Clears status from GRDB, cancels tasks

Removed from v1:
- `private static var assistantJoinStatuses` static dictionary
- `restoreAssistantJoinStatusIfNeeded()` — GRDB observation handles this
- `dismissAssistantJoinErrorIfNeeded()` — errors no longer dismissed on send

### MessagesViewController

Reads `state.conversation.assistantJoinStatus` and appends a synthetic `.assistantJoinStatus(joinStatus, requesterName:)` cell at the end of the messages list.

Requester name resolution:
- Reads `conversation.assistantJoinRequestedBy`
- If it matches `conversation.inboxId` (self): `requesterName = nil` → shows "Assistant is joining…"
- If it's another member: resolves display name → shows "Louis invited an assistant to join"

Scroll-to-bottom on status appearance: tracks `previousAssistantJoinStatus` and scrolls when transitioning from nil to non-nil.

---

## Rendering Pipeline

```
localStateWriter.updateAssistantJoinStatus(.pending, requestedBy: inboxId, for: conversationId)
  → GRDB write to conversation table
  → ValueObservation on DBConversation detects row change
  → conversationPublisher emits
  → ConversationViewModel.conversation = conversation
  → @Observable triggers SwiftUI re-render
  → ConversationView → MessagesView → MessagesViewRepresentable
  → updateUIViewController → MessagesViewController.state
  → processUpdates: cells.append(.assistantJoinStatus(joinStatus, requesterName:))
  → CellFactory → AssistantJoinStatusView rendered in collection view
```

---

## Files Modified

| File | Change |
|------|--------|
| `ConvosCore/.../SharedDatabaseMigrator.swift` | Migration for columns |
| `ConvosCore/.../DBConversation.swift` | Added columns, `with()` methods |
| `ConvosCore/.../Conversation.swift` | Added properties |
| `ConvosCore/.../AssistantJoinStatus.swift` | `String`-backed `Codable` enum |
| `ConvosCore/.../MessageContentType.swift` | Added `.assistantJoinRequest` case |
| `ConvosCore/.../AssistantJoinRequestCodec.swift` | **New** — XMTP codec |
| `ConvosCore/.../XMTPClientProvider.swift` | `sendAssistantJoinRequest()` extension |
| `ConvosCore/.../StreamProcessor.swift` | Handle incoming broadcasts, update GRDB |
| `ConvosCore/.../ConversationLocalStateWriter.swift` | `updateAssistantJoinStatus` method |
| `ConvosCore/.../ConversationWriter.swift` | Preserve status during re-stores |
| `ConvosCore/.../DBConversationDetails+Conversation.swift` | Hydration |
| `ConvosCore/.../MessagesRepository.swift` | Hydration, content type switches |
| `ConvosCore/.../DecodedMessage+DBRepresentation.swift` | Handle new content type |
| `ConvosCore/.../IncomingMessageWriter.swift` | Handle new content type |
| `ConvosCore/.../OutgoingMessageWriter.swift` | Handle new content type |
| `Convos/.../ConversationViewModel.swift` | GRDB-based flow, pending broadcast |
| `Convos/.../ConversationView.swift` | Read status from conversation |
| `Convos/.../MessagesViewController.swift` | Synthetic cell injection |
| `Convos/.../AssistantJoinStatusView.swift` | Requester name display |
| `Convos/.../MessagesListItemType.swift` | Updated case signature |
| `Convos/.../MessagesViewRepresentable.swift` | Removed status parameter |
| `Convos/.../MessagesView.swift` | Removed status parameter |

---

## Backend Requirements

No backend changes needed. Current endpoint behavior:

- `POST /api/v2/agents/join`
  - **200** → agent is joining
  - **502** → provisioning failed
  - **503** → no idle agents
  - **504** → 30s timeout

## Out of Scope

- Broadcasting error states to other members
- Pre-checking agent availability before showing the menu
- Showing status in the conversations list
- Retry with exponential backoff
- Server-side duplicate rejection
