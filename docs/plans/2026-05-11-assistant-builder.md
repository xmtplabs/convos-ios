# Feature: Assistant Builder

> **Status**: Draft
> **Author**: Jarod
> **Created**: 2026-05-11
> **Updated**: 2026-05-11

## Overview

A new entry-point view for creating an "AI helper" conversation. The user
types a prompt, optionally attaches media (photos, voice memo, files), and
taps **Make** to commit. Behind the scenes the app spins up a fresh
conversation, invites an assistant agent into it, and once both the
conversation is created **and** the assistant has joined, the **Make**
button enables. Tapping **Make** transitions (liquid-glass morph) the
draft composer into the standard messages bottom bar, revealing the
underlying chat with the user's first message ready to send.

This is a *variation* of `NewConversationView` — same presentation
pattern, same state-machine backbone, same conversation-indicator at
top, but with a different composer ("Assistant Draft Composer") and an
extra readiness gate (assistant has joined).

## Problem Statement

Today, creating an assistant-backed chat requires the user to:
1. Tap "Compose" → land in a new conversation with the QR placeholder
2. Open the "+" menu → tap "Instant assistant"
3. Wait silently while the assistant joins
4. Start typing once they realize they can

That's three taps and an opaque wait before the user can express what
they want help with. The Assistant Builder collapses the flow into one
view where the user can think about *what they want made* while the
assistant is being invited in the background.

## Goals

- [ ] One-tap entry from the conversations list (new bottom-bar button)
- [ ] User can start composing their request immediately — assistant
      provisioning is fully background
- [ ] Make button enables as soon as the text field is non-empty,
      regardless of readiness. If the user taps Make before the
      conversation reaches `.ready` and/or before the assistant has
      joined, the morph runs anyway and the composed message (text
      + attachments) is queued; `ConversationView` surfaces its own
      "Assistant is joining…" state, and the message dispatches as
      soon as the conversation reaches `.ready`
- [ ] Liquid-glass morph from builder composer → standard messages
      bottom bar on Make, with the conversation indicator persisting
- [ ] Continue / Discard intent on dismiss so accidental Xs don't lose
      the user's prompt
- [ ] Voice memo + photo + camera + file attachments work in the
      draft composer just like they do in the standard bottom bar

## Non-Goals

- **Not** building the gear icon next to the Make button (deferred)
- **Not** building the rolling-dice "randomize" icon in the top right
  of the composer (deferred)
