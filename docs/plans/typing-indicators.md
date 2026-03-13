# Typing Indicators — Investigation & Plan

## Status: Investigation

## Summary

Add real-time typing indicators so users can see when other members of a conversation are currently typing. Since XMTP does not natively support typing notifications (XIP-65 is still a proposal), we'll implement this using a custom content type sent as ephemeral XMTP messages.

## Existing Code

We already have UI scaffolding in place:

- **`TypingIndicatorView`** — SwiftUI view showing a message bubble with `PulsingCircleView` (3 pulsing dots). Currently single-user only, no avatar support.
- **`TypingIndicatorCollectionCell`** — UICollectionViewCell wrapper for the indicator, registered in `MessagesCollectionViewDataSource`.
- **`TypingState`** — Simple `idle`/`typing` enum (unused in ViewModel).
- **`PulsingCircleView`** — Configurable pulsing dot animation with typing indicator preset.

None of this is wired up — no typing events are sent or received.

## Architecture

### Custom Content Type

A single content type with an `isTyping` boolean flag:

```
convos.org/typing_indicator:1.0
```

```swift
struct TypingIndicator: Codable, Sendable {
    let isTyping: Bool  // true = started typing, false = stopped
}
```

One type with a flag is simpler than two separate types and follows the pattern in XIP-65. The message is **not stored** in the local database — it's purely ephemeral, handled in-memory only.

### Why not two content types?

Two types (`typing_started` / `typing_stopped`) adds codec registration overhead and doesn't provide any benefit. A single type with a boolean is cleaner and matches XIP-65's approach.

### Sending (Outgoing)

**Where:** `ConversationViewModel` or a new `TypingIndicatorService`

1. Observe changes to `messageText` in the input field
2. On first character typed → send `TypingIndicator(isTyping: true)`
3. Debounce: don't re-send `isTyping: true` within 5 seconds
4. When text becomes empty OR after 10 seconds of no typing → send `TypingIndicator(isTyping: false)`
5. When message is sent → send `TypingIndicator(isTyping: false)`
6. When leaving the conversation → send `TypingIndicator(isTyping: false)`

**Throttling is critical** — we don't want to flood the group with typing messages on every keystroke.

### Receiving (Incoming)

**Where:** `StreamProcessor` → new in-memory `TypingIndicatorManager`

1. `StreamProcessor.processMessage` detects `ContentTypeTypingIndicator`
2. Instead of writing to DB, passes it to `TypingIndicatorManager`
3. `TypingIndicatorManager` maintains a `[inboxId: TypingInfo]` dictionary per conversation
4. Each entry has a timeout (e.g., 15 seconds) — if no refresh received, auto-expire to prevent stale indicators
5. Publishes updates via `AsyncStream` or `@Observable` for the UI to observe

### UI Changes

**`TypingIndicatorView` needs updates:**
- Accept an array of `ConversationMember` (the typers)
- Show horizontally stacked avatars at the leading edge using `ClusteredAvatarView` or similar
- Show "Alice is typing" for 1 person, "Alice and Bob are typing" for 2, "3 people are typing" for 3+
- Always rendered as the **last item** in the messages list

**`MessagesListItemType` needs a new case:**
```swift
case typingIndicator(typers: [ConversationMember])
```

This gets appended as the last item in the list by `MessagesListProcessor` (or by the ViewModel directly, since it's not derived from stored messages).

### Message Properties

- `shouldPush: false` — typing indicators must not trigger push notifications
- Not stored in DB — purely ephemeral, in-memory only
- Not displayed as a chat message — only drives the typing indicator UI

## Components to Build/Modify

### ConvosCore (new)
1. **`TypingIndicatorCodec`** — Custom content type codec (`convos.org/typing_indicator:1.0`)
2. **`TypingIndicatorManager`** — In-memory manager tracking who's typing per conversation, with auto-expiry

### ConvosCore (modify)
3. **`InboxStateMachine`** — Register `TypingIndicatorCodec` in codec list
4. **`StreamProcessor`** — Intercept typing indicator messages, route to `TypingIndicatorManager` instead of DB
5. **`OutgoingMessageWriter`** or new sending helper — Send typing indicator messages

### App (modify)
6. **`ConversationViewModel`** — Observe text input, send typing events (debounced), observe `TypingIndicatorManager` for incoming typing state
7. **`TypingIndicatorView`** — Update to accept multiple typers with stacked avatars
8. **`MessagesListItemType`** — Add `.typingIndicator` case
9. **`MessagesViewController`** / data source — Render typing indicator as last item

## Effort Estimate

| Component | Effort |
|-----------|--------|
| TypingIndicatorCodec | Small (follow ExplodeSettingsCodec pattern) |
| TypingIndicatorManager | Medium (per-conversation state, auto-expiry timers, thread safety) |
| StreamProcessor changes | Small (intercept + route) |
| Sending logic (debounce/throttle) | Medium (timing edge cases) |
| UI updates (multi-avatar, last item) | Medium |
| Integration + testing | Medium |

**Total estimate: ~3-5 days**

## Open Questions

1. **Group size limits?** — Should we disable typing indicators for very large groups to reduce message volume?
2. **DM vs Group behavior?** — Same behavior for both, or different?
3. **Rate limiting on XMTP side?** — Need to verify XMTP doesn't rate-limit these ephemeral messages. Since they go through the normal message pipeline, high-frequency sends could be an issue.
4. **Battery/network impact?** — Sending messages on every typing session adds network traffic. The debounce/throttle logic is important.
5. **Backward compatibility?** — Older clients will see unknown content type. The codec's `fallback` should return `nil` so nothing is displayed.

## References

- [XIP-65: Typing Notifications](https://improve.xmtp.org/t/xip-65-typing-notifications/929) — Proposes a similar approach but at the protocol level
- Existing codec pattern: `ExplodeSettingsCodec`, `AssistantJoinRequestCodec`
