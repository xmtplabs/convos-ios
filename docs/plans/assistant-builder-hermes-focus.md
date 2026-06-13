# Assistant Builder: focus-mode streaming from the local assistants backend

Wire the convos-assistants runtime (Hermes) into the Honk-style focus mode so
that, during the build-template phase, the agent conducts the interview as a
live, co-typing conversation. The iOS side already speaks the protocol (branch
`jarod/assistant-builder-prototypes`, resurrected on top of dev); this plan
covers the backend half.

**This is not a transport swap.** The naive version -- take whatever the agent
would have said and re-route it from the `thinking` badge into `StreamingText`
snapshots -- is wrong. It leaves the agent oblivious: same multi-paragraph
chatbot output, just painted into a live bubble. Focus mode is a *medium* with
its own conversational grammar (short single-thought bubbles, one question at a
time, you can watch the other person type, nothing is permanent until it's
committed). The agent has to **know it is in focus mode** and **change how it
communicates** because of it. So the runtime work is three things, not one:

1. **Awareness** -- surface the focus session and the peer's live typing into
   the agent's context, so it reasons over "they're typing: '...'" not just a
   finished message.
2. **A focus-mode communication policy** -- prompt/skill guidance that tells the
   agent how to behave in this medium.
3. **Deliberate outbound actions** -- the agent decides when to speak, clear,
   wait, and end the session, rather than a wrapper transcoding its prose.

The transport substrate (codecs in convos-cli, herald endpoints with
server-side revision allocation + coalescing, inbound webhook events) is still
exactly as in Phases 1-2 below -- that's just how the bytes move. The rethink
is entirely in Phase 3.

## Where the seams are

The assistants stack is layered, and each layer touches the protocol once:

```
hermes runtime (python, per-conversation container)
    | HTTP (generated herald_client)         ^ webhooks (signed POSTs)
    v                                        |
herald-lite (Hono/TS, owns the XMTP client; codecs imported from @xmtp/convos-cli)
    | XMTP node-sdk
    v
XMTP network  <->  iOS (FocusModeControlCodec / StreamingTextCodec / StreamingClearCodec)
```

- Codecs live once in **convos-cli** (`src/utils/*`) and are imported by
  herald-lite (`herald-lite/src/utils/xmtp.ts:174` `createConvosCodecs()`),
  exactly how `ThinkingCodec` ships today.
- **herald-lite** exposes send endpoints (`POST /v1/conversation/{id}/messages/…`,
  Hono + zod-openapi) and forwards inbound decoded messages to the runtime as
  webhook events (`src/agent-streamer/router.ts`, `src/webhooks/index.ts`).
- **hermes** decides *what* to send and *when*. The thinking badge today is
  driven by `runtime/hermes/src/convos/progress/badge.py` (per-anchor
  latest-wins coalescing) and the build-template phase by
  `runtime/hermes/src/convos/channel.py` (agent-builder kickoff, side-channel
  `.convos-progress.ndjson`, post-activation arc).

## Wire protocol (already fixed by the iOS prototype)

All JSON codecs, authority `convos.org`, silent (`shouldPush=false`, no
fallback). Source of truth: `ConvosCore/Sources/ConvosCore/Custom Content Types/`
and `docs/plans/assistant-builder-cli-integration.md` on the prototype branch.

| Type id | Payload | Semantics |
| --- | --- | --- |
| `focus_mode_control` | `{state: "start"\|"stop", focusedInboxId: string\|null, sessionId: uuid}` | iOS opens a pending session (`focusedInboxId: null`), then re-sends `start` to promote the agent once it joins. Stale `start(null)` must never demote a known focus. |
| `streaming_text` | `{sessionId, senderInboxId, revision: uint32, text}` | Full-text snapshot of the sender's bubble, not a delta. Receiver drops `revision <=` last seen per `(sessionId, senderInboxId)`. |
| `streaming_clear` | `{sessionId, senderInboxId, revision}` | End-of-thought. Shares the revision counter with `streaming_text`. iOS applies a 600 ms visual delay and drops the clear if a newer snapshot lands meanwhile. |
| `conversation_snapshot` | `{focusSession: {sessionId, state, focusedInboxId} \| null}` | Late-joiner catch-up, sent by the conversation creator after admitting a member. Receivers treat the embedded session as a virtual start/stop. |

