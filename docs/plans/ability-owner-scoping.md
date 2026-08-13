# Ability Owner Scoping, Default-Enable, and Request Visibility

> **Status:** Decided design. Owner scoping (Q1) is implemented; the
> default-enable and request-visibility work is scoped as described below.
> **Scope:** convos-ios (client) and the assistants worker/backend (cross-repo)

## Overview

An "ability" is a per-conversation grant that lets an agent invoke a
third-party integration (Composio-backed services like Google Calendar,
Strava, etc.) on a member's behalf. A member connects a service once, then
grants it to a specific agent in a specific conversation; the agent's runtime
checks that grant before executing a tool call against the underlying
service.

The initial request/approve/grant flow shipped first. This doc addresses
three follow-on product questions that came up once it was in use:

1. **Owner scoping.** Once an ability is granted, should only the member who
   granted it be able to trigger it through the agent, or is any conversation
   member sufficient?
2. **Default-enable.** Should abilities a member has already connected
   auto-enable in new conversations, instead of requiring the manual
   per-conversation toggle every time?
3. **Request visibility.** When an agent asks for something nobody has
   connected yet, who should be able to see and act on that "Connect this
   ability" prompt?

Each is addressed independently below; they compose without conflicting, and
none of the choices creates schema or wire surface that a more complete
request/grant/execution model would later need to migrate away from (see
Removability).

## Q1: Restrict ability use to the owner

### Problem

A grant today is membership-sufficient: once one member connects a service
and grants it to the agent in a conversation, every member of that
conversation can drive it through the agent. In a group conversation, any
member can ask the agent to read or write to a service that only one member
actually connected.

### Trust chain

Fixing this requires knowing, for a given tool call, who actually sent the
message that triggered it - and knowing it in a way the agent's own
execution environment cannot spoof:

- Message delivery is attested at the transport layer: the sending member's
  identity comes off the messaging protocol's own message attribution, which
  a group member cannot forge on another member's behalf.
- The path from the messaging layer into the worker/runtime that executes
  tool calls is authenticated end-to-end (signed webhook delivery).
- The one untrustworthy hop is the agent's own execution container: it runs
  model-authored and model-directed code, so anything it asserts about "who
  is asking" - a header or field it sets itself - is not a security
  boundary. A prompt-injected agent could simply claim to be the owner.

So the design constraint is: attribute the triggering sender using only
system-controlled signals, never anything the container asserts about
itself.

### Decision

Owner-only is enforced at the backend using a short-lived, worker-maintained
record of recent activity - an append-only "attested-dispatch window" that
the container can neither add to, remove from, nor extend the life of.

- The worker/runtime layer appends an entry, at the moment it forwards an
  inbound event for processing (a system-controlled event the container has
  no path to trigger or influence), recording either a **human dispatch** -
  the sending member's id, for turn-driving message content and the couple
  of other attested human-originated events that open a turn - or a
  **proactive marker** with no sender, whenever the worker fires its own
  scheduled dispatch (cron, notifications) rather than forwarding a human
  message.
- Entries are append-only: there is no removal path of any kind, and in
  particular no completion-driven settlement - if the container reports
  that a turn has ended, that signal is recorded for telemetry only and is
  never consulted to decide whether an entry is still live. Every entry
  expires purely on a fixed, worker-controlled TTL, and every entry lifetime
  - human dispatches and proactive markers alike - derives from one
  expression: (the maximum number of queued system turns + 1) times the
  wall-clock turn ceiling, plus a margin. At the shipped values - a queue
  cap of 2, a 10-minute ceiling, a 2-minute margin - that is 32 minutes.
  Drift guards pin the components on either side of the language boundary
  to the same source for this value, so the two cannot diverge.
- When exactly one distinct human sender is live in the window **and no
  proactive marker is currently live**, the outbound call to the backend
  carries a `x-convos-trigger-sender-inbox-id` header with that sender's id.
  Any ambiguity - more than one sender, a live proactive marker, or an empty
  window - omits the header.
- The backend compares the header, when present, against the inbox id
  recorded on the grant at the time it was created and denies with a typed
  `owner_only` error on a mismatch - including when the header is absent, and
  including grants with no owner recorded at all (an incomplete write should
  not be treated as open to everyone).
