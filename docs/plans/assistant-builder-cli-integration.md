# Assistant Builder — CLI Integration Spec

**Audience:** the engineer (or agent) implementing CLI support for the new
Assistant Builder / Focus Mode feature in `convos-cli`.
**Source of truth for the iOS side:** `docs/plans/assistant-builder-honk-mode.md`
in this repo.
**Last updated:** 2026-05-04
**iOS branch:** `jarod/assistant-builder`

This doc is self-contained — read it once and you'll have everything needed
to implement the matching CLI behavior. Three new XMTP custom content types,
a small state machine, and one new long-running command. Don't change
existing commands; add a new one.

## 1. What the feature is

The iOS app has a new "Build assistant" flow opened via the `hammer.fill`
toolbar button on the conversations list. Tapping it:

1. Auto-creates a new XMTP group (one member: the human user).
2. Generates an invite slug.
3. Shows a "CLI Bootstrap Sheet" with a "Copy invite code" button.
4. Sends `FocusModeControl(state: .start, focusedInboxId: nil, sessionId: <UUID>)`
   immediately — opening a *pending* focus session.
5. Watches the conversation member list. As soon as a non-self member joins,
   it sends a follow-up `FocusModeControl(.start, focusedInboxId: <new member>, sessionId: <same>)`
   to "promote" the focus to that member.

After promotion both sides enter **Focus Mode**:

- The user types directly into a giant message bubble. Every keystroke ships
  a `StreamingText` with the **full snapshot** of the current text (not a
  delta) and a monotonically increasing `revision` per (session, sender).
- Pressing return ships a `StreamingClear` and the receiver clears their
  view of the bubble after a 600ms readability delay.
- The agent (you, in `convos-cli`) is expected to do the same in the
  opposite direction: stream live text into your own bubble that the user
  can read in real time.

When the agent decides it has gathered enough information, it sends
`FocusModeControl(.stop, sessionId: <same>)`. The iOS side then shows a
"Start chatting" CTA that transitions into the standard ConversationView.

The whole point: it's a real-time co-typing interview, not a turn-based
chat. Latency and snappy clears matter.

## 2. The three new content types

All three live under authority `convos.org`, version `1.0`. All three are
JSON-encoded, **silent** (`shouldPush: false`), and have **no fallback
text** (`fallback: undefined`). They are **not** stored in conversation
history on iOS — receivers route them through a side channel into a
separate state store and never persist them as messages.

The CLI **must** register all three codecs on the `Client` so messages
decode through them, but does **not** need to persist or expose them to
its normal message-history commands. Treat them like `TypingIndicator`.

### 2.1 FocusModeControl

**Content type id:** `convos.org/focus_mode_control:1.0`

**Payload (JSON):**

```ts
interface FocusModeControl {
  state: "start" | "stop";
  focusedInboxId: string | null; // see "Pending focus" rules below
  sessionId: string;             // groups the .start/.stop pair (UUID v4)
}
```

**Semantics:**

| state  | focusedInboxId | meaning |
|--------|---------------|---------|
| `start` | `null`        | session is open but no member is focused yet (user fired this before agent joined) |
| `start` | `<inboxId>`   | session is open and focused on that member; if a row already exists for the sessionId, this **promotes** the focus |
| `stop`  | (ignored)     | session is over; receiver enters end-of-session state |

**Apply rules** (mirror these on the CLI receiving side if you keep your
own session state — even just for logging):

- `start` is an upsert by `sessionId`. If a row exists, **only overwrite
  `focusedInboxId` with non-null values** — a stale `start(null)` arriving
  late must not blow away a known focus.
- `stop` flips state to ended; live bubble snapshots stay in place so the
  receiver can render the final phrase before transitioning.

**When the CLI agent should send these:**

- The **iOS side fires the initial `start`**. You don't send the first
  `start`. You only send a `stop` when you decide the interview is done.

### 2.2 StreamingText

**Content type id:** `convos.org/streaming_text:1.0`

**Payload (JSON):**

```ts
interface StreamingText {
  sessionId: string;       // matches an active FocusModeControl session
  senderInboxId: string;   // your inbox id
  revision: number;        // uint32, monotonic per (sessionId, senderInboxId)
  text: string;            // FULL SNAPSHOT of your current bubble text
}
```

**Snapshot, not delta.** Each message carries the entire current bubble
content. Don't try to ship deltas — XMTP doesn't guarantee message ordering,
and the receiver compares revisions to drop stale arrivals. A dropped
message is harmless: the next keystroke catches the receiver up.

**Revision rules:**

- Maintain a counter per (sessionId, senderInboxId) on your side.
- Increment by 1 for every snapshot you send (and every clear — they share
  the counter).
