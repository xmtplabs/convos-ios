# XMTP Read Receipts Investigation

## What XMTP Provides

### ReadReceiptCodec
- Located at `XMTPiOS/Codecs/ReadReceiptCodec.swift`
- Content type: `xmtp.org/readReceipt:1.0`
- `ReadReceipt` is an empty struct — no payload, just the message existence + sender + timestamp
- `shouldPush` returns `false` — no push notifications for read receipts
- Fallback is `nil` — the message is not expected to be displayed
- Read receipts must be filtered out and not shown to users as messages

### Sending a Read Receipt
Send via regular `conversation.send()`:
```swift
Client.register(codec: ReadReceiptCodec())
try await conversation.send(
    content: ReadReceipt(),
    options: .init(contentType: ReadReceiptCodec().contentType)
)
```

### Querying Read Times
```swift
let lastReadTimes: [String: Int64] = try conversation.getLastReadTimes()
// Returns: [inboxId: sentAtNs] for each member's most recent read receipt
```

This is built into the XMTP SDK at the FFI level — no manual message scanning needed.

### Key Docs Notes (from docs.xmtp.org)
- **Opt-out**: Best practice is to provide users with the option to opt out of sending read receipts
- **Display**: Read receipt indicator should be displayed under the message it's associated with, can include a timestamp
- **Filtering**: Read receipts are empty messages — must filter them out so they don't render as visible messages
- **Timestamp comparison**: The read receipt timestamp indicates "everything up to this time was read" — compare message timestamps to determine which messages have been read
- **No push**: `shouldPush` is false, so properly configured notification servers won't send push for read receipts

## Implementation Plan

### Phase 1: Infrastructure
1. **Register `ReadReceiptCodec`** in `InboxStateMachine.swift` codecs array
2. **Handle in `DecodedMessage+DBRepresentation.swift`**: Add `ContentTypeReadReceipt` case — skip storing as a visible message (return early or use a non-visible content type)
3. **Handle in `StreamProcessor`**: When receiving a read receipt, update local state rather than storing a message
4. **Handle in `IncomingMessageWriter`**: Skip read receipt messages (don't store in message table)

### Phase 2: Sending Read Receipts
1. **Add `sendReadReceipt()` to `MessageSender` protocol** (or a separate protocol)
2. **Trigger when user views a conversation**: When `MessagesViewController` appears / messages are displayed
3. **Debounce**: Don't send on every message — send when the user opens/focuses a conversation, or periodically while viewing
4. **Store locally**: Track last sent read receipt timestamp per conversation to avoid redundant sends

### Phase 3: Displaying Read Status
1. **Store read times in DB**: New table or column — `conversation_read_receipts(conversationId, inboxId, readAtNs)`
2. **Update `MessageStatus`**: Add `.read` status or a separate "read by" indicator
3. **UI**: Show read indicators on messages (e.g., "Read" or profile avatars of readers under the last read message)

### Phase 4: Real-time Updates
1. **Stream processing**: Update read receipt state when receiving read receipt messages via stream
2. **Polling fallback**: Periodically call `getLastReadTimes()` to sync state

## Key Decisions Needed
- **Groups vs DMs**: Read receipts in groups show who has read up to what point. Do we show this for all groups or just DMs?
- **Privacy**: Should read receipts be opt-in/opt-out per user?
- **UI treatment**: iMessage-style "Read" text? Profile avatar bubbles under last read message? Both?
- **Frequency**: How often to send read receipts? On open? On scroll? Throttled?
- **Storage**: Do we need a new DB table for read receipt state, or can we use `getLastReadTimes()` on demand?

## Effort Estimate
- Phase 1 (infra): Small — register codec, skip in message pipeline
- Phase 2 (sending): Medium — protocol addition, trigger logic, debouncing
- Phase 3 (display): Medium-Large — DB schema, UI changes, message status updates
- Phase 4 (real-time): Small — stream handler addition

## Files to Modify
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` (register codec)
- `ConvosCore/Sources/ConvosCore/Storage/XMTP DB Representations/DecodedMessage+DBRepresentation.swift` (handle content type)
- `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift` (process read receipts)
- `ConvosCore/Sources/ConvosCore/Storage/Writers/IncomingMessageWriter.swift` (skip storing)
- `ConvosCore/Sources/ConvosCore/Messaging/XMTPClientProvider.swift` (send method)
- New: DB migration for read receipt storage
- New: Read receipt repository/writer
- UI: Message status views