- Enforcement defaults to on in code. An environment override exists purely
  as an operational break-glass - normal operation never sets it, and normal
  rollback is reverting the enforcement change or redeploying the previous
  backend build, not flipping a flag.

The header is named around "trigger sender," not "requester" - it identifies
who sent the message that opened the current turn, which is transport
context, not a claim about intent or authorization. A fuller model that
distinguishes who created a request, who owns the underlying credential, and
who triggered a specific call is future work (see Non-goals); this header is
scoped to exactly what the window can attest today.

### Suppression is unconditional and expires only by TTL

Two properties of the window are worth stating outright, because they are
what make the attribution rule safe rather than merely conservative:

- **A proactive/system marker suppresses attribution for its entire
  lifetime, regardless of what else happens.** That lifetime is the single
  bound above, anchored to the turn's actual start and extend-only. From
  the moment the marker is recorded until it
  expires, no outbound call carries a trigger-sender header at all. Human
  messages arriving during that span do not change this: they are recorded
  as their own entries and are simply additional live entries. The presence
  of any live marker is on its own sufficient to omit the header. A
  scheduled turn's tool calls therefore can never carry a human sender's
  header, no matter what arrives while that turn is running.
- **Human messages can only add entries; nothing removes them.** Appending
  is the only write the window has. No event of any kind - a human message,
  a container-reported turn completion, another dispatch, an operator
  action - removes an entry, clears the window, or shortens any entry's
  remaining life. Entries expire by TTL alone. The only permitted change to
  an existing entry is extending a marker forward to cover its turn's real
  start, which suppresses more, never less.
- **One bound covers both kinds of entry, because a human entry's clock
  starts before its turn runs.** The entry is written when the event is
  forwarded, but the turn that event triggers may execute later if it was
  queued behind others. Bounding every entry by the worst-case execution
  latency - which is exactly what the expression above computes -
  guarantees that a queued human-triggered turn always executes inside its
  own entry's window, so it can never be stamped with a different member's
  identity.
- **Markers may be extended by a container-reported turn start; human
  entries never are.** The asymmetry is deliberate. Extending a marker
  denies more, so accepting that signal is safe even when the container is
  lying. Extending a human entry would allow more - a compromised container
  could keep one member's attribution alive indefinitely by reporting turn
  starts - so a human entry's bound is worker-clock only, fixed when the
  event is forwarded and never touched again.

So suppression is not a state that some later event can lift: there is no
event a turn can wait for, provoke, or race in order to get its calls
attributed to a human sender. The window either attests a single human
dispatcher over its whole trailing span with no marker live, or the call is
denied. Note which way the error runs: longer entry lifetimes mean more
overlap between entries, and overlap denies under the rule that exactly one
distinct human sender must be live, so every adjustment to these bounds
moves the failure mode toward denial and never toward wrong attribution.

### Timeline of the attested-dispatch window

Minutes are illustrative and use the shipped 32-minute bound. `[===]` marks
the live span of an entry; every entry, human or marker, lives for that same
bound.

```
  minute    0       8       16      24      32      40      48
            |   |   |   |   |   |   |   |   |   |   |   |   |

  entry A   [===============================]
            forwarded at 0; expires at 32

  entry B         [===============================]
                  forwarded at 6; expires at 38

  marker            [==][===============================]
                    recorded at 8, then extended forward to the turn's
                    actual start at 12; expires at 44

  entry C                 [===============================]
                          forwarded at 14 - adds an entry, clears nothing

  exec attempts and the stamping decision

    at  2   live: A                stamped, trigger sender = A
    at  7   live: A, B             not stamped - two distinct human senders
    at 13   live: A, B, marker     not stamped - a marker is live
    at 39   live: C, marker        not stamped - a marker is live, even
                                   though C is by now the only live sender
    at 45   live: C                stamped, trigger sender = C - the marker
                                   expired on its own TTL; nothing cleared
                                   it early
    at 47   live: nothing          not stamped - empty window
```

The call at 39 is the case the explicit rule above exists for: a single
human sender is live and the ambiguity from A and B is gone, yet the
scheduled turn's marker still covers the window, so the call is denied. The
call at 45 shows the only way suppression ever ends - the marker reached its
TTL. And because every entry runs the full bound, a turn triggered by C's
message at 14 is still inside C's own entry however long it sat queued.