- The iOS receiver's writer drops any `StreamingText` whose `revision <=
  existing.revision` for that (sessionId, senderInboxId).

### 2.3 StreamingClear

**Content type id:** `convos.org/streaming_clear:1.0`

**Payload (JSON):**

```ts
interface StreamingClear {
  sessionId: string;
  senderInboxId: string;
  revision: number;        // strictly greater than the last StreamingText
}
```

**Semantics:** "I'm done with this thought, blank my bubble." Receivers
delay the visual clear by **600ms** so the final phrase stays readable.
You don't need to add the delay yourself — iOS handles it on its side.
But if you display the user's incoming bubble in the CLI, apply the same
600ms delay so the UX matches.

**Revision shares the same counter as `StreamingText`.** If your last
StreamingText was revision 5, your StreamingClear is revision 6.

## 3. CLI codec implementation (TypeScript)

These mirror the existing `src/utils/typingIndicator.ts` exactly. Three new
files in `src/utils/`:

### `src/utils/focusModeControl.ts`

```ts
import type { ContentTypeId, EncodedContent } from "@xmtp/node-bindings";
import type { ContentCodec } from "@xmtp/content-type-primitives";
import type { DecodedMessage } from "@xmtp/node-sdk";

export const ContentTypeFocusModeControl: ContentTypeId = {
  authorityId: "convos.org",
  typeId: "focus_mode_control",
  versionMajor: 1,
  versionMinor: 0,
};

export type FocusModeState = "start" | "stop";

export interface FocusModeControl {
  state: FocusModeState;
  focusedInboxId: string | null;
  sessionId: string;
}

export class FocusModeControlCodec implements ContentCodec<FocusModeControl> {
  get contentType(): ContentTypeId {
    return ContentTypeFocusModeControl;
  }

  encode(content: FocusModeControl): EncodedContent {
    const json = JSON.stringify(content);
    return {
      type: ContentTypeFocusModeControl,
      parameters: {},
      content: new TextEncoder().encode(json),
    } as EncodedContent;
  }

  decode(content: EncodedContent): FocusModeControl {
    const json = new TextDecoder().decode(content.content);
    const parsed = JSON.parse(json) as FocusModeControl;
    if (parsed.state !== "start" && parsed.state !== "stop") {
      throw new Error("Invalid FocusModeControl.state");
    }
    if (typeof parsed.sessionId !== "string" || parsed.sessionId.length === 0) {
      throw new Error("Missing FocusModeControl.sessionId");
    }
    if (parsed.focusedInboxId !== null && typeof parsed.focusedInboxId !== "string") {
      throw new Error("Invalid FocusModeControl.focusedInboxId");
    }
    return parsed;
  }

  fallback(_content: FocusModeControl): string | undefined {
    return undefined;
  }

  shouldPush(_content: FocusModeControl): boolean {
    return false;
  }
}

export function isFocusModeControlMessage(message: DecodedMessage): boolean {
  const ct = message.contentType;
  return ct.authorityId === ContentTypeFocusModeControl.authorityId
    && ct.typeId === ContentTypeFocusModeControl.typeId;
}
```

### `src/utils/streamingText.ts`

```ts
import type { ContentTypeId, EncodedContent } from "@xmtp/node-bindings";
import type { ContentCodec } from "@xmtp/content-type-primitives";
import type { DecodedMessage } from "@xmtp/node-sdk";

export const ContentTypeStreamingText: ContentTypeId = {
  authorityId: "convos.org",
  typeId: "streaming_text",
  versionMajor: 1,
  versionMinor: 0,
};

export interface StreamingText {
  sessionId: string;
  senderInboxId: string;
  revision: number;   // uint32
  text: string;
}

export class StreamingTextCodec implements ContentCodec<StreamingText> {
  get contentType(): ContentTypeId { return ContentTypeStreamingText; }

  encode(content: StreamingText): EncodedContent {
    return {
      type: ContentTypeStreamingText,
      parameters: {},
      content: new TextEncoder().encode(JSON.stringify(content)),
    } as EncodedContent;
  }

  decode(content: EncodedContent): StreamingText {
    const parsed = JSON.parse(new TextDecoder().decode(content.content)) as StreamingText;
    if (typeof parsed.sessionId !== "string"
        || typeof parsed.senderInboxId !== "string"
        || typeof parsed.revision !== "number"
        || typeof parsed.text !== "string") {
      throw new Error("Invalid StreamingText payload");
    }
    return parsed;
  }

  fallback(): string | undefined { return undefined; }
  shouldPush(): boolean { return false; }
}

