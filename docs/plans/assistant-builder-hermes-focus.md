# Assistant Builder: focus-mode streaming from the local assistants backend

Wire the convos-assistants runtime (Hermes) into the Honk-style focus mode so
that, during the build-template phase, the assistant streams its replies into a
live bubble (`StreamingText` snapshots) instead of narrating progress through
the `thinking` content type. The iOS side already speaks the protocol (branch
`jarod/assistant-builder-prototypes`, resurrected on top of dev); this plan
covers the backend half.

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

**Session tracking.** New `FocusSessionState` on the channel
(`runtime/hermes/src/convos/channel.py`): `{sessionId, focusedInboxId, state}`
updated from the new webhook events, with the same upsert rule as iOS's
`FocusSessionWriter` (stale `start(null)` never overwrites a known focus).
"We are focused" == `focusedInboxId == our inboxId` and `state == started`.

**Gating.** Focus streaming replaces thinking **only when** (a) a focus session
is live, (b) we are the focused member, and (c) the conversation is still in
the build-template phase — i.e. the agent-builder kickoff was injected and the
post-activation arc has not fired (`_post_activation_arc_armed` /
`_first_impression_arc_fired` in channel.py). Outside that window, behavior is
unchanged (thinking badge + regular text sends).

**Reply path.** Add a `FocusStreamWriter` to the herald client wrapper
(`runtime/hermes/src/convos/herald/client.py`) with
`stream(text_snapshot)`, `clear()`, `stop()`. In the channel's reply flow,
when gated in:

1. Suppress the thinking badge — claim the badge arbiter with a `focus` owner
   that swallows ambient phrases (the affordance is now the live bubble, the
   badge would double-signal).
2. Stream the reply. v1 cadence: chunk the composed reply on
   word/clause boundaries and emit cumulative snapshots every ~100–200 ms
   (herald coalesces; iOS renders keystroke-style). This works with today's
   buffered-completion agent loop — no LLM plumbing change. v2 (optional):
   where the runtime has incremental token callbacks, push raw cumulative
   text and let herald's coalescer set the pace.
3. End-of-thought: `clear()` after a hold (~3.5 s, matching the prototype's
   transcript pacing), then either stream the next bubble or wait.
4. Wait-for-rest: before replying to live typing, wait until the user's
   bubble has had no new `streaming_text` revision for ~2 s, or they sent a
   regular message (the prototype treats committed messages as definitive).
5. Phase exit: when the template pins (`templateId` metadata patch) and the
   post-activation arc fires, send `focus_mode_control(stop)` (or let iOS own
   the stop — see open questions), fall back to normal messaging, and send the
   first-impression message as a regular persisted text message.

**Persistence note:** streamed bubbles are ephemeral by design (iOS never
stores them as chat rows). Anything that must survive — the final template
summary, the "what I built" message — goes out as a normal text send after the
clear.

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
   agent-builder flow, verify: live bubble paints during the interview, no
   thinking badge while focused, bubble clears ~600 ms after the agent's
   clear, transcript shows only the committed messages afterward.

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