### Bounding scheduled-turn attribution

An earlier version of this design had a gap: a proactive marker could be
outlived by the scheduled turn it was meant to cover, since nothing bounded
how long that turn could keep running - once the marker expired, the
ambiguity it existed to prevent could reopen while the turn was still live.

This is closed with three changes, all enforced by the worker/runtime layer
rather than anything the container reports about itself:

- **A wall-clock ceiling on every turn.** Every turn now runs under an
  enforced maximum duration (10 minutes), checked inside the execution
  thread itself at every model call and at every tool/ability-exec boundary
  - not just at the edges. A turn that overruns the ceiling can no longer
  execute an ability at all, regardless of what it is doing when the
  ceiling hits.
- **The marker's window is anchored to the turn's actual start, and only
  ever extends.** Rather than a fixed span set when the turn is dispatched,
  the worker refreshes the marker at the moment the turn actually begins
  executing, so the suppression window covers the turn's real execution
  time even if it sat queued for a while first. The marker can only be
  extended this way, never shortened - nothing the container reports can
  pull the window in.
- **The queue of pending triggers is bounded**, so a backlog cannot
  silently push a turn's actual start arbitrarily far past when its entry
  was recorded. Overflow drops the trigger rather than queueing it, which
  fails closed. That cap is also what makes the entry-lifetime expression
  computable at all - the bound is a function of it, so the queue cap and
  the TTL move together.

Together these give a plain invariant: every entry, human or proactive,
outlives the worst-case execution of the turn it belongs to, so neither a
scheduled turn nor a queued human turn can outlive the window that covers
it. Note that only markers get the actual-start extension; human entries
are bounded by the worker clock alone, for the reason given above.

**Why not track per-dispatch lineage instead of bounding a marker's span?**
The transport that carries a dispatch into execution has no notion of
per-dispatch identity, and every turn - human or scheduled - runs inside
the same trust domain as the container. Any marker fine-grained enough to
trace a specific dispatch through to its execution would have to be
readable, and therefore forgeable, from inside that same domain, which
reintroduces the exact container-trust problem the rest of this design
exists to avoid. Bounding how long a marker can possibly need to stay
valid, and only ever extending it from a worker-controlled signal, achieves
the same practical guarantee without needing dispatch-level identity at
all.

### Owner-name denial copy

A denial says whose ability it is rather than just refusing. The backend's
`owner_only` error carries the owner's inbox id when the denied grants share
a single, unambiguous owner (omitted otherwise). The layer that talks to the
model resolves that id to a display name using conversation member profile
data it already has access to, and phrases the denial as:

> "Only \<owner name\> can ask me to use this."

When no name resolves - missing profile data, a lookup failure, or an
ambiguous/absent owner id - it falls back to:

> "Only the ability owner can ask me to use this."

The raw inbox id never appears in text a user sees.

### Deploy-order constraint

The component that stamps the header has to be deployed before the component
that enforces on it; enforcement live with no stamping means every
owner-only check sees no header and denies everything. The work is therefore
split into two sequenced changes rather than coordinated through a shared
feature flag: the stamping change deploys and is confirmed first, then
enforcement. Production promotion follows the same order, and rollback runs
the reverse - enforcement comes out before stamping does.

### Forward design: webhook-triggered execution

Scheduled/proactive execution of owner-only abilities stays off for now
(see Non-goals). Webhook-triggered execution is coming later and needs a
different answer, since there is no live turn to attribute at fire time:

- **Capture** authority once, at subscription-creation time - that happens
  inside a live, window-attested human turn, so the creating member's id can
  be persisted alongside the subscription record as the point of consent.
- **Replay** that stored authority at webhook-fire time as a distinct,
  explicitly-typed claim, never conflated with the live-turn header. The
  backend's owner-only check accepts either claim type against the same
  owner field on the grant; because it re-checks current grant state on
  every call, a revoked or disabled ability still denies correctly even if
  the stored authority itself is stale.
- The cheap thing worth doing now, so this doesn't require touching the
  enforcement path twice later: express stamping as a small discriminated
  claim type (a live-turn claim vs. a stored-authority claim) at the point
  where the header gets set, so a second authority source can be added
  without changing how enforcement reads it.