- **Not** adding capability-resolution / skill picking inside the
  builder (assistant joins with the default "You're a Convos
  Assistant" instructions, same as today's `requestAssistantJoin`)
- **Not** persisting a "draft assistant" outside the in-memory
  view-model — Save just exits the builder without discarding the
  conversation
- **Not** building a Stuff/RHS counterpart for the builder (the builder
  doesn't have a Stuff pane)

## User Stories

### As a user who wants to make a custom AI helper, I want to type my prompt while the assistant is being set up so that I don't have to wait

Acceptance criteria:
- [ ] Tapping the hammer button on the conversations list opens the
      Assistant Builder immediately (sheet-presented like
      `NewConversationView`)
- [ ] The text field is focused and accepts input immediately, before
      the conversation is created on the network
- [ ] The Make button enables as soon as the text field has any
      content, regardless of whether the conversation has reached
      `.ready` and regardless of whether the assistant has joined
- [ ] If I tap Make before the conversation is ready, the morph
      animates me into `ConversationView` and my message (text +
      attachments) is queued. `ConversationView` shows its own
      "Assistant is joining…" indicator while the queue waits for
      `.ready`; the message dispatches automatically once the
      conversation flips ready.

### As a user who started composing and changed their mind, I want a confirm step on the X button so I don't lose my work

Acceptance criteria:
- [ ] If I tap X with text or attachments present, a context menu
      appears anchored to the X with Continue / Discard
- [ ] **Continue**: dismisses the menu and leaves me on the builder.
      Composer state, conversation, and any in-flight assistant
      invite are all untouched. Non-destructive.
- [ ] **Discard** (destructive): deletes the conversation. If the
      assistant has already joined, leaves the group first, then
      deletes.
- [ ] If I tap X with no text and no attachments, behaves as Discard
      with no confirm prompt (silently delete + leave).

### As a user who finalizes their prompt, I want the transition to feel like the composer is becoming the regular chat input

Acceptance criteria:
- [ ] Tapping Make morphs the composer (and its Make button) via a
      liquid-glass matched-geometry transition into the standard
      `MessagesBottomBar`'s text input + send button
- [ ] The conversation indicator at the top *does not move* during
      the transition — same view instance, same position
- [ ] After the morph, the user is in the regular `ConversationView`
      for the just-created conversation, with the composed message
      sent (or queued for send) as the first message

## Technical Design

### Architecture

#### Reused components

| Component | File | Reuse |
|---|---|---|
| `NewConversationViewModel` | `Convos/Conversation Creation/NewConversationViewModel.swift` | Inbox acquisition + state machine driving + optimistic placeholder pattern. Extended with a new `.newAssistant` mode. |
| `ConversationStateMachine` | `ConvosCore/.../ConversationStateMachine.swift` | Existing `.create` action drives conversation creation. No state-machine changes required for assistant-joined gating (we observe `conversation.hasAgent` externally). |
| `ConversationIndicatorView` | `Convos/Conversation Detail/Messages/ConversationIndicatorView.swift` | Same component, parameterized with `subtitle: "Draft"` and a custom placeholder title `"New assistant"`. Existing API (`untitledConversationPlaceholder`, `subtitle`) already supports this. |
| `MessagesMediaButtonsView` | `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/Views/MessagesMediaInputView.swift` | The bottom-left icons row. Already a focused component with toggles (`isSideConvoDisabled`); we'll pass `isSideConvoDisabled: true` and drop the convos-action button from the layout, or add a hide flag for the side-convo button specifically. |
| `VoiceMemoRecorder` + `VoiceMemoRecordingView` / `VoiceMemoReviewView` | `Convos/.../Views/VoiceMemo*.swift` | The recorder state + UI. Will need a small adaptation pass to bind to the draft composer's state instead of the messages bottom bar's. **Research item** — see Open Questions. |
| `PendingMediaAttachment` (model) | (existing) | Reused as-is; we render the chips below the text field instead of above. |
| `session.requestAgentJoin(slug:instructions:)` | Used today in `ConversationViewModel.requestAssistantJoin()` | Same call. We invoke it from the builder VM once the state machine emits `.ready` and the conversation has a usable invite slug. |
| `conversation.hasAgent` | `Conversation` model | The signal for "assistant has joined". The repository's `conversationsPublisher` will surface the updated flag when the assistant member appears. The builder VM observes this. |

#### New components

| Component | File | Responsibility |
|---|---|---|
| `AssistantBuilderView` | `Convos/Assistant Builder/AssistantBuilderView.swift` | Top-level SwiftUI view. Hosts the conversation indicator + composer + handles X-button menu + Make morph. |
| `AssistantBuilderViewModel` | `Convos/Assistant Builder/AssistantBuilderViewModel.swift` | Drives the builder. Owns the underlying `NewConversationViewModel`-equivalent state (or wraps one) plus assistant-readiness + composer state (text, attachments, voice memo). |
| `AssistantDraftComposer` | `Convos/Assistant Builder/AssistantDraftComposer.swift` | The composer view itself. Multi-line text field on top, `PendingMediaAttachmentRow` below, then a horizontal row with `MessagesMediaButtonsView` on left and `Make` capsule on right. |
| `NewConversationMode.newAssistant` | `Convos/Conversation Creation/NewConversationViewModel.swift` | New mode case. Behaves like `.newConversation` (autoCreate, optimistic placeholder) and, after the state machine emits `.ready`, triggers `session.requestAgentJoin`. |

#### New `NewConversationMode` case

Adding `.newAssistant` to the existing mode enum (`Convos/Conversation
Creation/NewConversationViewModel.swift:27-31`) makes the assistant
flow a peer of `.newConversation` / `.scanner` / `.joinInvite`. The
mode determines:

- `autoCreateConversation: true` (same as `.newConversation`)
- `startedWithFullscreenScanner: false`
- After the state machine emits `.ready`, fire
  `session.requestAgentJoin(slug:instructions:)` once and let the
  conversation publisher surface the assistant member when it joins.

`AssistantBuilderViewModel` consumes the `NewConversationViewModel`
(rather than subclassing) so its UI state (composer text, attachments)
stays separate. The wrapping view model adds:

- `composerText: String`
- `pendingAttachments: [PendingMediaAttachment]`
- `voiceMemoRecorder: VoiceMemoRecorder`
- `isMakeEnabled: Bool` — `!composerText.isEmpty`. The Make button's
  only gate. Readiness (state machine `.ready` and/or
  `conversation.hasAgent`) does **not** factor in — the builder is a
  thin pre-chat composer and the downstream `ConversationView` owns
  the "Assistant is joining…" indicator if the assistant hasn't joined
  by the time the morph completes.

### Sending the first message (queue-on-not-ready)

When Make is tapped:

1. The composer immediately morphs (see UI/UX → Liquid-glass morph
   on Make below) — that's our commitment indicator.
2. The builder VM calls `conversationStateManager.send(text:)` plus
   the existing eager-attachment-upload calls for each attachment.
3. **If the state machine is already `.ready`** (conversation
   published), the message dispatches immediately through the
   standard `OutgoingMessageWriter` path.
4. **If the state machine has not yet reached `.ready`**, the
   existing message-stream queue inside
   `ConversationStateMachine.sendMessage` (which yields into an
   `AsyncStream` consumed by a worker that awaits `.ready`) holds
   the message until the state machine flips. No new queueing layer
   needed — the existing one already serializes against `.ready`.
5. **Assistant-join timing is independent of message dispatch.**
   Messages can land in the conversation before the assistant has
   joined; the assistant sees them in history once it joins (the
   normal new-member catchup behavior), so there's no reason to
   gate the send on `assistantHasJoined`.

So the queue is the existing one, the Make path doesn't need
special-case wiring for "not ready yet", and the user's commitment
animation runs the same in either case.

### UI / UX

#### Entry point

Bottom toolbar on `ConversationsView`
(`Convos/Conversations List/ConversationsView.swift:158-174`). Add a
third `ToolbarItem(placement: .bottomBar)` for the hammer button,
positioned **before** (visually left of) the existing Compose button:

```swift
ToolbarItem(placement: .bottomBar) {
    Button("Make assistant", systemImage: "hammer") {
        viewModel.onStartAssistant()
    }
    .accessibilityLabel("Make a new assistant")
    .accessibilityIdentifier("assistant-builder-button")
}
.matchedTransitionSource(id: "assistant-builder-transition-source", in: namespace)

ToolbarItem(placement: .bottomBar) {
    Button("Compose", systemImage: "square.and.pencil") { … }
    …
}
```

`onStartAssistant()` on `ConversationsViewModel` parallels
`onStartConvo()` / `onJoinConvo()` and sets a new
`@Observable` property `assistantBuilderViewModel:
AssistantBuilderViewModel?` that drives a `.sheet(item:)` in
`ConversationsView`.

#### Layout

```
┌───────────────────────────────────────────┐
│   ┌─────────────────────────────────┐     │  ← navigation safe area
│   │  X                              │     │  ← top-left close button
│   │                                 │     │
│   │   ┌──────────────────┐          │     │  ← ConversationIndicator
│   │   │   New assistant  │          │     │     title="New assistant"
│   │   │       Draft      │          │     │     subtitle="Draft"
│   │   └──────────────────┘          │     │
│   │                                 │     │
│   ├─────────────────────────────────┤     │
│   │ Make a new little agent          │    │  ← text field placeholder
│   │ |                                │    │
│   │                                  │    │
│   │ ┌─────┐ ┌────────────────┐       │    │
│   │ │00:18│ │  📅 calendar   │ ✕     │    │  ← attachments below text
│   │ │ ~~~ │ │                │ ✕     │    │
│   │ └─────┘ └────────────────┘       │    │
│   │                                  │    │
│   │ 📷 📸 〰  📂          ⚙  ╭───╮   │    │  ← media buttons + Make
│   │                          │Make│   │   │
│   │                          ╰───╯   │    │
│   └─────────────────────────────────┘     │
│                                           │
└───────────────────────────────────────────┘
```

(Gear icon and dice icon in the mock are deferred — see Non-Goals.)

#### X-button context menu

When the user taps X with `composerText.isEmpty &&
pendingAttachments.isEmpty`: silently dismiss + cleanup. Otherwise:

```swift
.contextMenu(...) attached to the X button
  - Continue              // dismisses the menu; user stays on the builder
  - Discard (destructive) // delete conversation, leave group if assistant joined
```

Use `Menu` or a confirmation dialog anchored to the X. **Continue** is
the non-destructive option — it just closes the menu and leaves the
builder, composer state, and in-flight assistant invite alone.
**Discard** is destructive and runs the full cleanup (leave-then-
delete when the assistant has joined; direct delete otherwise).

#### Liquid-glass morph on Make

The morph is a layered, staged animation — *not* a sheet dismissal.
`AssistantBuilderView` is a `ZStack` from day one:

```
AssistantBuilderView (ZStack)
├── ConversationView(viewModel: underlyingConversationVM)   // bottom layer, always mounted
│   └── MessagesBottomBar  ← the matched-geometry *destination*
└── ComposerOverlay                                          // top layer
    ├── Backdrop fill (color)                                ← faded to clear on Make
    ├── X button
    ├── ConversationIndicatorView                            ← lives in this overlay layer
    └── AssistantDraftComposer                               ← the matched-geometry *source*
```

Both layers exist in the same SwiftUI render tree under one shared
`@Namespace`, so the matched-geometry source/destination can
interpolate across the morph.

**Per-element matched-geometry mapping**:

| Composer element | Bottom-bar destination | Notes |
|---|---|---|
| Multi-line text field | `MessagesBottomBar`'s message input | Same matched-geometry id (e.g. `"assistant-builder.textfield"`). The composer's vertical-axis text field morphs into the bottom bar's single-line input. |
| **Make** capsule button (right) | **Send** arrow button (right) | Capsule shape collapses to the circular send button. |
| Media buttons row (left, 4 buttons) | Media buttons bar (left, 5 buttons incl. side-convo) | Same matched-geometry id on the row container; the side-convo (orange Convos) button fades in independently (no source to morph from). |

**Staged animation sequence** (`withAnimation` cascade triggered by
`onMakeTap`):

1. **Phase A — content fade-out (≈150–200ms).** Attachments row and
   the text content inside the composer's text field fade and slide
   out. The text field's *shell* (border/background) stays put.
   Reason: the morph from "multi-line bordered text view" to
   "single-line bottom-bar input" looks cleaner without text content
   trying to reflow through the shape change.
2. **Phase B — backdrop reveal + shape morph (≈250–300ms, can
   start at the tail of A).**
   - `ComposerOverlay`'s backdrop fill animates its opacity to 0,
     revealing the `ConversationView` underneath.
   - The composer rounded rect's *interior chrome* (the rect's own
     fill/border) fades.
   - The three matched-geometry elements (text field shell, Make
     button, media buttons row) interpolate position+shape into
     their `MessagesBottomBar` counterparts.
   - The side-convo (orange Convos) button fades in inside the
     destination row.
3. **Phase C — overlay teardown.** Once the morph completes, the
   `ComposerOverlay` view is removed from the tree. The
   `ConversationIndicatorView` is *not* removed — it's promoted by
   either re-anchoring it onto `ConversationView`'s toolbar or by
   keeping it in the same overlay slot with the composer layer gone
   underneath. See Open Questions.

The `ConversationIndicatorView` instance does not animate or
re-mount — it stays in its slot for the entire transition. This is
the "conversation indicator stays in place" requirement.

The send call (`stateManager.send(text:)` + eager-attachment uploads)
is fired at the start of Phase A so the network work overlaps with
the animation. If the state machine has not yet reached `.ready`, the
existing message-stream queue holds the send; the user sees the
morph complete and lands on `ConversationView` with a message in the
pending-send state, which is the same UX the regular chat already
shows for offline / racey sends.

### Data Model

No new database tables or models. The builder reuses:

- `DBConversation` (created via the state machine)
- `DBConversationMember` (assistant member written by the standard
  invite-join flow)
- `PendingMediaAttachment` (in-memory only, same as `MessagesBottomBar`)

### API Changes

None. The builder uses existing:

- `session.prepareNewConversation()` → returns (service, optional
  cached existing conversation id)
- `stateManager.createConversation()` → publishes conversation +
  emits `.ready`
- `session.requestAgentJoin(slug:instructions:)` → invites the
  assistant
- `stateManager.send(text:)` / `send(image:)` / `send(text:afterPhoto:)` /
  voice-memo send → composes the first message

## Implementation Plan

### Phase 1: Entry point + view scaffolding

- [x] Add hammer-icon `ToolbarItem` to `ConversationsView`'s bottom
      toolbar, left of Compose
- [x] Add `assistantBuilderViewModel: AssistantBuilderViewModel?` to
      `ConversationsViewModel` and `onStartAssistant()` setter
- [x] Add `.sheet(item: $viewModel.assistantBuilderViewModel)` to
      `ConversationsView`'s sheet modifier
- [x] Create `Convos/Assistant Builder/` group + empty
      `AssistantBuilderView.swift` + `AssistantBuilderViewModel.swift`
      that build cleanly

### Phase 2: View-model + state machine wiring

- [x] Add `.newAssistant` case to `NewConversationMode`
- [x] `AssistantBuilderViewModel` wraps a `NewConversationViewModel`
      (mode `.newAssistant`) and forwards conversation state
- [x] After state machine reaches `.ready`, kick off
      `session.requestAgentJoin(slug:instructions: "You're a Convos
      Assistant")`. Track an `assistantJoinTask` on the builder VM.
- [x] Compute `isMakeEnabled = !composerText.isEmpty` (decoupled
      from readiness — the destination `ConversationView` handles
      the "Assistant is joining…" indicator if the morph completes
      before the assistant joins)

### Phase 3: Composer UI

- [x] `AssistantDraftComposer` view: multi-line `TextField` (
      `axis: .vertical`) with placeholder "Make a new little agent"
- [x] Attachments row **below** the text field. Reuses
      `PendingMediaAttachment` and `FileAttachmentRow`. Per-chip
      rendering lives in a new `PendingMediaAttachmentChip` view in
      `Convos/Assistant Builder/` (intentionally not yet shared with
      `MessagesInputView` — extraction can come later once both call
      sites are settled). No poof-on-remove animation yet — drop in
      from `MessagesInputView` later if needed.
- [x] Media buttons row reusing `MessagesMediaButtonsView` with
      side-convo button hidden via new `showsSideConvoButton: Bool =
      true` parameter (default preserves existing call sites)
- [x] `Make` button — capsule, primary color when enabled, disabled
      style otherwise (uses existing `.rounded(fullWidth: false)`
      `convosButtonStyle`)

### Phase 4: Conversation indicator on the builder

- [x] Place `ConversationIndicatorView` at the top of
      `AssistantBuilderView` with `untitledConversationPlaceholder:
      "New assistant"`, `subtitle: "Draft"`
- [x] Wire its `conversationName` / `conversationImage` to the
      underlying `NewConversationViewModel.conversationViewModel`'s
      conversation (so the user can rename / re-image the draft just
      like in the new-conv flow). Composer and indicator now share
      a single `@FocusState var focusState: MessagesViewInputFocus?`
      and a local `FocusCoordinator`, so tapping the indicator moves
      focus to `.conversationName` (expands the editor) and finishing
      moves it back to `.message` (the composer text field).

### Phase 5: X-button menu + dismissal cleanup

- [x] X button in top-left. Tap behaviour branches on `hasContent`:
      empty composer → silent discard + dismiss; non-empty composer →
      `confirmationDialog` with Continue (cancel role) / Discard
      (destructive). Confirmation dialog presents from the close button
      via the standard SwiftUI dialog plumbing — same visual treatment
      as native iOS destructive confirmations.
- [x] `AssistantBuilderViewModel.discard()` encapsulates the cleanup:
      cancels the in-flight `assistantJoinTask`, calls
      `newConversationViewModel.dismissWithDeletion()` to cancel the
      conversation-creation tasks, and — if the conversation has
      already transitioned out of draft state AND the assistant has
      joined — fires `conversationConsentWriter.delete(conversation:)`
      so the assistant sees us leave. Local DB cleanup is handled by
      the draft repository on VM dealloc.

### Phase 6: Voice memo adaptation

- [ ] Audit `VoiceMemoRecorder` + `VoiceMemoRecordingView` /
      `VoiceMemoReviewView` for coupling to `MessagesBottomBar`
- [ ] Extract any coupled state into the recorder's own model so the
      same recorder can back either composer
- [ ] Wire into `AssistantDraftComposer`'s voice-memo button

### Phase 7: Make → liquid-glass morph

- [ ] Restructure `AssistantBuilderView` as a `ZStack`: bottom layer
      `ConversationView(viewModel: underlyingConversationVM)`,
      top layer `ComposerOverlay` (backdrop + X button +
      `ConversationIndicatorView` + `AssistantDraftComposer`). Share
      one `@Namespace` across both layers.
- [ ] Annotate the three morph pairs with `matchedGeometryEffect`
      using stable ids:
  - `"assistant-builder.textfield"` — composer's multi-line text
    field shell ↔ `MessagesBottomBar`'s input shell
  - `"assistant-builder.primary-button"` — Make capsule ↔ Send
    arrow button
  - `"assistant-builder.media-buttons"` — composer's 4-button
    media row ↔ bottom bar's 5-button media row (side-convo fades
    in independently — see next step)
