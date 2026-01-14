# Tap to Like - Display a Heart

## Overview

Enable users to react to messages by tapping to display a heart, providing a lightweight way to acknowledge or appreciate messages without typing a response.

## Goals

1. Allow users to react to any message with a heart by tapping
2. Display heart reactions visibly on messages
3. Sync reactions across all conversation participants via XMTP
4. Keep the interaction simple and intuitive (double-tap)
5. Double tap again to remove

## Non-Goals

- Multiple reaction types (emoji picker) - future enhancement
- Reaction counts/aggregation for group chats - future enhancement
- Animated reaction effects - future enhancement

## User Experience

### Reacting to a Message

**Option A: Double-tap gesture**
- User double-taps on a message bubble
- Heart appears on the message with a subtle animation
- Heart is persisted and visible to all participants

**Option B: Long-press context menu**
- User long-presses on a message
- Context menu appears with heart option
- Tapping heart adds the reaction

**Recommendation:** Start with double-tap (Option A) as the primary gesture - it's the most intuitive and matches user expectations from Instagram/iMessage.

### Displaying Reactions

- Heart appears at the bottom-right corner of the message bubble
- If the current user reacted, heart is filled (❤️); otherwise outlined (♡)
- For group chats: show a single heart with count if multiple people reacted (e.g., ❤️ 3)
- Tapping the heart indicator opens the **Reactions Drawer**

### Reactions Drawer (Sheet)

When a user taps on the reaction indicator, a bottom sheet slides up showing who reacted.

**Drawer Layout:**
```
┌─────────────────────────────────────────┐
│  Reactions                          ✕   │  ← Header with close button
├─────────────────────────────────────────┤
│  ┌────┐  You                       ❤️   │  ← Own reaction always first
│  │ 👤 │  Tap to remove                  │  ← Subtle hint, tappable row
│  └────┘                                 │
├─────────────────────────────────────────┤
│  ┌────┐  Alex Johnson              ❤️   │
│  │ 👤 │                                 │  ← No "Tap to remove" for others
│  └────┘                                 │
├─────────────────────────────────────────┤
│  ┌────┐  Sarah Smith               ❤️   │
│  │ 👤 │                                 │
│  └────┘                                 │
└─────────────────────────────────────────┘
```

**Drawer Behavior:**
- Presented as a `.sheet` or bottom drawer (SwiftUI)
- Shows all users who reacted to this message
- **Own reaction always appears first** at the top of the list
- Each row displays: avatar, display name, and the reaction emoji on the right
- **Remove action**: Only for current user's own reaction
  - Shows "Tap to remove" in secondary text below the name
  - Entire row is tappable to remove
  - Tapping sends a reaction with `action: .removed` via XMTP
  - Row animates out after removal
  - Drawer dismisses automatically if no reactions remain
- Other reactors sorted by reaction timestamp (oldest first)
- Group conversations: Can have many reactors, drawer should be scrollable
- Empty state: If all reactions removed, drawer dismisses and indicator disappears

### Visual Design

```
┌─────────────────────────────┐
│ Hey, did you see the game   │
│ last night?                 │
└─────────────────────────────┘ ❤️

┌─────────────────────────────┐
│ Yes! That final play was    │
│ incredible!                 │
└─────────────────────────────┘ (not yet reacted)
```

## Technical Considerations

### XMTP Reaction Content Type

XMTP has a **built-in `Reaction` content type** with the following structure:

| Field | Type | Description |
|-------|------|-------------|
| `reference` | String | ID of the message being reacted to |
| `referenceInboxId` | String? | (Optional) Inbox ID of the message sender - helps with attribution in groups |
| `action` | Enum | `.added` or `.removed` |
| `content` | String | The reaction content (e.g., "❤️" or "U+2764") |
| `schema` | Enum | `.unicode`, `.shortcode`, or `.custom` |

**Swift Example - Sending a Reaction:**
```swift
let reaction = Reaction(
    reference: messageToReact.id,
    referenceInboxId: messageSenderInboxId, // Optional
    action: .added,
    content: "❤️",
    schema: .unicode
)

try await conversation.send(
    content: reaction,
    options: .init(contentType: ContentTypeReaction)
)
```

**Removing a Reaction:**
```swift
let reaction = Reaction(
    reference: messageToReact.id,
    action: .removed,
    content: "❤️",
    schema: .unicode
)

try await conversation.send(
    content: reaction,
    options: .init(contentType: ContentTypeReaction)
)
```

### Data Model (GRDB)

```
Reaction:
  - id: String (XMTP message ID of the reaction message itself)
  - messageId: String (reference - the message being reacted to)
  - senderInboxId: String (who sent the reaction)
  - action: String ("added" or "removed")
  - content: String (the emoji, e.g., "❤️")
  - schema: String ("unicode", "shortcode", "custom")
  - timestamp: Date
```

