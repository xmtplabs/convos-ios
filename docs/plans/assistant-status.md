# Assistant Join Status — Error UX & In-Chat Feedback

## Context

When a user adds an assistant to a conversation via the "+" menu, the app calls `POST /api/v2/agents/join`. This call can take up to ~30 seconds. Currently, the app fires the request and silently waits — if it fails, the error is only logged. There is no visual feedback during the join attempt, and no error states shown to the user.

The backend already returns three distinct error cases that the iOS client catches as `APIError`:
- **`noAgentsAvailable`** (503) — no idle agents in the pool
- **`agentPoolTimeout`** (504) — no agent joined within 30 seconds
- **`agentProvisionFailed`** (502) — provisioning attempted but failed

## Goal

Show real-time, in-chat status feedback when the user requests an assistant join — from the moment they tap "Instant assistant" until the assistant either joins, fails, or is unavailable. This replaces the current silent fire-and-forget behavior.

## Design Spec

### States & Visual Treatment

All status items appear **inline in the messages list** as centered rows, styled like group updates (same layout as `TextTitleContentView`).

#### 1. "Assistant is joining…" (Pending)
- Shown **immediately** when the user taps "Instant assistant" — no waiting for the API response.
- Text: **"Assistant is joining…"**
- Color: `color/text/tertiary`
- **No PFP** — no avatar circle prepended, just the text.
- Not tappable.
- This is a **local-only optimistic UI element** — not a real group update from XMTP.
- Disappears when replaced by either an error state OR the real "joined by invitation" group update.

#### 2. "No assistants are available" (503 — `noAgentsAvailable`)
- **Replaces** the "Assistant is joining…" row.
- Text: **"No assistants are available"**
- Color: `color/text/primary`
- Prepended with a **gray circle** (same size as PFP in group updates, `color/fill/tertiary` background) containing an **SF Symbol `xmark`** in white.
- **Not tappable.**

#### 3. "Assistant could not join" (502 — `agentProvisionFailed`, 504 — `agentPoolTimeout`)
- **Replaces** the "Assistant is joining…" row.
- Text: **"Assistant could not join"**
- Color: `color/text/primary`
- Prepended with a **gray circle** (same size as PFP in group updates, `color/fill/tertiary` background) containing an **SF Symbol `arrow.clockwise`** in white.
- **Tappable** — tapping retries the assistant join (same action as tapping "Instant assistant" from the + menu).

#### 4. "Assistant joined by invitation" (Success — real group update)
- This is the existing `ConversationUpdate` that arrives via XMTP when the agent actually joins the group.
- Shown with the **orange PFP** (existing `colorLava` avatar), as it already works today.
- The "Assistant is joining…" (or error) row is **removed** when this real group update appears.
- The `AssistantJoinedInfoView` continues to display below this update (existing behavior).

### State Transitions

```
User taps "Instant assistant"
  │
  ▼
[Pending] "Assistant is joining…"
  │
  ├─ API returns 200 ──────────► [Pending stays] ──► XMTP group update arrives ──► [Success] Real update replaces pending
  │
  ├─ API returns 503 ──────────► [Error] "No assistants are available"
  │
  ├─ API returns 502/504 ─────► [Error] "Assistant could not join" (tappable retry)
  │                                 │
  │                                 └─ User taps retry ──► [Pending] "Assistant is joining…" (restart)
  │
  └─ XMTP update arrives ─────► [Success] Real update replaces pending (race condition: API slow but agent joined)
      before API responds
```

### Edge Cases

- **Status is transient**: held in the ViewModel, not persisted. If the user navigates away or the app is killed, the status is naturally lost. This is acceptable — the user can retry from the menu.
- **User taps "Instant assistant" again** while pending: no-op (button should be disabled while `assistantJoinStatus != nil`).
- **Conversation already has an assistant**: the "Instant assistant" button is already disabled via `hasAssistant` (existing behavior).
- **Retry after error**: resets to pending state, fires a new API call.

---

## iOS Implementation

### 1. Add `AssistantJoinStatus` enum

In `ConversationViewModel` (or a dedicated type):

