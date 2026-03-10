# Assistant Join Status — Persistent State & Group-Broadcasted Updates

## Context

When a user adds an assistant to a conversation via the "+" menu, the app calls `POST /api/v2/agents/join`. This call can take up to ~30 seconds. The initial implementation used transient ViewModel state (with a static dictionary for navigation survival) to show inline feedback. This worked but had limitations:

- **Local-only state**: other members couldn't see that an assistant was being requested, leading to potential duplicate requests
- **Lost on app kill**: the pending state disappeared if the app was terminated mid-request
- **Race conditions between members**: two users could tap "Instant assistant" simultaneously with no coordination

This v2 plan moves the assistant join status into GRDB and broadcasts state changes as XMTP group update messages, solving all three problems.

## Goal

1. **Persist** assistant join status in GRDB at the conversation level so it survives app kills and navigation
2. **Broadcast** status changes as XMTP group messages so all members see the same state and can't double-request
3. **Render** status transitions as updatable message rows in the chat (insert on request, update on resolution)

## Design Spec

### States & Visual Treatment

Same visual treatment as v1 — inline centered rows in the messages list:

#### 1. "Louis requested an assistant" → "Assistant is joining…" (Pending)
- Shown immediately when **any member** requests an assistant
- Text: **"[Name] requested an assistant"** for other members, **"Assistant is joining…"** for the requester
- Color: `color/text/tertiary`
- Not tappable

#### 2. "No assistants are available" (503 — `noAgentsAvailable`)
- **Replaces** the pending row (same message row, updated in-place)
- Text: **"No assistants are available"**
- Prepended with gray circle + SF Symbol `xmark`
- Not tappable

#### 3. "Assistant could not join" (502/504)
- **Replaces** the pending row (same message row, updated in-place)
- Text: **"Assistant could not join"**
- Prepended with gray circle + SF Symbol `arrow.clockwise`
- **Tappable** — retries the join

#### 4. Success (real XMTP group update)
- The existing `ConversationUpdate` with `addedAgent == true` arrives via XMTP
- The pending/error message row is **removed** from the DB
- The real "joined by invitation" update + `AssistantJoinedInfoView` display as today

### State Transitions

```
User taps "Instant assistant"
  │
  ├─ 1. Write assistantJoinStatus = .pending to DBConversation
  ├─ 2. Insert a local "assistant_join_request" message into GRDB
  ├─ 3. Send XMTP group message (custom content type) broadcasting the request
  ├─ 4. Fire POST /api/v2/agents/join
  │
  ▼
[Pending] "Assistant is joining…" (visible to all members via XMTP message)
  │
  ├─ API returns 200 ──► Keep .pending, wait for XMTP group update
  │
  ├─ API returns 503 ──► Update DB status to .noAgentsAvailable
  │                       Update the existing message row in GRDB
  │                       Send XMTP update message with failure status
  │
  ├─ API returns 502/504 ► Update DB status to .failed
  │                         Update the existing message row in GRDB
  │                         Send XMTP update message with failure status
  │                              │
  │                              └─ User taps retry ──► Reset to .pending (new cycle)
  │
  └─ XMTP member-added update ──► Clear DB status
      (agent joined the group)     Delete the status message row
```

### Multi-User Coordination

When Member A taps "Instant assistant":
1. An XMTP message is sent to the group: `AssistantJoinRequest(status: .pending, requestedBy: inboxId)`
2. All members receive this and see "Louis requested an assistant"
3. The "Instant assistant" button is disabled for all members (because `conversation.assistantJoinStatus != nil`)
4. When the API resolves, a follow-up XMTP message updates the status

**Race condition window**: There's still a small window where two members could tap simultaneously before receiving each other's XMTP message. This is dramatically smaller than the current window (seconds of XMTP propagation vs. 30+ seconds of API call). The backend should also reject duplicate join requests for the same conversation as additional protection.

---

## Data Model Changes

### 1. Add `assistantJoinStatus` column to `conversation` table

New GRDB migration:

```swift
migrator.registerMigration("addAssistantJoinStatus") { db in
    try db.alter(table: "conversation") { t in
        t.add(column: "assistantJoinStatus", .text) // nil, "pending", "noAgentsAvailable", "failed"
    }
}
```

This column stores the current join status at the conversation level. It's `nil` when no join is in progress.

### 2. Update `DBConversation`

Add the column:
```swift
let assistantJoinStatus: String? // nil | "pending" | "noAgentsAvailable" | "failed"
```

Add a `with(assistantJoinStatus:)` method following the existing pattern.

### 3. Update `Conversation` model

Add to the public model:
```swift
public let assistantJoinStatus: AssistantJoinStatus?
```

Where `AssistantJoinStatus` remains the existing enum in `ConvosCore/Storage/Models/`:
```swift
public enum AssistantJoinStatus: String, Equatable, Hashable, Sendable, Codable {
    case pending
    case noAgentsAvailable
    case failed
}
```

(Changed from plain enum to `String`-backed for GRDB column storage.)

### 4. New custom content type: `AssistantJoinRequestCodec`

A new XMTP custom content type for broadcasting assistant join status to the group:

```swift
public struct AssistantJoinRequest: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case noAgentsAvailable
        case failed
    }

    public let status: Status
    public let requestedByInboxId: String
    public let requestId: String // UUID to correlate request → resolution
}

public let ContentTypeAssistantJoinRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "assistant_join_request",
    versionMajor: 1,
    versionMinor: 0
)
```

The `requestId` is a UUID generated when the user taps "Instant assistant". It's used to:
- Match the resolution message to the original request
- Identify which message row in GRDB to update when the status changes

### 5. Store as a message in GRDB

The assistant join request is stored as a `DBMessage` with:
- `contentType`: new `.assistantJoinRequest` case added to `MessageContentType`
- `messageType`: `.original`
- `text`: the `requestId` (used for correlation)
- `update`: a `DBMessage.Update` encoding the status and requester info

This means:
- It appears in the messages list automatically via the existing `MessagesRepository` observation
- It can be **updated in place** when the status changes (same message ID, new update payload)
- It's deleted when the agent successfully joins

### 6. Update `MessageContentType`

```swift
public enum MessageContentType: String, Codable, Sendable {
    case text, emoji, attachments, update, invite, assistantJoinRequest

    var marksConversationAsUnread: Bool {
        switch self {
        case .update, .assistantJoinRequest:
            false
        default:
            true
        }
    }
}
```

### 7. Update `MessagesListItemType`

Replace the current `.assistantJoinStatus(AssistantJoinStatus)` case with a richer type that includes the requester profile:

```swift
case assistantJoinStatus(id: String, status: AssistantJoinStatus, requester: ConversationMember?)
```

The `id` is the message ID for stable identity in the collection view. The `requester` enables showing "Louis requested an assistant" to other members.

---

## Flow: Requesting an Assistant Join

### Step-by-step (requester's device)

1. **User taps "Instant assistant"**
2. **Write to GRDB**: Set `conversation.assistantJoinStatus = .pending`
3. **Insert local message**: Create a `DBMessage` with `contentType = .assistantJoinRequest`, `status = .pending`, a new `requestId`
4. **Send XMTP message**: Broadcast `AssistantJoinRequest(status: .pending, requestedByInboxId: myInboxId, requestId: requestId)` to the group
5. **Fire API call**: `POST /api/v2/agents/join`
6. **On API success (200)**: Keep `.pending` — wait for the XMTP group update showing the agent joined
7. **On API error**: Update GRDB conversation status + update the message row + send XMTP resolution message
8. **On XMTP member-added (agent)**: Clear conversation status + delete the status message row

### Step-by-step (other members' devices)

1. **Receive XMTP message** with `ContentTypeAssistantJoinRequest`
2. **StreamProcessor** handles it:
   - Decode the `AssistantJoinRequest`
   - If `status == .pending`: write `conversation.assistantJoinStatus = .pending`, insert/update the message row
   - If `status == .failed/.noAgentsAvailable`: update the conversation and message row