Ordering rule everywhere: trust revisions, never timestamps. After
`stop`, drop all further streaming messages for that session.

## Phase 1 — codecs in convos-cli

New files mirroring `src/utils/typingIndicator.ts` / `thinking.ts`:

- `src/utils/focusModeControl.ts`, `src/utils/streamingText.ts`,
  `src/utils/streamingClear.ts`, `src/utils/conversationSnapshot.ts` — each a
  `ContentCodec<T>` + `is*Message()` helper + exported types.
- Register all four in the `codecs` array in `src/utils/client.ts:138-154`.
- This also unblocks the planned `convos agent focus` command
  (spec: `docs/plans/assistant-builder-cli-integration.md`), which doubles as
  the test harness peer for everything below.

## Phase 2 — herald-lite endpoints + events

**Codec registration:** add the four codecs to `createConvosCodecs()`
(`src/utils/xmtp.ts`) and the `XmtpContentTypes` union.

**Send endpoints** (pattern: `src/api/conversation/messages/thinking.ts`):

- `POST /v1/conversation/{id}/messages/focus-mode-control`
  `{state, focused_inbox_id?, session_id}` — used by the runtime to stop a
  session it owns (and to re-broadcast `start` for resilience if we want
  agent-initiated sessions later).
- `POST /v1/conversation/{id}/messages/streaming-text`
  `{session_id, text}` — **revision is allocated server-side**. Herald owns the
  XMTP identity, so it keeps the monotonic counter per
  `(conversationId, sessionId)` in memory and stamps `senderInboxId` itself.
  The runtime never sees revisions, which removes a whole class of
  out-of-order bugs across runtime restarts.
- `POST /v1/conversation/{id}/messages/streaming-clear`
  `{session_id}` — increments the same counter.

**Coalescing:** herald has no send throttling today (fine for thinking's
start/stop cadence, not for per-token snapshots). Give the streaming-text
handler a per-session latest-wins coalescer — accept every request
immediately, keep only the newest pending snapshot, and drain at a floor of
~80 ms between XMTP sends (12/s, inside the 5–20/s budget from the CLI spec).
Same shape as hermes' `_drain_progress` loop, just one layer down.

**Inbound events** (pattern: thinking in `src/agent-streamer/router.ts:154` +
`src/webhooks/index.ts:136`): decode and forward as new webhook payloads in the
`AgentServeEventPayloadSchema` union —

- `focus_mode_control` `{event, id, senderInboxId, conversationId, state, focusedInboxId, sessionId, sentAt}`
- `streaming_text` `{…, sessionId, revision, text}` — needed so the agent can
  watch the user's live bubble and detect "rest" (no new revision for ~2 s).
- `streaming_clear` `{…, sessionId, revision}`
- `conversation_snapshot` with the embedded focus session.

**Spec/client regen:** `scripts/dump-openapi.ts`, then regenerate the python
`herald_client` package consumed by hermes (`runtime/hermes/src/herald_client/`).

## Phase 3 — hermes runtime behavior

The goal: when focused in the build-template phase, the agent *runs the
interview as a live conversation it understands it's having*. Four pieces.

### 3a. Session state + the upsert rule

New `FocusSessionState` on the channel
(`runtime/hermes/src/convos/channel.py`): `{sessionId, focusedInboxId, state,
peerLiveText, peerLastRevision, peerLastChangeAt}`, updated from the new webhook
events (Phase 2), with the same upsert rule as iOS's `FocusSessionWriter`
(stale `start(null)` never overwrites a known focus). "We are focused" ==
`focusedInboxId == our inboxId` and `state == started`. The peer fields track
the *other* member's live bubble as their `streaming_text` revisions arrive --
this is what makes awareness possible.

### 3b. Gating

