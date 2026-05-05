# Assistant Builder — Honk-Style Focus Mode

**Status:** Plan / prototype
**Branch:** `jarod/assistant-builder`
**Owner:** Jarod
**Last updated:** 2026-05-04

## 1. Summary

Prototype a new conversation experience used to **build an assistant**. The user
opens a dedicated builder flow, a 1:1 conversation with an assistant agent is
auto-created, and the conversation enters a **Focus Mode** that mimics
[Honk](https://benji.org/honkish): one large bubble for the focused member's
live text, one bubble area for the rest, with text streamed character-by-character
as a custom content type rather than as discrete messages. When the assistant
decides it has enough information, it ends Focus Mode and the screen transitions
into a normal `ConversationView` for ongoing chat.

Visually the prototype borrows Honk's "two-bubble live-typing canvas" pattern but
uses Convos design tokens (colors, bubble shape with the existing `.tailed` mask)
and our existing `MessagesBottomBar` composer chrome.

## 2. Goals & Non-Goals

### Goals
- Add a new entry point on the conversations list (`hammer.fill` toolbar button).
- Reuse `NewConversationViewModel` machinery to create the conversation (single
  source of truth for invite generation, scanner, error handling).
- Introduce **Focus Mode** as a per-conversation state driven by a custom
  content type, with a single "focused" member (the assistant) and the rest as
  the chorus.
- Stream text per-keystroke between participants without polluting the messages
  list, using the same ephemeral pattern as `TypingIndicatorCodec`.
- Persist the live focus/streaming state in **GRDB** so SwiftUI subscribes via
  `ValueObservation` rather than directly to the XMTP stream.
- Provide a **debug bootstrap sheet** so the human can hand-join with the
  `convos-cli` tool while the agent endpoint isn't wired yet.
- End-of-session transition: when assistant fires "stop" focus, swap the bottom
  section for a "Start chatting" CTA that animates into a standard
  `ConversationView`.

### Non-Goals (this prototype)
- Real assistant inference / decision-making — the human running `convos-cli`
  acts as the assistant.
- Attachments inside Focus Mode. The composer's media row is shown disabled /
  out of scope for the streaming path; only text + clear are wired.
- Multi-assistant or multi-focus support. One focused member at a time.
- Voice / call modes from Honk. Out of scope.
- Haptics and sound design. (Animations are explicitly **in** scope — see
  next section.)

### Animation is in scope and load-bearing

The whole prototype lives or dies on how the live-typing canvas *feels*. A
working-but-flat implementation undersells the concept. So we treat animation
as a first-class deliverable, not polish to add later. Concrete commitments:

- **Region resizing** uses a single shared `withAnimation(.spring(response: 0.45, dampingFraction: 0.85))`
  driven by the typing-state matrix in §5.4 — every transition between the
  five rows of that table is animated. No hard cuts.
- **Bubble appearance / disappearance** uses `matchedGeometryEffect` so the
  same bubble morphs as it changes size and position, rather than fading one
  out and another in.
- **Streaming text** rides on SwiftUI's text-content-transition (`.contentTransition(.numericText())`
  or `.contentTransition(.interpolate)` per character) so newly arrived
  characters slide/blur in instead of popping.
- **Clear** isn't an instant blank — it's a 600ms receiver-side delay, then a
  dissolve transition on the bubble's text (`.transition(.opacity.combined(with: .scale(scale: 0.95)))`).
- **Bootstrap → focus transition**: the CLI sheet doesn't just dismiss; the
  invite-code card collapses into the empty user bubble while the assistant
  bubble drops in from the top with a spring.
- **Focus → standard chat transition**: at end-of-session, the bottom bubble
  morphs into the "Start chatting" pill via `matchedGeometryEffect`, then on
  tap the whole canvas crossfades into `ConversationView` while the
  ConversationIndicator capsule rides through with `matchedGeometryEffect`.
- **Performance budget:** all of the above must hit 60fps on an iPhone 13 mini.
  If a transition can't be done in pure SwiftUI without dropping frames,
  prefer a simpler animation over a janky one — but always animate.

