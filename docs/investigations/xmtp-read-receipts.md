# XMTP Read Receipts — Implementation Plan

## Overview

Add read receipt support to Convos. When a user opens a conversation or receives a new message while viewing it, we send a read receipt. The last message sent by the current user shows "Read" with a horizontally scrolling list of profile avatars of members who have seen it (replacing the current "Sent" + checkmark). Users can opt out of both sending and seeing read receipts.

## XMTP SDK API

### ReadReceiptCodec
- Content type: `xmtp.org/readReceipt:1.0`
- `ReadReceipt` is an empty struct — timestamp is the message's `sentAt`
- `shouldPush` returns `false`
- Fallback is `nil` — must be filtered from visible messages

### Sending
```swift
try await conversation.send(
    content: ReadReceipt(),
    options: .init(contentType: ReadReceiptCodec().contentType)
)
```

### Querying
```swift
let lastReadTimes: [String: Int64] = try conversation.getLastReadTimes()
// Returns: [inboxId: sentAtNs] for each member's most recent read receipt
```

## DB Schema

New table: `conversation_read_receipts`
```sql
CREATE TABLE conversation_read_receipts (
    conversationId TEXT NOT NULL,
    inboxId TEXT NOT NULL,
    readAtNs INTEGER NOT NULL,
    PRIMARY KEY (conversationId, inboxId)
);
CREATE INDEX idx_read_receipts_conversation ON conversation_read_receipts(conversationId);
```

One row per member per conversation. Updated when a new read receipt is received (upsert with max timestamp). To find who has read a message: `WHERE conversationId = ? AND readAtNs >= message.dateNs AND inboxId != currentUserInboxId`.

This optimizes for the primary use case (who read the last sent message) while supporting future per-message queries with the same schema.

## Implementation

### Phase 1: Infrastructure

1. **Register `ReadReceiptCodec`** in `InboxStateMachine.swift` codecs array
2. **Skip in `DecodedMessage+DBRepresentation.swift`**: Add `ContentTypeReadReceipt` case, throw or return early (don't store as a visible message)
3. **Skip in `StreamProcessor.processMessage`**: Detect read receipt content type before calling `messageWriter.store()`, extract sender + timestamp, write to `conversation_read_receipts` instead
4. **Skip in NSE**: Drop read receipt messages in `MessagingService+PushNotifications.swift` (return `.droppedMessage`)
5. **DB migration**: Add `conversation_read_receipts` table

### Phase 2: Sending Read Receipts

1. **Add `sendReadReceipt` to `MessageSender` protocol** (or on `ConversationSender`)
2. **Trigger on conversation open**: When `MessagesViewController` appears and messages load
3. **Trigger on new incoming message**: When a message arrives while the conversation is active (`activeConversationId` matches)
4. **Debounce**: Don't re-send if we already sent one within the last N seconds for the same conversation
5. **Respect opt-out**: Check `GlobalConvoDefaults.sendReadReceipts` before sending

### Phase 3: Displaying Read Status

1. **New model**: `ReadReceipt` or extend `ConversationMember` with read status
2. **Query at display time**: For the last message sent by current user, fetch members from `conversation_read_receipts` where `readAtNs >= message.dateNs`
3. **UI in `MessagesGroupView`**: Replace "Sent" + checkmark with "Read" + horizontally scrolling avatar list
   - ScrollView with profile avatars (same size as current checkmark, ~16pt)
   - Max width capped, gradient fade on edges (same pattern as reactions HStack)
   - Only shows on the last message sent by current user (`isLastGroupSentByCurrentUser`)
   - Exclude current user from avatar list
   - If no one has read it yet, show "Sent" + checkmark (existing behavior)
4. **Respect opt-out**: If user has opted out, always show "Sent" (never "Read")

### Phase 4: Settings

1. **Add to `GlobalConvoDefaults`**: `sendReadReceipts: Bool` (default `true`)
2. **Add to `CustomizeSettingsView`**: Toggle row with appropriate icon/description
3. **When disabled**: Stop sending read receipts AND hide "Read" status (show "Sent" instead)

## Files to Modify

### ConvosCore
- `InboxStateMachine.swift` — register codec
- `DecodedMessage+DBRepresentation.swift` — handle content type (skip)
- `StreamProcessor.swift` — intercept read receipts, write to DB
- `SharedDatabaseMigrator.swift` — new migration
- `MessagingService+PushNotifications.swift` — drop in NSE
- `XMTPClientProvider.swift` — add `sendReadReceipt` to protocol
- New: `DBConversationReadReceipt.swift` — GRDB model
- New: `ReadReceiptWriter.swift` — write read receipts to DB
- New: `ReadReceiptRepository.swift` — query read receipts for UI

### Main App
- `MessagesGroupView.swift` — read status UI (replace "Sent" section)
- `GlobalConvoDefaults.swift` — add `sendReadReceipts` setting
- `CustomizeSettingsView.swift` — add toggle
- `ConversationViewModel.swift` or `MessagesViewController.swift` — trigger sending
- New: `ReadReceiptAvatarsView.swift` — scrolling avatar list with gradient fade

## Key Decisions
- **One table, not per-message**: `conversation_read_receipts` stores latest read timestamp per member per conversation — works for both "who read the last message" and future "who read message X"
- **Agents included**: Agents/assistants send read receipts and appear in the avatar list
- **Opt-out is both**: Disabling read receipts stops sending AND hides others' read status
- **Send frequency**: On conversation open + on each new incoming message while viewing
- **Default on**: `sendReadReceipts` defaults to `true`

## QA Testing
- Use two simulators + CLI tool for multi-member testing
- Test sending, receiving, display, opt-out, and edge cases