Focus behavior engages **only when** (a) a session is live, (b) we are the
focused member, and (c) the conversation is still in the build-template phase
(agent-builder kickoff injected, post-activation arc not yet fired --
`_post_activation_arc_armed` / `_first_impression_arc_fired`). Outside that
window nothing changes: normal thinking badge + committed text sends. Focus is
a phase, not a global mode.

### 3c. Awareness — focus mode enters the agent's context

This is the half the naive plan skipped. When gated in, the runtime augments
the agent's context for that turn:

- **A focus-mode system/skill addendum** (a prompt block, active only while
  focused) telling the agent the medium and its grammar -- see 3d. This is the
  mechanism by which the agent "knows it's in focus mode."
- **The peer's live typing as a first-class observation.** Instead of only
  handing the agent a finished user message, the turn carries the forming
  bubble: e.g. system note "The person is typing live; their bubble currently
  reads: '<peerLiveText>' (still going)" vs. "...they paused after: '<text>'".
  The agent can reason over an in-progress thought -- acknowledge, wait, or
  start forming a reply before they finish.
- **Turn-taking on rest, not on every keystroke.** The runtime must *not* wake
  the LLM on each inbound `streaming_text` revision. Coalesce: treat a thought
  as "ready to answer" when the peer's bubble has had no new revision for ~2 s
  (`peerLastChangeAt`), or they committed a real message, or they cleared.
  Sub-rest revisions only update `peerLiveText` for context. (v2: let the agent
  opt into reacting mid-typing for richer behavior; v1 is rest-driven.)

### 3d. Communication policy — how the agent behaves in the medium

A focus-mode addendum to the agent-builder skill prompt, in effect only while
focused. Roughly: *You're in a live focus session -- the person sees you type
in real time, one bubble at a time, and you see them type back. Communicate
like a live chat, not an essay: short single-thought bubbles, one question at a
time, react to what they're typing. Bubbles are ephemeral -- they vanish when
you clear and aren't saved to the transcript, so don't dump anything important
here; save the summary for when you finish. Drive the build interview as a
back-and-forth: greet, ask what they want, watch them answer, follow up, and
when you have enough, wrap up and hand off.* The exact wording is for the
prompt-tuning pass; the point is the agent's *output shape and pacing* come
from it, not from a transcoder downstream.

### 3e. Deliberate outbound actions

Expose focus communication as explicit actions the agent invokes, not an
automatic wrapper around its prose. Add a thin `FocusChannel` over the herald
client (`runtime/hermes/src/convos/herald/client.py`):

- `say(text)` -- stream one bubble (herald handles snapshot pacing +
  revisions), hold briefly, then `clear()`. One call == one spoken bubble.
- `wait_for_rest()` -- block until 3c's rest signal (used between turns).
- `end_focus()` -- pin the template, send `focus_mode_control(stop)`, and fall
  back to normal messaging.

The agent loop, while focused, emits a sequence of `say()` turns interleaved
with `wait_for_rest()` rather than one `send_text`. How the agent chooses to
break its thoughts into bubbles is driven by 3d. The thinking badge is **not**
used while focused -- the live bubble is the presence indicator; a badge would
double-signal. (Internally the runtime can still "think"; it just doesn't emit
the badge content type.)

v1 cadence inside `say()`: chunk the bubble's text on word/clause boundaries and
emit cumulative snapshots every ~100-200 ms (herald coalesces; iOS renders
keystroke-style). Works with today's buffered-completion loop -- no token-stream
plumbing required. v2: where incremental token callbacks exist, push raw
cumulative text and let herald's coalescer set the pace.

### 3f. Phase exit and persistence

When the agent calls `end_focus()` (it has enough to build the template) or iOS
sends `focus_mode_control(stop)` (user left the builder), the agent reverts to
normal messaging mid-conversation. Streamed bubbles are ephemeral by design
(iOS never stores them as chat rows), so anything that must survive -- the
template summary, the "here's what I built" first-impression message -- goes out
as a **normal committed text send** after focus ends, exactly as today. Stop is
idempotent; either side may send it.