These commitments are reflected in checkpoint #5 (layout) and #8 (end
transition) below — animations land alongside the layout work, not as a
separate pass.

## 3. User Flow

1. User taps **hammer.fill** in the conversations list bottom bar.
2. `AssistantBuilderView` is presented as a sheet (mirrors how
   `NewConversationView` is presented).
3. View immediately:
   - Creates a new XMTP conversation (1:1 group, assistant slot empty).
   - Generates an invite (existing `InviteWriter.generate`).
   - Shows the **CLI Bootstrap Sheet** with a "Copy invite code" button.
4. Human pastes the invite code into `convos-cli` and joins.
5. Convos detects the new member (existing add-member callback path), and the
   client sends a `FocusModeControl(state: .start, focusedInboxId: <agent>)`
   custom content type.
6. CLI bootstrap sheet auto-dismisses on focus start.
7. View renders the **Focus Mode canvas** (two stacked bubble regions).
8. Both sides type — every keystroke fires a `StreamingText` codec; on receipt
   the local client concatenates and renders into the appropriate region.
9. Pressing return on either side fires a `StreamingClear` codec, with a small
   server-side delay so the receiver gets a final frame to read.
10. When the assistant sends `FocusModeControl(state: .stop)`, the bottom region
    becomes a "Start chatting" button. Tapping animates into the standard
    `ConversationView`.

## 4. Data Model

### 4.1 Custom Content Types

All three are modeled on `TypingIndicatorCodec` (see
`ConvosCore/Sources/ConvosCore/Custom Content Types/TypingIndicatorCodec.swift`):
JSON-encoded `Codable` payload, `shouldPush:false`, no fallback push text. None
of them get persisted as `DBMessage` — they flow through a dedicated handler
into a new GRDB table (see §4.2).

```swift
// FocusModeControlCodec
public struct FocusModeControl: Codable, Sendable {
    public enum State: String, Codable, Sendable { case start, stop }
    public let state: State
    public let focusedInboxId: String?   // required when .start, nil on .stop
    public let sessionId: String         // groups the start/stop pair
}

// StreamingTextCodec
public struct StreamingText: Codable, Sendable {
    public let sessionId: String
    public let senderInboxId: String
    public let revision: UInt32          // monotonic per (session, sender)
    public let text: String              // full snapshot of current bubble
}

// StreamingClearCodec
public struct StreamingClear: Codable, Sendable {
    public let sessionId: String
    public let senderInboxId: String
    public let revision: UInt32          // must be > last StreamingText revision
}
```

**Why full-snapshot text instead of deltas:** the receiver doesn't have to
reconstruct from out-of-order chunks; a stale revision is dropped on arrival.
XMTP messages are not guaranteed to arrive in order, so deltas would force us
to handle reorder. Snapshots are also resilient to dropped messages — the next
keystroke catches the receiver up.

**Why `revision` and not just timestamp:** clock skew between clients +
sub-millisecond keystrokes. Each sender increments locally; receivers compare
`(senderInboxId, revision)` to decide whether to apply.

**Codec registration:** add the three codecs to wherever
`AssistantJoinRequestCodec` is registered (search `Client.register` in
`ConvosCore`). Register in both the main app and the notification service
extension.

### 4.2 GRDB Schema

We do **not** want SwiftUI hooking the XMTP stream directly. Mirror the
`TypingIndicatorManager` pattern but persist into GRDB so views observe via
`ValueObservation`.

New table `DBFocusSession`:

| column | type | notes |
|---|---|---|
| `sessionId` | text PK | from FocusModeControl |
| `conversationId` | text indexed | FK to DBConversation |
| `focusedInboxId` | text | who's in the spotlight |
| `state` | text enum | `started` / `stopped` |
| `startedAt` | date | |
| `stoppedAt` | date? | nil while live |

New table `DBLiveBubble` (one row per session × member, upserted on each
StreamingText):

| column | type | notes |
|---|---|---|
| `sessionId` | text | FK to DBFocusSession |
| `senderInboxId` | text | composite PK with sessionId |
| `text` | text | latest snapshot |
| `revision` | int | last applied revision |
| `updatedAt` | date | for clear-delay scheduling |