- [ ] Side-convo (orange Convos) button on `MessagesBottomBar`'s
      destination row gets an `.opacity(0 → 1)` fade tied to
      `hasCommitted`. No matched-geometry source.
- [ ] Drive the morph from a single `hasCommitted: Bool` flag on
      `AssistantBuilderViewModel`. On Make tap, set
      `hasCommitted = true` inside a staged `withAnimation` cascade:
  - **Phase A** (`withAnimation(.easeOut(duration: 0.18))`): fade
    out attachments row + text content (these have an
    `.opacity(hasCommitted ? 0 : 1)` modifier).
  - **Phase B** (chained after Phase A via `DispatchQueue.main`
    deadline or `withAnimation(...)` second invocation): fade the
    backdrop to clear, fade composer's interior chrome, run the
    matched-geometry morph, fade in the side-convo button.
  - **Phase C**: post-animation completion (use
    `.onAnimationCompleted` or a deadline), unmount the
    `ComposerOverlay` entirely.
- [ ] Fire `stateManager.send(text:)` + eager-attachment uploads at
      the **start of Phase A** so network work overlaps with the
      animation. The existing
      `ConversationStateMachine.sendMessage` queue handles the
      not-ready case — no new layer.
- [ ] Verify `ConversationIndicatorView` stays in place across the
      transition. Concretely: render it at a fixed position in the
      overlay's `VStack`, and after Phase C either (a) keep
      rendering it from the overlay slot with the composer removed
      below it, or (b) hand it off to the
      `ConversationView`'s toolbar via a second matched-geometry
      pair. (a) is simpler and avoids a second morph. Decide during
      implementation — see Open Questions.