export function isStreamingTextMessage(message: DecodedMessage): boolean {
  const ct = message.contentType;
  return ct.authorityId === ContentTypeStreamingText.authorityId
    && ct.typeId === ContentTypeStreamingText.typeId;
}
```

### `src/utils/streamingClear.ts`

Same shape as `streamingText.ts`. Type id: `streaming_clear`. Payload:
`{ sessionId, senderInboxId, revision }` (no `text`).

### Re-exports

Add the new codecs and helpers to `src/index.ts` next to the existing
`TypingIndicatorCodec` re-export so consumers can register and detect them.

### Registration

Wherever you build a `Client` for the CLI (search for
`TypingIndicatorCodec` in `getIdentityAndClient` / wherever client
instantiation lives), pass the three new codecs in the `codecs` array.

## 4. New command: `convos agent focus`

Don't bolt this onto `agent serve`. The interaction model is different
enough — it's not a chat, it's a co-typing session — that a dedicated
command is cleaner and easier to reason about.

### 4.1 Usage

```
convos agent focus <invite-code>
  --identity <name>     # which CLI identity to use
  --auto-stop-after <n> # optional: send FocusModeControl(.stop) after N seconds idle
  --persona <file>      # optional: text file describing how the agent should behave
```

### 4.2 Lifecycle

1. **Resolve identity & client.** Same as `agent serve`. Make sure the
   three new codecs are registered.

2. **Join the conversation.** Use the existing `conversations join`
   helper / `joinByInvite` flow with the supplied invite code.

3. **Stream messages from the conversation.** Filter for the three new
   content types using the `is*` helpers. Track per-(sessionId,
   senderInboxId) state in memory:

   ```ts
   interface RemoteBubble { text: string; lastRevision: number; }
   interface SessionState {
     sessionId: string;
     focusedInboxId: string | null;
     state: "started" | "stopped";
     bubbles: Map<string, RemoteBubble>; // key: senderInboxId
     localRevision: number;              // OUR counter for outgoing
   }
   ```

4. **Wait for the iOS-initiated `FocusModeControl(.start)`.** It will
   arrive as soon as the iOS side notices you joined. The first one
   typically has `focusedInboxId: null`; a follow-up `start` will arrive
   moments later promoting focus to your inbox id.

5. **Once `focusedInboxId === yourInboxId`, you are the focused member.**
   The user is now waiting for you to type into your bubble.

6. **Stream your text.** As you compose your response (whether driven by
   stdin, an LLM, a fixed script, etc.), call:

   ```ts
   async function publishStreamingText(
     conversation: Group,
     state: SessionState,
     ourInboxId: string,
     text: string,
   ) {
     state.localRevision += 1;
     await conversation.send(
       {
         sessionId: state.sessionId,
         senderInboxId: ourInboxId,
         revision: state.localRevision,
         text,
       } satisfies StreamingText,
       ContentTypeStreamingText,
     );
   }
   ```

   **Cadence:** debounce at ~50ms client-side. If you're driving from an
   LLM token stream, batch up to a few tokens per send (target 5–20
   sends/sec). Don't ship one message per character of LLM output — the
   iOS receiver renders snapshots fine, but the wire cost is unnecessary.

7. **End your turn.** When you're done with a thought, send a
   `StreamingClear` with the next revision and reset your local text
   buffer:

   ```ts
   async function publishStreamingClear(
     conversation: Group,
     state: SessionState,
     ourInboxId: string,
   ) {
     state.localRevision += 1;
     await conversation.send(
       {
         sessionId: state.sessionId,
         senderInboxId: ourInboxId,
         revision: state.localRevision,
       } satisfies StreamingClear,
       ContentTypeStreamingClear,
     );
   }
   ```

8. **Render the user's incoming text.** Show their `RemoteBubble.text`
   inline in the terminal, updating in place as new `StreamingText`
   arrives. When their `StreamingClear` lands, wait 600ms before clearing
   the line so you can read the final phrase.

9. **End the session.** When you decide the interview is done (manual
   keystroke, command flag, LLM signal — your choice):

   ```ts
   await conversation.send(
     {
       state: "stop",
       focusedInboxId: null,
       sessionId: state.sessionId,
     } satisfies FocusModeControl,
     ContentTypeFocusModeControl,
   );
   ```

   The iOS side will swap to the "Start chatting" CTA, and the user can
   then transition into a normal chat with you (which lands in the
   existing message stream — `agent serve` will pick it up).

### 4.3 Suggested terminal UX

```
┌─ convos agent focus ──────────────────────────────────────────┐
│ Joined conversation 0xabc... as agent-jane                    │
│ Waiting for focus… (got pending session 8d2c…)                │
│ → focused. Stream your text below; ⏎ to clear & end turn.     │
│                                                               │
│ user: I want an assistant that reminds me to call mom         │
│                                                               │
│ you:  > Sounds great. How often should I remind you?_         │
└───────────────────────────────────────────────────────────────┘
```

Use ANSI escape codes (`\x1b[2K\r`) or a TUI library to update the lines
in place rather than appending. The defining UX is that *the line
itself* changes, not a new line per snapshot.

## 5. Edge cases & gotchas

**Out-of-order arrivals.** XMTP doesn't guarantee message ordering.
Always trust your `revision` comparison, never timestamps.

**Late `StreamingText` after `StreamingClear`.** Possible if a snapshot
was in flight when you hit return. Receiver drops it via revision check.
You don't need to defend against sending one — your own counter prevents
that locally.

**Late `StreamingText` after `FocusModeControl(.stop)`.** Drop it. The
iOS writer drops these unconditionally. Your CLI should too.

**Catch-up on reconnect.** If you lose connectivity and reconnect, you
may receive past `StreamingText` snapshots. Ignore any with `revision <=
your last seen`. Treat any session you haven't heard from in 60s as
orphaned and don't try to resume.

**Length cap.** Plan-recommended cap: 500 chars in the composer, reject
incoming `StreamingText` over 1KB. The iOS side hasn't enforced this yet
but will.

**Empty `text` in `StreamingText`.** Treated as "user backspaced to
nothing." Render as an empty bubble, not as a clear. The clear is its
own message type.

**`FocusModeControl(.start)` with `focusedInboxId !== yourInboxId`.**
Means the iOS user wants someone else to be the focused member. You're
present in the conversation but not the focus. Don't send any
`StreamingText` from your inbox in this case — only the focused member
streams. (For the prototype this won't happen because the iOS auto-
promotion always picks the first non-self member, which is you.)

**Multiple `start` messages with the same sessionId.** This is the
promotion mechanism, not an error. Keep applying — last non-null
`focusedInboxId` wins.

## 6. Quick reference: wire format examples

```jsonc
// 1. iOS opens a pending session right after creating the group
{
  "state": "start",
  "focusedInboxId": null,
  "sessionId": "8d2c5a1e-f4a7-4b8e-9c0d-7a3b2e1f4d5c"
}

// 2. iOS notices you joined and promotes focus
{
  "state": "start",
  "focusedInboxId": "0xagentinbox...",
  "sessionId": "8d2c5a1e-f4a7-4b8e-9c0d-7a3b2e1f4d5c"
}

// 3. You start typing
{
  "sessionId": "8d2c5a1e-...",
  "senderInboxId": "0xagentinbox...",
  "revision": 1,
  "text": "Tell me wha"
}
{
  "sessionId": "8d2c5a1e-...",
  "senderInboxId": "0xagentinbox...",
  "revision": 2,
  "text": "Tell me what you"
}
{
  "sessionId": "8d2c5a1e-...",
  "senderInboxId": "0xagentinbox...",
  "revision": 3,
  "text": "Tell me what you want this assistant to do."
}

// 4. You hit enter
{
  "sessionId": "8d2c5a1e-...",
  "senderInboxId": "0xagentinbox...",
  "revision": 4
}

// 5. … back-and-forth …

// 6. You decide the interview is done
{
  "state": "stop",
  "focusedInboxId": null,
  "sessionId": "8d2c5a1e-..."
}
```

## 7. iOS implementation references (for cross-checking)

If you want to verify a behavior matches iOS exactly, the source of
truth is in this repo:

- Codecs: `ConvosCore/Sources/ConvosCore/Custom Content Types/{FocusModeControl,StreamingText,StreamingClear}Codec.swift`
- Writer (apply rules + 600ms clear delay): `ConvosCore/Sources/ConvosCore/Storage/Writers/FocusSessionWriter.swift`
- Stream dispatch (where incoming messages route to the writer): `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift` — see `processFocusModeMessage`
- Sender publisher (debounce + revision): `Convos/Assistant Builder/FocusSessionPublisher.swift`
- View-model orchestration (auto-promotion, draft binding, end transition): `Convos/Assistant Builder/AssistantBuilderViewModel.swift`
- Tests (apply-rule edge cases, race between clear and newer text): `ConvosCore/Tests/ConvosCoreTests/FocusSessionWriterTests.swift`

## 8. Out of scope for this round

- Attachment streaming. The iOS prototype doesn't allow attachments in
  focus mode; don't accept them on the CLI either.
- Multi-focused-member sessions. One focused member at a time.
- Voice / call modes from Honk.
- Push notifications — all three codecs are explicitly silent.

## 9. Acceptance test (manual)

You can validate the integration end-to-end with one human:

1. iOS user taps `hammer.fill`, copies the invite code from the bootstrap
   sheet.
2. Run `convos agent focus <invite-code>` in another terminal.
3. CLI shows "Waiting for focus" then "→ focused".
4. User types in the iOS bubble; CLI shows the text updating in place.
5. User hits return; CLI bubble line clears after ~600ms.
6. CLI agent types something; iOS bubble updates in place.
7. CLI agent hits return; iOS bubble clears after ~600ms.
8. CLI agent fires the stop command (Ctrl-D, `/end`, whatever you wire);
   iOS shows the "Start chatting" CTA.

If all of those work, you're done.