Migration in `SharedDatabaseMigrator.swift`. Both tables are app-scoped; no
shared database concerns since this is a UI-only feature.

**Apply rules:**
- On `StreamingText`: upsert if `revision > existing.revision`, else drop.
- On `StreamingClear`: only blank the row if `revision > existing.revision`.
  Schedule a 600ms delay before clearing locally so the receiver sees the final
  text. The clear is wall-clock-driven; no separate "clear-pending" flag needed.
- On `FocusModeControl(.stop)`: leave `DBLiveBubble` rows in place but mark the
  session `stopped`. Views key off session state.

### 4.3 Writers / Repositories

- **`FocusSessionWriter`** in
  `ConvosCore/Sources/ConvosCore/Storage/Writers/`: handlers for
  `handleFocusModeControl(_:)`, `handleStreamingText(_:)`,
  `handleStreamingClear(_:)`. Idempotent under retries.
- **`FocusSessionRepository`**: vends a GRDB `ValueObservation<DBFocusSession?>`
  for the currently-active session of a conversation, and
  `ValueObservation<[DBLiveBubble]>` for the per-member bubble snapshots.
- **`FocusSessionPublisher`** (sender-side): owns local revision counters and
  a debounced sender (see §6 for cadence rules). Talks to
  `MessagingService.send(custom:)`.
- Wire all three into `MessagingService` exactly where `TypingIndicatorManager`
  is wired. Look at `Convos/Conversation Detail/ConversationViewModel+TypingIndicators.swift`
  for the existing pattern.

### 4.4 Hidden-from-list contract

`MessageContentType` already has `marksConversationAsUnread`
(`ConvosCore/Sources/ConvosCore/Storage/Models/MessageContentType.swift`).
Extend the enum with `.focusModeControl`, `.streamingText`, `.streamingClear`
and return `false` for all three. **However**, like `TypingIndicator`, the
`ConversationWriter` should also early-return *before* persisting these as
`DBMessage` rows — see the `isTypingIndicator` short-circuit at
`ConversationWriter.swift:637`. We'll add an `isFocusEphemeral` analog.

## 5. iOS Architecture

### 5.1 Entry Point — Conversations list bottom bar

`Convos/Conversations List/ConversationsView.swift` already declares two
`ToolbarItem(placement: .bottomBar)` items (Scan, Compose) preceded by a
`Spacer`. Reorder so the new button sits **leading** of the spacer:

```swift
ToolbarItem(placement: .bottomBar) {
    Button("Build assistant", systemImage: "hammer.fill") {
        viewModel.onStartAssistantBuilder()
    }
    .accessibilityIdentifier("assistant-builder-button")
}
ToolbarItem(placement: .bottomBar) { Spacer() }
ToolbarItem(placement: .bottomBar) { /* Scan */ }
ToolbarItem(placement: .bottomBar) { /* Compose */ }
```

`ConversationsViewModel` gets a new `presentingAssistantBuilder: Bool` plus
`onStartAssistantBuilder()`. The presentation point mirrors `NewConversationView`'s
sheet attachment (sibling sheet on the conversations container).

### 5.2 `AssistantBuilderView` (top-level)