```swift
enum AssistantJoinStatus: Equatable {
    case pending
    case noAgentsAvailable
    case failed // covers agentProvisionFailed and agentPoolTimeout
}
```

### 2. Update `ConversationViewModel`

- Add `var assistantJoinStatus: AssistantJoinStatus?` observable property.
- Modify `requestAssistantJoin()`:
  - Set `assistantJoinStatus = .pending` immediately.
  - On `APIError.noAgentsAvailable` → set `.noAgentsAvailable`.
  - On `APIError.agentProvisionFailed` or `.agentPoolTimeout` → set `.failed`.
  - On success (200) → keep `.pending` (wait for XMTP group update to clear it).
- Add observation: when a new `ConversationUpdate` with `addedAgent == true` arrives in the messages list, set `assistantJoinStatus = nil`.
- Disable the "Instant assistant" menu button when `assistantJoinStatus != nil` (in addition to existing `hasAssistant` check).

### 3. Add `AssistantJoinStatusView`

New view in `Messages List Items/`:

```
AssistantJoinStatusView
├── .pending → "Assistant is joining…" (tertiary text, no icon)
├── .noAgentsAvailable → gray circle with xmark + "No assistants are available"
└── .failed → gray circle with arrow.clockwise (tappable) + "Assistant could not join"
```

The gray circle icon should match the PFP size used in `TextTitleContentView` (16pt based on current code).

### 4. Add `MessagesListItemType.assistantJoinStatus` case

Add a new case to `MessagesListItemType`:
```swift
case assistantJoinStatus(AssistantJoinStatus)
```

This gets injected into the messages list by the processor/ViewController when `assistantJoinStatus != nil`, positioned at the **bottom** of the list (most recent position).

### 5. Clear status on real group update

When `MessagesListProcessor` processes messages and finds an update with `addedAgent == true`, signal the ViewModel to clear `assistantJoinStatus`. Alternatively, observe the messages list in the ViewModel and clear when an agent-added update appears.

### 6. Wire up retry

The `.failed` state's tap action calls `requestAssistantJoin()` again (which resets to `.pending`).

### 7. Update `AddToConversationMenu`

The `onInviteAssistant` button should be disabled when `assistantJoinStatus != nil`:
```swift
.disabled(hasAssistant || assistantJoinStatus != nil)
```

---

## Backend Requirements

The backend already supports the required error responses. No backend changes are needed for the core feature.

### Current endpoint behavior (no changes needed)

`POST /api/v2/agents/join`
- **200** `{ success: true, joined: true }` → agent is joining
- **502** `AGENT_PROVISION_FAILED` → provisioning failed
- **503** `NO_AGENTS_AVAILABLE` → no idle agents
- **504** `AGENT_POOL_TIMEOUT` → 30s timeout

### Optional backend enhancement: availability check

If the team wants to **pre-check** assistant availability before showing the menu option (e.g., gray out or hide "Instant assistant" when no agents are available), the backend could expose:

```
GET /api/v2/agents/status
Response: { "available": true/false, "estimatedWaitSeconds": 0 }
```

This is **out of scope** for this iteration — the iOS app will optimistically show the option and handle errors inline.

---

## Files to Modify

| File | Change |
|------|--------|
| `Convos/Conversation Detail/ConversationViewModel.swift` | Add `assistantJoinStatus`, update `requestAssistantJoin()` error handling |
| `Convos/Conversation Detail/Messages/MessagesListView/MessagesListItemType.swift` | Add `.assistantJoinStatus` case |
| `Convos/Conversation Detail/Messages/MessagesListView/MessagesListView.swift` | Render `AssistantJoinStatusView` for new case |
| `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/Cells/MessagesListItemTypeCell.swift` | Render new case in UIKit cell |
| `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/AssistantJoinStatusView.swift` | **New file** — the status row view |
| `Convos/Conversation Detail/AddToConversationMenu.swift` | Disable button when `assistantJoinStatus != nil` |
| `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/MessagesViewController.swift` | Inject status item into list |

## Out of Scope

- Pre-checking agent availability before showing the menu
- Persisting the join status across app restarts
- Showing status in the conversations list (home view)
- Retry with exponential backoff (simple single retry is sufficient)