3. **UI updates automatically** via GRDB observation (conversation publisher + messages publisher)

---

## Implementation Details

### New file: `ConvosCore/Custom Content Types/AssistantJoinRequestCodec.swift`

Follow the exact pattern of `ExplodeSettingsCodec`:
- JSON-encoded content
- Register in the XMTP client codec list
- `shouldPush` returns `false` (silent, no notification needed)

### Update: `StreamProcessor.swift`

Add handling for the new content type in `processMessage()`, similar to how `ExplodeSettings` is handled:

```swift
if contentType == ContentTypeAssistantJoinRequest {
    await processAssistantJoinRequest(message, conversationId: conversation.id)
    return // don't store as a regular message
}
```

The processor:
1. Decodes the `AssistantJoinRequest`
2. Updates `DBConversation.assistantJoinStatus` via the conversation writer
3. Inserts or updates a `DBMessage` for the status row

### Update: `ConversationWriter.swift`

Add a method:
```swift
func updateAssistantJoinStatus(_ status: AssistantJoinStatus?, for conversationId: String) async throws
```

### Update: `ConversationViewModel.swift`

Remove:
- `private static var assistantJoinStatuses: [String: AssistantJoinStatus]` (no longer needed — GRDB is the source of truth)
- `restoreAssistantJoinStatusIfNeeded()` (no longer needed — conversation publisher delivers the status)
- `var assistantJoinStatus: AssistantJoinStatus?` as a standalone property (read from `conversation.assistantJoinStatus` instead)

The `requestAssistantJoin()` method becomes:
1. Write `.pending` to GRDB
2. Insert local message
3. Send XMTP message
4. Fire API call
5. On error: update GRDB + send XMTP resolution
6. On XMTP agent-joined: clear GRDB + delete message (handled by the stream processor / conversation observer)

### Update: `MessagesViewController.swift`

Remove the synthetic injection of `.assistantJoinStatus` in `processUpdates`. The status row is now a real message in the DB, delivered through the normal messages pipeline. The scroll-to-bottom logic for new messages will handle it automatically.

### Update: `DecodedMessage+DBRepresentation.swift`

Add a case for `ContentTypeAssistantJoinRequest` in the switch statement, producing a `DBMessage` with `contentType = .assistantJoinRequest`.

### Update: `AssistantJoinStatusView.swift`

Add support for showing the requester's name:
```swift
struct AssistantJoinStatusView: View {
    let status: AssistantJoinStatus
    let requesterName: String? // nil = current user
    var onRetry: (() -> Void)?
}
```

When `status == .pending` and `requesterName != nil`: show "[Name] requested an assistant"
When `status == .pending` and `requesterName == nil`: show "Assistant is joining…"

---

## Auto-Dismiss & Cleanup

### Error auto-dismiss (45s timer)

Keep the 45s auto-dismiss timer for error states. When it fires:
1. Clear `conversation.assistantJoinStatus` in GRDB
2. Delete the status message row from GRDB
3. UI updates automatically via observation

### Dismiss on message send

When the user sends a message while an error status is showing:
1. Clear the status and delete the message row (same as auto-dismiss)

### Dismiss on agent join (success)

When the stream processor sees a `ConversationUpdate` with `addedAgent == true`:
1. Clear `conversation.assistantJoinStatus` in GRDB
2. Delete any `.assistantJoinRequest` messages for the conversation
3. The real "joined by invitation" update renders normally

---

## Backend Requirements

The backend already supports the required error responses. No backend changes are needed for the core feature.

### Current endpoint behavior (no changes needed)

`POST /api/v2/agents/join`
- **200** `{ success: true, joined: true }` → agent is joining
- **502** `AGENT_PROVISION_FAILED` → provisioning failed
- **503** `NO_AGENTS_AVAILABLE` → no idle agents
- **504** `AGENT_POOL_TIMEOUT` → 30s timeout

### Recommended backend enhancement: duplicate request rejection