### Phase 8: Polish + tests

- [ ] `AccessibilityIdentifier` coverage on new buttons / fields for
      QA harness
- [ ] Preview canvases for `AssistantDraftComposer` (empty,
      text-only, with attachments, preparing-assistant caption,
      voice-memo recording)
- [ ] Unit tests on `AssistantBuilderViewModel` for state-readiness
      derivation and the dismiss-cleanup paths
- [ ] Build + simulator smoke-test of the full flow

## Testing Strategy

- **Unit tests** (`ConvosTests/`):
  - `AssistantBuilderViewModelTests` — `isMakeEnabled` derivation
    given composer-text combinations, plus `requestAgentJoin` fires
    exactly once on first `.ready`
  - Dismiss-cleanup paths (leave-then-delete when assistant joined,
    direct delete otherwise)
- **Integration / QA**:
  - `qa/tests/structured/` — new structured test that drives the
    hammer button → composer → Make → verifies the first message
    appears in the resulting chat
  - Manual: voice memo recording inside the builder, attachment
    handling, save/discard menu interactions

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Liquid-glass morph behaves poorly across sheet boundaries | Medium | The builder is structured as a `ZStack` with `ConversationView` underneath and the composer overlay on top, both inside the same `@Namespace`. The matched-geometry source/destination live in the same render tree — no cross-boundary morph. The "sheet" is a single presentation that holds this whole `ZStack`. |
| Matched-geometry on three element pairs simultaneously is visually noisy | Low–Medium | Staged animation: attachments + text content fade out first (Phase A), only then do the three shell elements run their morph (Phase B). The user's eye tracks one transition at a time. |
| `ConversationView` mounted under the composer eagerly creates side effects (network reads, scrollback fetches) before the user has committed | Low | Mounting `ConversationView` against the just-created (post-`.ready`) conversation is the same work that would happen on a post-Make sheet dismissal anyway. Acceptable. If a measurable issue, gate `ConversationView`'s heavy side effects on a `isInteractive` prop. |
| `VoiceMemoRecorder` is too tightly coupled to `MessagesBottomBar`'s state | Medium | Phase 6 has an explicit audit step. If coupling is deep, factor out a shared recorder host into `Shared Views/`. |
| `requestAgentJoin` fails (network / agent unavailable) | High for builder usability — Make never enables | Surface the failure inside the builder with a retry affordance. Reuse the same retry-and-display-error machinery from `NewConversationViewModel` (`displayError`, `retryAction`). |
| Side-convo button hide in `MessagesMediaButtonsView` requires a wider refactor than expected | Low | If `isSideConvoDisabled` doesn't already permit hiding (it only disables today), add a new `showsSideConvoButton: Bool = true` parameter; default preserves existing call sites. |
| Conversation gets created but the user dismisses before assistant joins → empty stranger conversation appears in the list | Low | The dismiss-cleanup path covers this: if no text + no attachments, we silently leave (no assistant to leave at that moment, so just delete) → no leak. If user "Saves", the conversation is real and intentional. |

