# Ability Owner Scoping, Default-Enable, and Request Visibility

> **Status:** Decided design, fast-follow implementation
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

Enforce owner-only at the backend using a short-lived, worker-maintained
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
- Entries are never removed early; they expire purely on a fixed,
  worker-controlled TTL - roughly 10 minutes for a human entry, and the
  scheduled dispatch's own lead time plus that same window for a proactive
  marker.
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
scoped to exactly what the ledger can attest today.

### Owner-name denial copy

A denial should say whose ability it is, not just refuse. The backend's
`owner_only` error carries the owner's inbox id when the denied grants share
a single, unambiguous owner (omitted otherwise). The layer that talks to the
model resolves that id to a display name using conversation member profile
data it already has access to, and phrases the denial as:

> "Only \<owner name\> can ask me to use this."

When no name resolves - missing profile data, a lookup failure, or an
ambiguous/absent owner id - it falls back to:

> "Only the ability owner can ask me to use this."

The raw inbox id should never appear in text a user sees.

### Deploy-order constraint

The component that stamps the header must be deployed before the component
that enforces on it; enforcement live with no stamping means every
owner-only check sees no header and denies everything. In practice this
means shipping and confirming the stamping change first, then shipping
enforcement - rather than coordinating the two through a shared feature
flag. Production promotion should follow the same order.

### Forward design: webhook-triggered execution

Scheduled/proactive execution of owner-only abilities stays off for now
(see Non-goals). Webhook-triggered execution is coming later and needs a
different answer, since there is no live turn to attribute at fire time:

- **Capture** authority once, at subscription-creation time - that happens
  inside a live, ledger-attested human turn, so the creating member's id can
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
  scheduled dispatch only until the next human message.** An earlier version
  of this design worked this way. Two gaps surfaced during implementation:
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
  path for what is meant to be an interim mitigation. The ledger reaches the
  same fail-closed outcome (ambiguity denies, staleness denies, a withheld
  completion costs the attacker nothing) without touching delivery
  semantics.

### Known limitations

- If several members are mid-turn at once, the ledger holds more than one
  live sender and denies rather than guessing. Acceptable at pilot scale;
  the workaround is asking one at a time.
- The header attests who spoke, not what the model was told to do with that
  fact - it stops other members from *using* an ability through the agent,
  it does not prove the owner specifically wanted a given call.
- Turning enforcement on changes the behavior of every existing group grant
  in an environment at once (membership-sufficient access becomes
  owner-only). That is the intended effect, but it is a behavior change
  worth telling pilot users about rather than a silent tightening.
- Because entries never clear early, attribution needs the entire trailing
  TTL window to have had a single human dispatcher, not just the instant of
  the check - group conversations with mixed traffic deny more often than a
  clears-on-completion design would have.
- A live proactive marker blocks attribution for its whole span, so a
  genuine ask from the owner immediately after a scheduled run can also
  deny, for a few minutes past that run's start.
- A scheduled turn that runs longer than its own marker re-opens the
  ambiguity window for whatever remains of that turn.

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

## Sequencing

1. Q2's client implementation can start now; enabling it for users waits on
   the backend liveness gate landing. The disconnect-hardening fix has
   standalone value and can ship independently and immediately.
2. Q1 ships as two sequenced changes: the worker/runtime stamping change
   first, backend enforcement second, deployed in that order (see
   deploy-order constraint above). The owner-name denial copy ships
   alongside enforcement.
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