## Phase 4 — iOS follow-ups (small)

- The resurrected branch already registers the codecs, persists sessions
  (`FocusSessionWriter`), and renders `FocusModeView`. The prototype entry
  point is the hammer button → CLI-driven flow; wiring the *production*
  AgentBuilder conversation into focus mode needs iOS to open the session
  (send `focus_mode_control(start, null)` on entering the builder, promote the
  assistant's inbox once its `ProfileUpdate` lands) — mirror of
  `FocusSessionPublisher`'s existing promotion logic.
- Creator-side `conversation_snapshot` after admitting a member already ships
  in `InviteJoinRequestsManager` on the branch.

## Testing on the cloned stack

Use the isolated stack at `~/Code/xmtplabs/convos-stack-honk` (compose project
`convos-stack-honk`; backend :4100, herald :5150, worker :8887, Postgres :5532,
MinIO :9100/:9101 — see its `stack.env`). It shares nothing with the default
`convos-stack` workspace, so focus-mode hacking can't break other checkouts.

1. Unit: codec round-trips in convos-cli; herald endpoint schema tests; a
   coalescer test (N rapid snapshots → ≤ rate-floor sends, last text wins).
2. Protocol: `convos agent focus` (CLI spec) against herald-lite — handshake,
   monotonic revisions, clear-shares-counter, stop semantics.
3. End-to-end: iOS sim on the Local scheme pointed at the honk stack
   (`make -C dev/local-stack ios-config IOS=<this worktree>`), run the
   agent-builder flow, verify both the *mechanics* and the *behavior*:
   - Mechanics: live bubble paints during the interview, no thinking badge
     while focused, bubble clears ~600 ms after the agent's clear, transcript
     shows only the committed messages afterward.
   - Behavior: the agent communicates in short single-thought bubbles (not
     dumped paragraphs), asks one thing at a time, waits for the user to stop
     typing before replying, and reacts to what the user is typing -- i.e. it
     reads as a live conversation, not a chatbot painted into a bubble. This is
     the acceptance bar the rethink exists for; eyeball it against the
     prototype's `--focus` test transcript in `docs/plans/assistant-builder-cli-integration.md`.

## Open questions / risks

- **Who owns session stop** — iOS (user leaves the builder) vs the agent
  (template pinned)? Proposal: both may stop; receivers treat stop as
  idempotent. The 60 s orphan rule from the prototype covers crashes.
- **Herald hang risk:** thinking sends already burned hermes once (23 s Herald
  hang); keep the runtime's 5 s emit timeout on the new calls, and the
  server-side coalescer keeps XMTP back-pressure off the request path.
- **Catch-up noise:** focus messages must stay out of herald's catch-up
  delivery to the runtime (live-only, mirroring iOS's `CaughtUpMessageKind`
  ignore) — otherwise a reconnect replays stale bubbles.
- **Old clients:** unknown content types are silently dropped by clients
  without the codecs, and `shouldPush=false` keeps notifications quiet, so the
  rollout is backward-compatible by construction.
- **LLM wakeups vs. live typing (3c):** the inbound `streaming_text` stream is
  high-frequency; waking the agent loop per revision would be both expensive
  and behaviorally wrong (it'd reply mid-thought). Rest-coalescing is load-
  bearing, not an optimization. Get the rest window right (~2 s feels live
  without interrupting) and make sub-rest revisions context-only.
- **Prompt-tuning is real work (3d):** "the agent communicates well in focus
  mode" is a prompt/eval task, not just plumbing. Budget a tuning pass with the
  evals harness; the communication policy wording will need iteration against
  real transcripts. The mechanical pieces (3a/3b/3e) can land first and be
  exercised via the CLI peer while 3d is tuned.
- **Does the agent over-narrate?** Today it leans on the thinking badge to show
  progress. With the badge gone in focus, make sure the policy doesn't push it
  to narrate its process into bubbles ("Let me think about that...") -- the
  bubble should carry the actual reply, not status. Worth an explicit prompt
  rule and an eval check.