The backend should reject `POST /api/v2/agents/join` if an agent join is already in progress for the given conversation (identified by the invite slug). Return a `409 Conflict` or similar. This provides server-side protection against the remaining race window.

---

## Migration from v1

The v1 implementation has:
- `assistantJoinStatus` as a ViewModel property
- `assistantJoinStatuses` static dictionary
- Synthetic injection in `MessagesViewController.processUpdates`
- `AssistantJoinStatusView` (keep and extend)
- `AssistantJoinStatus` enum (keep, make `String`-backed)
- `MessagesListItemType.assistantJoinStatus` case (update signature)

The migration:
1. Add the GRDB migration for the new column
2. Add the custom content type codec
3. Update StreamProcessor to handle the new content type
4. Update ConversationWriter with the new method
5. Update the ViewModel to write to GRDB instead of static state
6. Update MessagesViewController to stop injecting synthetic rows
7. Update the view to support requester name
8. Remove the static dictionary and restore logic

---

## Files to Modify

| File | Change |
|------|--------|
| `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift` | Add migration for `assistantJoinStatus` column |
| `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift` | Add column + `with(assistantJoinStatus:)` |
| `ConvosCore/Sources/ConvosCore/Storage/Models/Conversation.swift` | Add `assistantJoinStatus` property |
| `ConvosCore/Sources/ConvosCore/Storage/Models/AssistantJoinStatus.swift` | Make `String`-backed, add `Codable` |
| `ConvosCore/Sources/ConvosCore/Storage/Models/MessageContentType.swift` | Add `.assistantJoinRequest` case |
| `ConvosCore/Sources/ConvosCore/Custom Content Types/AssistantJoinRequestCodec.swift` | **New file** |
| `ConvosCore/Sources/ConvosCore/Messaging/XMTPClientProvider.swift` | Add `sendAssistantJoinRequest()` extension |
| `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift` | Handle incoming `AssistantJoinRequest` messages |
| `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationWriter.swift` | Add `updateAssistantJoinStatus()` |
| `ConvosCore/Sources/ConvosCore/Storage/XMTP DB Representations/DecodedMessage+DBRepresentation.swift` | Handle new content type |
| `Convos/Conversation Detail/ConversationViewModel.swift` | Rewrite to use GRDB, remove static dict |
| `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/MessagesViewController.swift` | Remove synthetic injection |
| `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/AssistantJoinStatusView.swift` | Add requester name support |
| `Convos/Conversation Detail/Messages/MessagesListView/MessagesListItemType.swift` | Update case signature |
| `Convos/Conversation Detail/AddToConversationMenu.swift` | Read status from `conversation.assistantJoinStatus` |

## Testing

### Unit Tests

| Test | Asserts |
|------|---------|
| Requesting join writes `.pending` to GRDB | `conversation.assistantJoinStatus == .pending` |
| API error updates GRDB status | Status reflects the error |
| API error updates the message row in GRDB | Message content changes |
| Agent joins → status cleared from GRDB | `conversation.assistantJoinStatus == nil` |
| Agent joins → status message deleted from GRDB | No `.assistantJoinRequest` messages remain |
| Receiving XMTP join request from other member | Status set to `.pending`, message inserted |
| Receiving XMTP failure update from other member | Status and message updated |
| Menu disabled when `conversation.assistantJoinStatus != nil` | Button disabled for all members |
| Auto-dismiss fires after 45s | Status and message cleared |
| Retry resets to `.pending` | New request cycle starts |
| Duplicate request blocked when status is non-nil | Second tap is no-op |

### Integration Tests

| Test | Asserts |
|------|---------|
| Full flow: request → pending → agent joins → cleared | End-to-end with mock XMTP |
| Full flow: request → pending → error → retry → success | Error recovery path |
| Multi-member: A requests, B sees pending, agent joins, both cleared | Cross-member coordination |

## Out of Scope

- Pre-checking agent availability before showing the menu
- Showing status in the conversations list (home view)
- Retry with exponential backoff (simple single retry is sufficient)
- Server-side duplicate rejection (recommended but separate backend work)