Deliberately deferred alongside this: re-consent when a subscription's scope
changes, invalidating stored authority when the authorizing member leaves
the conversation, and backend-side verification of the stored claim (it
stays worker-attested for now, same trust level as the live-turn header).

### Alternatives considered

- **Clear an entry when its turn finishes, and suppress attribution from a
  scheduled dispatch only until the next human message. Rejected - this was
  an earlier version of this design, and no part of it survives in what
  shipped.** Two gaps surfaced during implementation:
  a "this turn is finished" signal that anything downstream of the worker
  can trigger is not fully outside the container's reach, so a malicious
  container could clear entries early to narrow attribution, or withhold
  that signal to keep a stale entry alive past when it should expire; and
  suppressing attribution only until the next human message does not block
  attribution for the full span of an in-flight scheduled turn, so a human
  message arriving while a scheduled turn was still running could get that
  turn's tool call misattributed to the human. The fixed-TTL, no-early-removal
  design above closes both: nothing reachable from the container can shorten
  or extend an entry's life, and a scheduled dispatch blocks attribution for
  its entire span rather than only until the next human message.
- **Trust a container-asserted identity** (a header or field the agent's own
  code sets). Rejected as enforcement - the container is exactly the
  untrusted hop; anything it asserts can be prompt-injected. Fine only as
  advisory copy, never as the security boundary.
- **Infer the sender from in-flight delivery-queue state.** Rejected: a
  delivery can sit in an in-flight state for reasons unrelated to the
  current turn - retry backoff, parked awaiting a completion signal that may
  never arrive, or event types that never open a turn at all - for hours.
  Scanning that state for "who's currently talking" produces false
  attribution in both directions, and there is no reliable way to scope it
  to a single conversation when an agent DM and its parent conversation
  share the same underlying session.
- **Serialize delivery per sender until a turn completes** (an "active-turn
  lease"). A stronger invariant, but its release is still gated on the same
  container-originated completion signal - a withheld completion would then
  stall *other members'* message delivery too, turning a spoofing attempt
  into visible group breakage, and it changes delivery semantics on a hot
  path for what is meant to be an interim mitigation. The window reaches
  the same fail-closed outcome without touching delivery semantics at all:
  entries are TTL-bound regardless of what the container does or does not
  report, so there is nothing for a withheld or fabricated completion
  signal to change.

### Known limitations

- If several members are mid-turn at once, the window holds more than one
  live sender and denies rather than guessing (multi-sender dilution).
  Acceptable at pilot scale; the workaround is asking one at a time.
- The header attests who spoke, not what the model was told to do with that
  fact - it stops other members from *using* an ability through the agent,
  it does not prove the owner specifically wanted a given call.
- Turning enforcement on changes the behavior of every existing group grant
  in an environment at once (membership-sufficient access becomes
  owner-only). That is the intended effect, but it is a behavior change
  worth telling pilot users about rather than a silent tightening.
- Because entries never clear early and every entry lives the full bound,
  attribution needs that entire trailing window - 32 minutes at the shipped
  values - to have had a single human dispatcher, not just the instant of
  the check. Group conversations with mixed traffic therefore deny
  considerably more often than a shorter or clears-on-completion design
  would have. That is the price of the guarantee, paid in availability.
- A live proactive marker blocks attribution for its whole span, so a
  genuine ask from the owner right after a scheduled run also denies, for
  as long as that marker's window covers (post-system-turn attribution
  denial).
- If the worker-controlled signal that extends a marker to its turn's
  actual start ever fails to arrive, the marker is treated as still live
  for its originally recorded span rather than assumed clear - attribution
  fails closed on that uncertainty the same as any other ambiguity.

## Q2: Default-enable already-connected abilities in new conversations

### Problem

A grant is created only through explicit action - the per-conversation
toggle, or approving a request from the agent. There is no "on by default"
state; a missing grant simply means off. Every new conversation with an
agent starts at zero abilities, even for a service the member already
connected and uses constantly elsewhere - they have to remember to flip the
toggle again, every time.

### Decision

Client-side auto-enable, scoped narrowly:

- When a member creates a conversation with an agent, or adds an agent to an
  existing conversation, the client automatically grants that member's own
  already-connected, **live** cloud connections to that agent for that
  conversation - through the same confirming grant-write path the manual
  toggle already uses. This is not a new consent model; it materializes real
  grant rows the ordinary way, so "no row means off" stays true and turning
  it off afterward is the ordinary revoke path.
