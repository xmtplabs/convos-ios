# Feature: Message Replies

> **Status**: Implemented
> **Author**: @lourou
> **Created**: 2026-01-16
> **Updated**: 2026-02-04

## Overview

Enable users to reply to specific messages within conversations, creating a threaded context that makes it clear which message a user is responding to. This improves conversation clarity, especially in active group chats where multiple topics may be discussed simultaneously.

## Problem Statement

In active conversations, especially group chats, messages can quickly lose context as new messages arrive. Users currently have no way to explicitly reference which message they're responding to, leading to:

- Ambiguous responses that require scrolling back to understand context
- Confusion when multiple conversation threads happen simultaneously
- Lost context when messages are far apart in the timeline
- Difficulty following conversation flow in busy groups

## Goals

- [x] Enable users to reply to any message in a conversation
- [x] Display reply context inline with the reply message (show what's being replied to)
- [x] Persist reply relationships in the local database
- [x] Sync replies via XMTP protocol
- [x] Support replies for text messages and replies only
- [x] Support replies of replies (reference always shows immediate parent, not the thread root)

## Non-Goals

- Threaded view mode (displaying replies grouped together)
- Reply notifications that are distinct from regular message notifications
- Reply counts or analytics
- Replies to non-text content (attachments, system messages) in v1

## User Stories

### US1: As a user, I want to reply to a specific message

**Acceptance criteria:**
- [ ] ~~Long-pressing a message shows a reply option in the context menu~~ (conflicts with text selection)
- [x] Swiping right on a message opens the reply composer directly (like Apple Messages)
- [x] Swipe gesture is the primary way to initiate a reply
- [x] The referenced message preview shows sender name and message content (truncated if long)
- [x] User can dismiss the reply context and return to normal message composition
- [x] Sending the message creates a reply relationship to the original message

### US2: As a user, I want to see which message a reply is responding to

**Acceptance criteria:**
- [x] Reply messages display a visual indicator showing the referenced message
- [x] The reply reference shows the sender's name and a preview of the message content
- [x] Reply references are visually distinct from regular messages (outline bubble style)
- [x] Text messages and reply references show appropriate context
- [x] The reply UI works for both incoming and outgoing messages
- [x] If the parent message is deleted/unavailable, hide the reply reference (reply message remains visible)

## Technical Design

### Existing Infrastructure

The codebase already has strong foundations for reply support:

| Component | Status | Location |
|-----------|--------|----------|
| `DBMessage.sourceMessageId` | ✅ Exists | `DBMessage.swift` |
| `DBMessageType.reply` | ✅ Exists | `DBMessageType.swift` |
| `MessageReply` model | ✅ Exists (underutilized) | `MessageReply.swift` |
| `MessageWithDetails.sourceMessage` | ✅ Already queried | `MessageWithDetails.swift` |
| XMTP `ContentTypeReply` handling | ✅ Exists | `DecodedMessage+DBRepresentation.swift:119-163` |
| `AnyMessage.reply` case | ✅ Exists | `AnyMessage.swift` |

**Critical fix needed:** `MessagesRepository.composeMessages()` currently returns `nil` for `.reply` case (lines 384-405). This must be completed to hydrate `MessageReply.parentMessage`.

### Architecture

**New Components:**

| Component | Module | Location |
|-----------|--------|----------|
| `ReplyMessageWriter` | ConvosCore | `Storage/Writers/ReplyMessageWriter.swift` |
| Reply composer bar | Main App | `Conversation Detail/Messages/ReplyComposerBar.swift` |
| Reply reference view | Main App | `Conversation Detail/Messages/ReplyReferenceView.swift` |
| Reply action in menu | Main App | `Conversation Detail/Messages/Messages View Controller/Reactions/` |
| Scroll-to-message | Main App | `MessagesViewController` extension |

### ReplyMessageWriter

Follow the `ReactionWriter` pattern (stateless, takes conversationId per call) rather than extending `OutgoingMessageWriter`:

- Inject `InboxStateManagerProtocol` and `DatabaseWriter`
- Use XMTP SDK `Reply` type with `ContentTypeReply`
- Optimistic local insert: save `DBMessage` with `messageType: .reply` and `sourceMessageId` before network call
- Integrate via `MessagingServiceProtocol.replyWriter()` (similar to existing `reactionWriter()`)

### Menu Integration

Extend `MessageReactionMenuCoordinatorDelegate` with `onReply` callback:
- When Reply is tapped, dismiss menu and set `replyingToMessage` in `ConversationViewModel`
- Filter replyable messages: only `contentType == .text` or `messageType == .reply`

### ViewModel State

Add to `ConversationViewModel`:
- `replyingToMessage: AnyMessage?` - The message being replied to (nil = normal message mode)

When sending, pass `replyingToMessage?.base.id` to `ReplyMessageWriter`.

### UI/UX

**Screens affected:**
1. **Conversation Detail** - Primary screen for all reply interactions

**New views needed:**

1. **Reply Composer Bar** (above message input)
   - Shows referenced message with sender name and content preview
   - "X" button to cancel reply mode
   - Visually connects to the message input below

2. **Reply Reference View** (inline with messages)
   - Compact preview of the parent message
   - Shows sender name (if different from reply sender)
   - Shows first ~50 characters of text (truncated if longer)
   - Subtle connector line to parent message bubble
   - Tappable area to navigate to parent

**Navigation flow:**
1. User long-presses message → context menu appears with "Reply" option
2. User taps "Reply" → Reply composer bar appears above keyboard
3. Alternatively: User swipes message left and release → Reply composer bar appears above keyboard
4. User types message → send button creates reply relationship

**Visual design considerations:**
- Reply references should be compact (single line when possible)
- Use existing design tokens for colors and spacing
- Match the visual style of reactions menu for consistency
- Consider left-edge accent line to indicate reply relationship

## Implementation Plan

### Phase 1: Core Reply Sending ✅

- [x] Add `ReplyMessageWriter` to ConvosCore (similar to `OutgoingMessageWriter`)
- [x] Implement reply composition UI (reply bar above input with iOS 26 glass effect)
- [ ] ~~Hook up "Reply" action to message context menu~~ (conflicts with text selection)
- [x] Add swipe-right gesture to reply (per-bubble with haptic feedback)
- [x] Verify database storage of reply relationship

### Phase 2: Reply Display ✅

- [x] Fix `composeMessages()` to hydrate reply messages from database
- [x] Create `ReplyReferenceView` component (outline bubble style)
- [x] Integrate reply references into message bubbles
- [x] Handle text message content in references
- [x] Hide sender name for replies (already shown in "X replied to Y")

### Phase 3: Polish & Edge Cases ✅

- [x] Graceful handling of deleted/missing parent messages
- [x] Reply context restoration on send failure (retry UX)
- [x] Hide swipe arrow for outgoing messages
- [x] Design refinements using DesignConstants

## Testing Strategy

**Unit tests for:**
- `ReplyMessageWriter` send logic
- Reply message database queries
- Reply reference view rendering logic
- Message ID resolution and parent lookup

**Integration tests for:**
- End-to-end reply sending and receiving
- XMTP protocol compatibility (send from iOS, receive on other platforms)
- Database persistence of reply relationships across app restarts
- Reply syncing across multiple devices

**Manual testing:**
- Reply to text messages and replies
- Reply in group chats vs DMs
- Verify non-replyable messages don't show reply option

## Decisions

- **Replyable message types**: Only text messages and replies can be replied to (no system messages, attachments, or other content types for v1)
- **Reply-to-reply reference**: Always shows the immediate parent message, never the thread root
- **Reply counts**: No - not displaying reply counts on parent messages
- **Self-replies**: Allowed - useful for adding context or corrections

## Risks

| Risk | Mitigation |
|------|------------|
| `composeMessages()` returns nil for replies | Critical fix in Phase 2 - complete the `.reply` case hydration |
| Swipe gesture conflicts with existing gestures | Test thoroughly with long-press and scroll |
| Reply hydration performance with many replies | Monitor - current query already includes parent via association |

## References

- **Existing Code Patterns:**
  - Reactions system: `/Convos/Conversation Detail/Messages/Messages View Controller/Reactions/`
  - Message composition: `OutgoingMessageWriter.swift`
  - XMTP reply handling: `DecodedMessage+DBRepresentation.swift` (line 119-163)

- **XMTP Documentation:**
  - XMTP SDK already implements `ContentTypeReply`
  - Reply content structure: `Reply` object with `reference` (parent message ID) and `content`

- **Related Models:**
  - `/ConvosCore/Sources/ConvosCore/Storage/Models/MessageReply.swift`
  - `/ConvosCore/Sources/ConvosCore/Storage/Database Models/DBMessage.swift`
  - `/ConvosCore/Sources/ConvosCore/Storage/Database Models/DBMessageType.swift`