## Open Questions

- [ ] **Voice memo coupling**: how much of `VoiceMemoRecorder` /
      `VoiceMemoRecordingView` is `MessagesBottomBar`-specific? Phase
      6 starts with this audit.
- [ ] **Side-convo button hiding**: add `showsSideConvoButton: Bool`
      to `MessagesMediaButtonsView`, or just position the existing
      one with an alpha-zero / conditional render? Trivial to settle
      in code review.
- [ ] **Conversation creation timing**: kick off
      `prepareNewConversation()` + `createConversation()` on builder
      open (current plan), or wait for the first keystroke? Current
      plan is "on open" so the wait is overlapped with the user's
      thinking time. Trade-off: a user who opens and immediately
      dismisses with empty composer triggers a silent
      delete-and-leave. Acceptable per dismissal-cleanup plan.
- [ ] **`requestAgentJoin` timing**: fire on state-machine
      `.ready`, or speculatively on builder open (parallel to
      conversation creation)? `.ready` is safer because we need the
      conversation's invite slug, which only exists once the
      conversation has been published.
- [ ] **Conversation indicator handoff after Phase C**: after the
      composer overlay is torn down, does the
      `ConversationIndicatorView` (a) stay rendered from the same
      overlay slot (now floating above the chat), or (b) hand off
      to `ConversationView`'s toolbar via a second matched-geometry
      pair? (a) is one fewer animation but means the builder's
      overlay shell stays in the view tree (with no composer
      contents) — basically harmless but slightly ugly
      architecturally. (b) is cleaner architecturally but adds a
      second morph. Settle in implementation.