- Scope is deliberately narrow: only the acting member's own connections,
  only when they create the conversation or add the agent - never another
  member's connections, and not merely by joining a conversation someone
  else created.
- A short "connected" line appears in the conversation transcript so the
  auto-grant is visible rather than silent.
- **Live** means server-verified at grant time, not just present in local
  state - a connection whose underlying credential has since been revoked
  server-side should not be able to auto-enable. That check is a hard
  prerequisite: it is a backend liveness gate shipping as separate,
  in-flight work. The client-side implementation can be built ahead of that
  gate landing; turning auto-enable on for users waits until the gate is
  deployed to the target backend, since enabling it earlier would silently
  grant abilities backed by dead credentials at scale.

### Hardening that ships alongside

- **Rollback on a dead-credential rejection.** If the backend rejects a
  grant because the underlying connection is not live, auto-enable must
  fully unwind - including retracting any profile metadata already
  published for that grant - not just skip creating the local row. Otherwise
  other clients can still observe a "connected" claim that never actually
  took effect.
- **Disconnect should revoke server-side grants, not just clean up local
  state.** A connection's local cleanup on disconnect should not be the only
  thing that happens - every grant materialized against that connection
  should also be revoked on the backend. Without this, a later reconnect of
  the same service can silently revive old grants across every conversation
  they were ever created in, including ones the member has forgotten about.
  Worth shipping independent of the rest of this feature.
- **Optional local-only provenance.** Tagging a grant row with how it was
  created (manual toggle, request approval, auto-default) is useful for
  debugging and rollback and does not require any backend schema change.

### Known limitation

The per-conversation toggle reflects local device state only, so the same
account can show a grant as on on one device and off on another until a
device pairs and syncs. Auto-enable does not introduce this - it is an
existing property of the toggle - but it does make it more likely to be
noticed. Documented as a pilot-scale limitation, not solved here.

### Rollout scope

Starts with 1:1 agent conversations, matching the ability feature's current
rollout scope generally. Extending default-on to group conversations is
deliberately sequenced *after* Q1's owner-only enforcement is live in that
environment - default-on and membership-sufficient use are a materially
riskier combination than either alone; default-on plus owner-only narrows
exposure back down to owner-triggered use.

### Alternatives considered

- **Implicit allow inside the entitlement check itself** ("owner has a live
  connection and is a member" treated as sufficient, with no row written at
  all). Rejected: the backend has no notion of conversation membership or
  creation events to key this off; representing "explicitly disabled" would
  need a new tri-state the data model doesn't have; and it makes the
  client's toggle lie, since it only ever reads local rows it wrote itself.
- **Backend materializes a grant when the agent joins the conversation.**
  Rejected: the backend only reliably knows the agent's own connections, not
  the human members'; join events arrive asynchronously after the
  conversation already exists; and it creates rows the member never took an
  action to produce - a worse consent story than the client doing it
  explicitly.

## Q3: "Connect this ability" prompt visibility

### Problem

When the agent asks for something nobody has connected, every member of the
conversation can see the resulting prompt and act on it - including
connecting their own account in response. Whoever resolves it first (connect,
approve, or deny) resolves it for the whole conversation; there is no
per-member state.

### Decision

Keep this behavior as-is, with one small correctness fix as a fast-follow
rather than a blocker.

In the conversations this ships in today (1:1 with an agent), "visible to
everyone in the conversation" and "visible to the owner" are the same thing
- there is no behavioral gap to close yet. It also has a genuine product
upside as-is: it turns a single ask into "whoever cares can connect," and
each response uses the responding member's own account, not the original
asker's. The part that would be risky - one response settling it for a whole
group, or an unauthorized decline - only matters once conversations have
more than one member with different interests in the outcome, which is out
of scope for the current rollout. The honest framing is that the 1:1 scope
is rollout discipline today, not something enforced in code; documenting
that is preferable to adding guard code that a more complete request model
would later delete.

**Interaction with Q1.** Once owner-only enforcement is live, whoever's
account resolves a "Connect this ability" prompt becomes that ability's
owner going forward - only their messages can trigger it afterward. That is
coherent (their credential, their control), but worth surfacing in copy: a
helpful bystander connecting their own account does not hand control to
whoever originally asked.