Wraps `AssistantBuilderViewModel` — a sibling of `NewConversationViewModel`.
Reuses internals where possible:
- Same conversation-creation pipeline (writer chain → publish → persist).
- Same `ConversationPresenter` shell so the right-pane behavior is consistent.
- Same `ConversationIndicator` at the top, but with `placeholderName: "New assistant"`.
  The "+" toolbar item maps to `viewModel.onAddParticipant()` (same as
  NewConversationView's flow).

The body branches three ways:
- `case bootstrap` → `CLIBootstrapSheet` (modal-on-top of the indicator + empty canvas).
- `case focus(session)` → `FocusModeView(session:)`.
- `case stopped(conversationViewModel)` → `ConversationView(...)` (existing component).

### 5.3 Bootstrap & CLI Debug Sheet

- On `AssistantBuilderViewModel.init`, immediately call
  `messagingService.createAssistantConversation()` (new helper that creates a
  group seeded with the current user only, then triggers
  `InviteWriter.generate(for:expiresAfterUse: true, expiresAt: now + 10m)`).
- Sheet content: large title "Invite the assistant", monospaced invite slug,
  big "Copy invite code" button (`UIPasteboard.general.string = slug`), small
  "Waiting for assistant…" footer with a `ProgressView`.
- Sheet listens (via the conversation members `ValueObservation`) for the
  member count to grow to 2. On detection:
  1. Send `FocusModeControl(.start, focusedInboxId: newMember.inboxId, sessionId: UUID().uuidString)`.
  2. Dismiss sheet.
  3. View transitions to `case focus(session)`.

### 5.4 `FocusModeView`

```
┌─────────────────────────────────┐
│   ConversationIndicator         │  ← reused, label "New assistant"
├─────────────────────────────────┤
│                                 │
│      ASSISTANT BUBBLE           │  ← top region (read-only)
│      (focused member)           │
│      tail: top-trailing         │
│                                 │
├─────────────────────────────────┤
│                                 │
│      USER BUBBLE = TEXTFIELD    │  ← bottom region
│      user: tail bottom-trailing │     (typing happens *in* the bubble)
│      others: tail bottom-leading│
│                                 │
├─────────────────────────────────┤
│   media bar (planned, not in    │
│   this PR — see §5.5)           │
├─────────────────────────────────┤
│   system keyboard               │
└─────────────────────────────────┘
```

**Region sizing rules** (one source of truth, computed property on the
view-model returning `(topFraction: CGFloat, bottomLayout: BottomLayout)`):

| user typing | other(s) typing | top : bottom | bottom split |
|---|---|---|---|
| no | no | 50 : 50 | full user (empty) |
| yes | no | 50 : 50 | full user |
| no | yes | 30 : 70 | 70% others, 30% user (empty) |
| yes | yes | 50 : 50 | 50/50 user/others |
| no | yes → stops | 70 : 30 | 30% other (final text), 70% user |

"Typing" means `DBLiveBubble.text` is non-empty within the active session for
that member. The transitions are animated (`withAnimation(.spring)`).

**Bubble component:** `MessageContainer` currently locks tail orientation to
`isOutgoing`. We introduce a sibling view `LiveBubble(corner: BubbleCorner, …)`
with a configurable corner enum. Same `UnevenRoundedRectangle` mask trick; we
just parameterize which corner gets the small radius.

The user's own `LiveBubble` is **also the text input** (see §5.5) — there is
no separate composer field. The bubble's content is a `TextField` /
`TextEditor` styled to fill the bubble; the bubble's background is the user's
accent color, the text is large and centered (Honk-style).

**Other-members typing area:** when there's >1 non-focused member talking,
stack their `ClusteredAvatarView` (existing component at
`Convos/Shared Views/ClusteredAvatarView.swift`) in the bubble's leading inset
as the typing-indicator avatar cluster.

### 5.5 Composer wiring — typing into the bubble itself

**We do not reuse `MessagesBottomBar`.** Honk's defining UX is that the
keyboard types directly into the giant message bubble — there's no separate
input field. We mirror that.

A new view `LiveBubbleEditor` wraps `LiveBubble` with a backing `TextField`
(SwiftUI `TextField` with `.lineLimit(nil)` plus a large title font, axis
`.vertical`) bound to a `String` on the focus view-model. The bubble's
background is the user's accent color and the text is rendered white, large,
centered — same look as the read-only `LiveBubble` so the two share a layout.

The view-model wires:

```swift
@FocusState private var isComposing: Bool
@State private var draftText: String = ""

LiveBubbleEditor(text: $draftText, isFocused: $isComposing)
    .onChange(of: draftText) { _, newValue in
        focusSessionPublisher.publish(text: newValue)
    }
    .onSubmit {
        focusSessionPublisher.clear()
        draftText = ""
    }
```

Per-keystroke, `focusSessionPublisher.publish` debounces at ~50ms, bumps
`revision`, and ships a `StreamingText`. On submit (return key), it ships a
`StreamingClear` and clears `draftText` locally. Nothing is persisted as a
`DBMessage` — there is no "send" in focus mode.

`isComposing` is set `true` automatically whenever the focus session starts so
the keyboard surfaces immediately. Tapping anywhere on the user's bubble
re-focuses the editor.

**Media bar (planned, not in this PR):** Honk shows a row of icons (keyboard
toggle, sparkle, camera, photos, mic, HONK, trash) directly under the user's
bubble and above the keyboard. We will eventually lift `MessagesMediaButtonsView`
into this slot and add a trash-can affordance that fires `StreamingClear`. For
the prototype only the bubble + keyboard + return-to-clear behavior is wired.

### 5.6 End-of-session transition

When `FocusSessionRepository` observes `DBFocusSession.state == .stopped`:
- Bottom region animates to a single full-width primary button:
  `Button("Start chatting")`.
- On tap: `AssistantBuilderViewModel.state = .stopped(conversationViewModel:)`.
  The view's `Group` swap from `FocusModeView` → `ConversationView` rides on
  `withAnimation(.smooth)` plus a `matchedGeometryEffect` on the
  ConversationIndicator capsule so it threads through.

## 6. Streaming Cadence Rules

These are the exact rules the user sketched, made explicit so we don't bikeshed
them later:

1. **Per-keystroke send, locally debounced at 50ms.** Each `messageText` change
   schedules a send; if another change lands within 50ms, the previous timer is
   cancelled. This caps the wire rate at ~20 msgs/sec per typist.
2. **Always send a snapshot, never a delta.** Payload `text` is the full current
   composer string.
3. **Revision is monotonic per (sessionId, senderInboxId).** Receiver drops any
   `StreamingText` with `revision <= existing.revision`. Same rule for
   `StreamingClear`.
4. **Return key fires `StreamingClear`.** Locally, `messageText` is cleared
   immediately so the typist sees an empty composer. Receiver delays the visual
   clear by **600ms** so the final phrase is readable.
5. **Trash-can affordance** (Honk-style, planned but out of scope this round)
   maps to the same `StreamingClear`.
6. **Focus stop** invalidates the active session. Any late-arriving
   `StreamingText` for a stopped session is dropped at the writer.
7. **Reconnect / resume:** on app cold-start, if a `DBFocusSession` is `started`
   but the last activity is older than 60s, treat as orphaned and mark
   `stopped` locally. Don't try to resume.

## 7. Implementation Order

Single PR. Each row below is a **commit checkpoint** — the work compiles and
the relevant tests pass before moving on. No stacking.

| # | Checkpoint | Deliverable |
|---|---|---|
| 1 | Plan | This document committed. |
| 2 | Codecs + GRDB | Three new codecs, registration, migration for `DBFocusSession` + `DBLiveBubble`, writer + repo with unit tests in `ConvosCoreTests`. No UI yet. |
| 3 | Entry point | `hammer.fill` button on conversations list, `AssistantBuilderView` shell, `AssistantBuilderViewModel`, sheet plumbing. View shows a stub. |
| 4 | Bootstrap sheet | CLI debug sheet with copy-invite, member-join detection, auto-fire `FocusModeControl(.start)`. End-to-end testable with `convos-cli`. |
| 5 | FocusModeView (no streaming) | Two-region layout, `LiveBubble` with configurable tail corner, region-sizing rules. Reads from `DBLiveBubble` but bubbles are still empty. |
| 6 | Streaming text | `FocusSessionPublisher` wired to composer, receiver writer applies snapshots, both sides see live text. |
| 7 | Clear + cadence | Return-to-clear with delay, revision drops, debounce. |
| 8 | End transition | "Start chatting" CTA + animation into `ConversationView`. |

## 8. Open Questions

1. **Where does the assistant identity actually come from?** This prototype
   uses a human via `convos-cli`. Production needs an `agent-join` endpoint
   that auto-joins on a known invite slug. Track this separately.
2. **Should the conversation be discoverable from the conversations list while
   still in focus mode?** Likely yes (it's a real XMTP group), but it should
   render with a distinctive treatment (badge / placeholder name) until focus
   stops. Defer to phase 8.
3. **Push behavior for `FocusModeControl(.start)`:** the assistant joins → we
   send a control message. Does the user's other devices need a push? For now
   `shouldPush: false` everywhere; revisit when multi-device matters.
4. **Conflict on "+":** the indicator's "+" in NewConversationView adds a
   participant. In assistant-builder, adding a *second* assistant is undefined.
   Plan: hide the "+" while a focus session is live; show it only in the
   `bootstrap` and `stopped` states.
5. **What does "stop" on the assistant side actually look like over the wire?**
   For the prototype: a literal CLI command (`convos-cli send-stop <conv-id>`)
   that ships `FocusModeControl(.stop)`. Real assistant infers it.
6. **Text length cap.** A live bubble with 5KB of streamed text is silly.
   Cap composer at, say, 500 chars; reject `StreamingText` payloads larger
   than 1KB at the writer.

## 9. Risks

- **GRDB migration ordering** — adding two tables in the shared migrator. Check
  that the migration is gated on app target only (these aren't shared with the
  notification extension).
- **SwiftUI type-check time** — `FocusModeView` will have animated layout that
  branches on multiple bool states. Follow the SwiftUI rules in `CLAUDE.md`:
  hoist all conditionals to typed `let`s, cap body at 50 lines, extract
  `LiveBubble` and the region-size table to helpers from the start. This is
  a known cliff (we just landed PR #794 + #795 to address it).
- **XMTP message ordering** — the snapshot+revision design tolerates this, but
  we should write a unit test that interleaves messages out-of-order and
  verifies the final state is correct.
- **Assistant-not-joining timeout** — if no member joins within 10 minutes,
  what's the UX? Plan: fall back to a "Try again" button on the bootstrap sheet.

## 10. Files We'll Touch

New:
- `ConvosCore/Sources/ConvosCore/Custom Content Types/FocusModeControlCodec.swift`
- `ConvosCore/Sources/ConvosCore/Custom Content Types/StreamingTextCodec.swift`
- `ConvosCore/Sources/ConvosCore/Custom Content Types/StreamingClearCodec.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBFocusSession.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBLiveBubble.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Writers/FocusSessionWriter.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/FocusSessionRepository.swift`
- `ConvosCore/Sources/ConvosCore/Messaging/FocusSessionPublisher.swift`
- `Convos/Assistant Builder/AssistantBuilderView.swift`
- `Convos/Assistant Builder/AssistantBuilderViewModel.swift`
- `Convos/Assistant Builder/CLIBootstrapSheet.swift`
- `Convos/Assistant Builder/FocusModeView.swift`
- `Convos/Assistant Builder/LiveBubble.swift`
- `Convos/Assistant Builder/LiveBubbleEditor.swift` (TextField-backed bubble for the user)
- `Convos/Assistant Builder/FocusRegionLayout.swift`

Edited:
- `Convos/Conversations List/ConversationsView.swift` — toolbar item + sheet attach.
- `Convos/Conversations List/ConversationsViewModel.swift` — `onStartAssistantBuilder`.
- `ConvosCore/Sources/ConvosCore/Storage/Models/MessageContentType.swift` — three new cases.
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationWriter.swift` — `isFocusEphemeral` short-circuit.
- `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift` — two new tables.
- Codec registration site (search for `AssistantJoinRequestCodec()`) — register three new codecs.

## 11. Out-of-Scope Cleanups (capture for later)

- The Honk-style media row at the bottom of the focus canvas (camera, photos,
  voice, trash). Once Focus Mode is solid, lift `MessagesMediaButtonsView` and
  add a trash-can affordance that fires `StreamingClear`.
- "Rapid honk"-style attention-grab gesture inside focus mode.
- Theming per-conversation (Honk gives each chat its own color). Convos already
  has per-conversation accent — wire it into `LiveBubble.background`.
