# Fix: Pending Invite Stuck After Navigation

## Problem

When a joiner scans an invite QR code and the inviter approves (adds them to the XMTP group), the joiner's device can get permanently stuck showing the conversation as "pending invite."

**User report:** Andy scanned an invite for "Balloon Animals." The inviter confirmed Andy was added. Andy's device showed the conversation stuck as pending for 45+ minutes.

## Root Cause

The joiner's device discovers new XMTP groups through exactly **two** mechanisms:
1. **Conversation stream** — real-time stream from XMTP SDK
2. **Message stream** — when a message arrives for a group conversation

`syncAllConversations()` only syncs the XMTP data layer (LibXMTP/Rust). It does **not** list groups and process new ones into the local GRDB database.

There are three gaps that caused the bug:

### Gap 1: No post-sync group discovery
After `syncAllConversations` syncs from the network, there's no step that lists all XMTP groups and writes missing ones to the local DB. The app relies entirely on the conversation stream for discovery.

### Gap 2: Resume doesn't re-sync
`SyncingManager.handleResume()` only restarts streams — it doesn't call `syncAllConversations`. If the joiner was added to a group while the inbox was paused/backgrounded, the conversation stream won't emit it (it only streams *newly created* groups, not pre-existing ones).

### Gap 3: ValueObservation cancelled on navigation
`ConversationStateMachine.waitForJoinedConversation()` sets up a GRDB ValueObservation watching for a non-draft conversation with matching `inviteTag`. When the user navigates away, `handleStop()` cancels this observation. When the user returns to the conversation, it calls `useExisting()` which just sets state to `.ready` — it never restarts the observation.

**In Andy's case:** The inbox was stopped at 19:34:38 (after initial sync completed but before the inviter processed the join request). When it resumed at 19:42:25, only streams were restarted. The group had already been created on the network, so the conversation stream didn't emit it. No fallback mechanism existed to discover it.

## Fixes

### Fix 1: Post-sync group discovery in SyncingManager

After `syncAllConversations` completes, list all XMTP groups and process any that don't exist in the local DB.

**File:** `ConvosCore/Sources/ConvosCore/Syncing/SyncingManager.swift`

In `handleSyncComplete`, after calling `processJoinRequestsAfterSync`:

```
1. List all XMTP groups via client.conversationsProvider.listGroups(consentStates: params.consentStates)
2. For each group, check if a DBConversation exists with that group ID
3. If not, call streamProcessor.processConversation(group, params:) to store it
```

This is the primary fix — it provides a robust fallback regardless of how the stream missed the event.

### Fix 2: Re-sync on resume

When `handleResume()` is called (foreground, network reconnect), call `syncAllConversations` followed by the group discovery step from Fix 1.

**File:** `ConvosCore/Sources/ConvosCore/Syncing/SyncingManager.swift`

Modify `handleResume()` to:
1. Restart streams (existing behavior)
2. Call `syncAllConversations`
3. Run post-sync group discovery (Fix 1)
4. Run `processJoinRequestsAfterSync` (existing behavior)

### Fix 3: Restart join observation for pending drafts

When `ConversationStateMachine` receives `useExisting` for a draft conversation that has a pending invite (draft ID + inviteTag), restart the `waitForJoinedConversation` observation instead of immediately transitioning to `.ready`.

**File:** `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift`

Modify `handleUseExisting(conversationId:)`:
1. If the conversationId starts with `draft-`, look up the DBConversation
2. If it has an inviteTag and hasn't joined yet, start `waitForJoinedConversation(inviteTag:)` observation
3. Emit `.ready` with the draft ID so the UI still renders, but keep the observation running
4. When the observation fires (non-draft conversation appears), update the state with the real conversation ID

This ensures reopening a pending conversation re-arms the detection mechanism.

## Files to Modify

| File | Change |
|------|--------|
| `SyncingManager.swift` | Add `discoverNewConversations(params:)` after sync; call on resume |
| `ConversationStateMachine.swift` | Restart join observation for draft conversations in `handleUseExisting` |
| `StreamProcessor.swift` | Possibly extract `shouldProcessConversation` check for reuse |

## Testing

### Unit Tests
- `SyncingManager`: After sync completes, new groups are processed into DB
- `ConversationStateMachine`: `useExisting` with a draft ID + inviteTag starts observation
- `ConversationStateMachine`: Observation fires when matching non-draft conversation appears

### QA Test
See `qa/tests/XX-pending-invite-recovery.md` — covers the scenario where the joiner navigates away during the pending state and the invite is approved while they're in another conversation.