### Resolved

- ~~**Save semantics**~~ — replaced. The non-destructive dismiss
  option is now **Continue**, which is a pure no-op (close the menu,
  stay on the builder). No "save" concept needed.
- ~~**Make enable gating**~~ — the Make button enables on text non-
  empty alone. Readiness doesn't factor in; the destination
  `ConversationView` handles the "Assistant is joining…" state if
  the assistant hasn't joined by morph time.
- ~~**Queue-on-not-ready**~~ — the existing
  `ConversationStateMachine.sendMessage` stream already queues
  against `.ready`. No new layer.
- ~~**Make button send path**~~ — uses the existing
  `OutgoingMessageWriter.send(text:)` flow with the existing eager-
  attachment uploads. No batched-first-message special case.

## References

- Mockups: `/Users/jarod/Library/Application Support/CleanShot/media/media_v9umDM8a2G/CleanShot 2026-05-11 at 17.20.00@2x.png`
  (assistant-builder empty state), `media_HEaMK9Y6vo/CleanShot
  2026-05-11 at 17.23.42@2x.png` (assistant-builder with attachments)
- Related PRDs: `docs/plans/agent-join-endpoint.md`,
  `docs/plans/assistant-attestation.md`
- Inspiration: `Convos/Conversation Creation/NewConversationView.swift`
  + `NewConversationViewModel.swift` (the placeholder-VM ↔ real-VM
  swap pattern we'll mirror for composer ↔ chat)