**Fast-follow (small, ships independently).** Prompt results are currently
matched by a caller-supplied request id with no binding to which agent
issued the request. A crafted or accidentally reused id can resolve an
unrelated pending request. The fix is to key result matching by (asking
agent's id, request id) instead of the bare request id - a local,
client-side change to how results are bucketed, with no wire-format change.

### Later (group rollout)

Once conversations have more than one member with differing interests in the
outcome, the prompt needs role-aware states rather than global
first-response-wins: the member able to connect sees Connect/Approve, others
see a "waiting for someone to connect" state, and declining becomes a
personal dismissal rather than a resolution for the whole group. That needs
a request record with a real notion of who can respond and who has
responded, which does not exist today - not worth building ahead of a group
rollout.

### Alternatives considered

- **Restrict visibility/action to a designated target member now.** Rejected
  for this rollout: there is no target concept on a request today (the wire
  only carries the asking agent's id), and building one is exactly the
  request-record work that belongs with the group-rollout shape above, not
  a 1:1-scope fast-follow.

## Implementation map

Which component owns which piece:

| Component | Owns |
|---|---|
| iOS client app | Auto-enable of the acting member's own live connections at conversation create / agent add (Q2), and the client-side result keying fix (Q3). Nothing for owner-only enforcement. |
| Assistants worker, and its per-conversation durable object | The attested-dispatch window: recording human dispatch entries and proactive markers at forward time, TTL expiry, and the stamping decision that puts `x-convos-trigger-sender-inbox-id` on both outbound exec paths. |
| Agent runtime / container | Runs the turn under the enforced wall-clock ceiling and reports its own turn start so a marker can be extended to cover it. It has no attribution authority: nothing it reports can create, clear, or shorten a window entry in a way that widens attribution. |
| Backend entitlement service | Reads the optional header, compares it against the owner recorded on the grant, and returns the typed `owner_only` denial carrying the owner's inbox id under the single-distinct-owner rule. |
| Agent guidance layer | Turns that denial into requester-facing copy: resolves the owner's inbox id to a display name from conversation member profile data, with the generic fallback when no name resolves. |

## Sequencing

1. Q2's client implementation can start now; enabling it for users waits on
   the backend liveness gate landing. The disconnect-hardening fix has
   standalone value and can ship independently and immediately.
2. Q1 is implemented as two sequenced changes: the worker/runtime stamping
   change first, backend enforcement second, deployed in that order (see
   deploy-order constraint above). The owner-name denial copy rides with
   enforcement.
3. Q3's request-keying fix ships as a small, independent fast-follow; the
   1:1-posture note is documentation, not code.
4. Group-conversation default-on for Q2 follows only once Q1 enforcement is
   live in that environment.

## Non-goals (for this round)

- **Proactive or scheduled execution of owner-only abilities.**
  Cron-triggered and notification-triggered turns have no human sender and
  stay unable to trigger owner-only abilities. Not addressed here.
- **A full request/grant/execution actor model** - verified requester
  accounts, per-request lineage from ask through grant to execution,
  per-grant policy configuration, role-aware multi-party request states, and
  cross-device grant sync. Everything decided above is deliberately scoped
  to avoid requiring any of this; it is the natural next layer once the
  simpler model has been validated in use.
- **Backend-side verification of webhook-replayed authority.** The forward
  design above keeps that claim worker-attested, at the same trust level as
  the live-turn header; server-side verification is deferred with the rest
  of the actor model.
- **Re-consent on scope change, or invalidating stored webhook authority
  when the authorizing member leaves a conversation.** Real gaps in the
  webhook forward design, left for when webhook-triggered execution
  actually ships.

## Removability

None of the above creates schema or wire surface a later, more complete
model would need to migrate away from:

- Q1 is a new optional request header, a code-level default with an
  environment variable as its only override, and state that lives entirely
  inside the worker/runtime layer's own storage - removing the feature
  removes that state with it.
- Q2 writes only the same grant rows the existing manual toggle already
  writes, through the existing write path, plus an optional local-only field
  marking a grant's origin.
- Q3's fix is local result-matching logic on the client; no wire change.