Note: Reactions are sent as regular XMTP messages with `ContentTypeReaction`. The `action` field handles add/remove - we don't delete reaction records, we track the latest action per sender+message+content combination.

### Existing Codebase Infrastructure (Already Implemented)

| Component | File | Description |
|-----------|------|-------------|
| `DBMessageType.reaction` | `DBMessageType.swift` | Enum case for reaction messages |
| `DBMessage.emoji` | `DBMessage.swift:53` | Column storing the reaction emoji |
| `DBMessage.sourceMessageId` | `DBMessage.swift:55` | Reference to the reacted-to message |
| `DBMessage.reactions` | `DBMessage.swift:100-104` | GRDB association to fetch reactions |
| `MessageWithDetails.messageReactions` | `MessageWithDetails.swift:9` | Reactions included with message fetch |
| `handleReactionContent()` | `DecodedMessage+DBRepresentation.swift:166-179` | Parses incoming XMTP reactions |
| `Reaction.emoji` | `Reaction+DBRepresentation.swift:5-18` | Converts unicode codes (e.g., "U+2764") to emoji |
| `MessageReaction` | `MessageReaction.swift` | Public model for reactions |

**What's missing:**
- Sending reactions (extend `OutgoingMessageWriter` or create `ReactionWriter`)
- UI to display reactions on messages
- Double-tap gesture to trigger reactions

### Storage

✅ **Already implemented** - Reactions are stored as `DBMessage` records with:
- `messageType: .reaction`
- `sourceMessageId` pointing to the reacted message
- `emoji` containing the reaction (e.g., "❤️")
- Indexed via `DBMessage.reactions` GRDB association

### Message View Updates

- MessageView needs to observe reactions for its message
- Display reaction indicator when reactions exist
- Handle gesture recognizer for double-tap

## Open Questions

1. **Gesture choice**: Double-tap vs long-press vs dedicated button?
   - *Recommendation: Double-tap (matches Instagram/iMessage expectations)*
2. ~~**XMTP content type**: Use existing reaction type or create custom?~~
   - ✅ **Answered**: XMTP has a built-in `Reaction` content type with `ContentTypeReaction`
3. ~~**Remove reaction**: Should users be able to un-react in v1?~~
   - ✅ **Answered**: Yes - XMTP supports this natively via `action: .removed`
4. **Own message reactions**: Can users react to their own messages?
   - *Recommendation: Yes, no technical limitation*
5. **Offline behavior**: Queue reactions for sync when back online?
   - *XMTP handles this via message queuing*
6. **Group chat display**: How to show multiple reactors?
   - *Use `referenceInboxId` to track who reacted*

## Success Metrics

- Reaction adoption rate (% of users who use reactions)
- Reactions per active user per day
- Time from feature launch to first reaction (onboarding)

## Implementation Phases

### Phase 1: Core Infrastructure
- ~~Research XMTP reaction content type~~ ✅ Done - using `ContentTypeReaction`
- ~~Define `Reaction` GRDB model~~ ✅ **Already exists**: `DBMessage` with `messageType: .reaction`
- ~~Create GRDB migration~~ ✅ **Already exists**: `emoji`, `sourceMessageId` columns in `message` table
- ~~Create ReactionRepository~~ ✅ **Already exists**: `DBMessage.reactions` association, `MessageWithDetails.messageReactions`
- Create `ReactionWriter` for sending reactions via XMTP (if not exists)

### Phase 2: Sending Reactions
- Extend `OutgoingMessageWriter` or create `ReactionWriter` to send reactions via XMTP
- Add double-tap gesture recognizer to MessageView
- Optimistically save reaction locally before XMTP publish

### Phase 3: Displaying Reactions
- ~~Handle incoming reaction messages~~ ✅ Already handled in `handleReactionContent()`
- ~~Fetch reactions with messages~~ ✅ Already in `MessageWithDetails.messageReactions`
- Update MessageView to display reaction indicator (heart icon)
- Create `ReactionIndicatorView` component (filled/outlined heart + count)

### Phase 4: Reactions Drawer
- Create `ReactionsDrawerView` (SwiftUI sheet)
- Display list of reactors with avatar, name, and emoji
- Add "Remove" action for current user's own reactions
- Handle empty state (dismiss when no reactions remain)
- Support scrolling for group chats with many reactors

### Phase 5: Polish
- Add subtle animation on react
- Handle edge cases (deleted messages, etc.)
- Performance optimization for conversations with many reactions

## Dependencies

- ~~XMTP SDK reaction support~~ ✅ Already supported
- ~~GRDB schema migration~~ ✅ Already exists - reactions stored as `DBMessage` with `messageType: .reaction`
- MessageView modifications (display reactions, double-tap gesture)
- ReactionWriter (send reactions via XMTP)

## Timeline

Implementation details and timeline TBD after technical design phase.
