# Agent DMs — Implementation Plan

> **Status**: Draft (spike output for CON-761)
> **Author**: jarod
> **Created**: 2026-07-22
> **Ticket**: [CON-761 — Spike: Agent DM Viability](https://linear.app/convos/issue/CON-761/spike-agent-dm-viability)
> **Builds on**: ADR 011 (single-inbox identity), the direct-add agent-join architecture (convos-assistants #2074, herald-lite #109, convos-backend #302, convos-ios #1033), and the shipped user 1:1 model (2-member MLS groups). Note: `dm-single-inbox.md` proposed native XMTP DMs for user 1:1s but is **outdated** — user DMs shipped as 2-member groups.

## 1. Summary

Let a member of a group that contains an agent open a private DM with that agent. The target shape from CON-761: **one agent instance in 1 group conversation + N DM conversations with current group members**. Same agent brain everywhere — the DMs are extra channels into the group's agent, not fresh agent instances.

Verdict from this spike: **viable**. No hard protocol blockers. Agent DMs ride the same transport as every conversation in the app today — a 2-member MLS group — so Herald's attach, profile/attestation, streaming, and teardown machinery work unchanged. The work is: observe new-conversation welcomes in Herald, make the worker/runtime conversation-plural, and flip one deliberately-disabled iOS CTA. The risk concentrates in three places: the acceptance/revocation policy, channel-aware runtime behavior, and the shared-transcript confidentiality stance.

## 2. Decisions locked (ticket + comment thread + this plan)

| # | Decision | Source |
|---|---|---|
| D1 | **One Hermes session ID for everything**; a per-message field differentiates conversations inside that session | Nick + Saul in CON-761 comments (both explicitly converged) |
| D2 | DM messages appear in the main transcript and vice versa — one bidirectional transcript | Saul, CON-761 comments |
| D3 | **Herald stays policy-free**: Herald webhooks when the agent inbox lands in a new conversation; the worker decides whether to attach or leave | Nick's option 1 in CON-761, adapted to group transport (see §5.2) |
| D4 | DM transport is a **2-member MLS group** (same as shipped user 1:1s), classified as a DM locally on iOS — not the XMTP `dm` type | This plan, §5.1 (dm-type alternative documented) |
| D5 | Acceptance policy: peer inbox must be a **current member of the agent's primary group**, verified from on-network state | This plan, §5.2 |
| D6 | Revocation: **event-driven agent-leave + periodic reconciliation sweep** | This plan, §5.5 |
| D7 | Product stance: the agent's memory is **shared across the group and its DMs** ("shared brain"), disclosed in UI | This plan, §5.6 — needs product sign-off |
| D8 | Billing: owner pays (unchanged); worker adds per-DM spend caps | This plan, §5.7 |
| D9 | `conversation_id` → `primary_conversation_id` rename with back-compat aliases | CON-761 |

### Answer to Nick's open question ("does single-session make life easier client-side?")

Yes, or at worst neutral — the client is indifferent to Hermes session topology. iOS sees N XMTP conversations either way; read receipts, push topics, consent, and rendering are all per-XMTP-conversation regardless of how the runtime organizes context. Where single-session actively helps the client:

- **No cold-start UX.** The agent never greets a DM user as a stranger, so iOS needs no "context bridging" affordance (no "share group context with agent?" sheet, no explainer for why the agent forgot everything).
- **Behavioral coherence is free.** Task state started in the group carries into the DM with zero client work. There is no client-visible inconsistency to design around.
- The costs land server-side and in product copy, not in client code: the confidentiality stance (§5.6) becomes a disclosure the app owns, and revocation (§5.5) must be watertight because the shared transcript raises the stakes of a stale DM.

Multi-session would have forced the client to explain amnesia. Single-session forces it to explain omniscience. The second is one line of copy; the first is a UX project. Single-session is the right call from the client side.

### Layer separation (to prevent a recurring confusion)

The "one session with channel tags" decision is entirely server-side. On the wire there are N+1 genuinely separate MLS conversations; nothing DM-related ever travels through the primary group, and no channel header ever appears in an XMTP message. The channel header is fabricated by the worker at DO→container delivery time (§5.3). Clients render N+1 ordinary conversations and never see any of it.

## 3. Current state (research summary, verified 2026-07-22 on default branches)

### Herald (herald-lite)

- `POST /v1/conversations/attach` accepts groups (asserts `isGroupLike`, `src/api/conversations/attach.ts:161-167`) and publishes the agent profile on attach (`attach.ts:189-195`). All of this works unchanged for a 2-member group.
- Group message streaming and webhook routing are mature (`src/agent-streamer/stream.ts`, `router.ts`): message/typing/read-receipt/profile events, plus `removed_from_conversation` teardown derived from `group_updated` (`router.ts:445-458`).
- **Gap: Herald only streams conversations it has been told to attach.** Group streams are opened per stored conversation row (`stream.ts:196-206`); there is no observation of welcomes for conversations nobody attached. A user adding the agent inbox to a new 2-member group goes unnoticed today. (The DM-type lane has a global stream but is a deliberate dead-end — `stream.ts:714-780` — and stays out of scope under D4.)
- `leave` works for groups (`src/api/conversation/leave.ts` — it refuses only DMs). Read receipts, sends, replies, reactions, attachments are conversation-generic.
- Group-gated endpoints the runtime depends on (`profile`, `profiles`, `metadata`, `name`, `permissions`) all pass for 2-member groups — the attestation republish path needs no changes.

### Worker + runtime (convos-assistants)

- Single-conversation pinning end to end: DO stores one `herald_conversation_id` (`durable-objects/assistant/migrations.ts:22`, `assistant-store.ts:237-243`); container env `HERALD_CONVERSATION_ID` (`hermes-env.ts:225-226`); Hermes hard-requires one id at start and keys the session to it (`runtime/hermes/src/convos/channel.py:1642-1665`, `HERMES_SESSION_CHAT_ID = conversation_id`); all outbound sends pinned to the stored id (`durable-objects/assistant/herald-helpers.ts:84-172`).
- Inbound: Herald group stream → HMAC webhook → `POST /api/webhooks/herald/:instanceId` → DO enqueue → container drain (`api/webhooks/herald.ts:41-208`).
- Identity: `buildJoinIdentity` (`workflows/create-assistant-workflow.ts:536-577`) rides the attach profile publish; the runtime republishes attestation every 12h via `update_profile` (`runtime/hermes/src/convos/herald/runtime.py:362-404`) against the group profile endpoint — works as-is for DM groups.
- Teardown is keyed to group removal: `api/webhooks/herald.ts:121-145` dispatches the destroy workflow on self-removal from the (single) stored conversation. `classify.ts:isSelfRemoval` must become conversation-aware.
- Hermes has no `channel_id` field in its message schema (confirms the ticket).

### Backend (convos-backend)

- Stateless control plane for agents: **no agent Prisma model**; instances live in the runtime's D1. `POST /v2/agents/join` requires exactly one of `slug`/`conversationId` (`api/v2/agents/handlers/join.ts:91-126`).
- Billing is per-owner-account only: turns are charged to the `ownerAccountId` captured at join via `POST /v2/accounts/:accountId/credits/transactions` under the shared `X-Agent-API-Key` (`api/v2/index.ts:89-94`). No per-conversation attribution, no participation verification, no per-conversation spend cap.
- Backend has **no inboxId↔account mapping** and no membership data — it cannot police DM participation. Policy must live where the on-network state is: the worker + Herald.
- Notifications are conversation-kind-agnostic (`src/notifications/topics.ts:4-8`). Push "just works" for a new 2-member group.

### iOS (convos-ios, dev)

- **User 1:1s ship today as 2-member MLS groups.** `ConversationsRepository.composeOneToOne` requires `COUNT(*) = 2` (`ConversationsRepository.swift:190-205`); `findOneToOne(with:excluding:)` (`:74-76`) and `ContactDetailView.handleSendMessage` → `routeToChat` → `findExistingOneToOne` (`ContactDetailView.swift:476,519,553`) implement lookup-first 1:1 creation. Agent DMs follow this exact pattern.
- The `dm-single-inbox.md` native-DM plan was **not** what shipped; XMTP `dm`-type conversations exist only as hidden internal transport (device pairing, invite join-requests). `ConversationKind.dm` exists in GRDB/rendering (`ConversationKind.swift:5-7`, `Conversation.swift:206-211`).
- The insertion point is explicit: `ContactDetailView.swift:340-369` — `canSendMessage` deliberately disables the Chat CTA for verified agents with the comment "doesn't accept 1:1 DMs today." Template agents route to *new group + new instance* (`handleChatWithAgentTemplate` :642), which is not what CON-761 wants.
- Agent verification is complete and reusable: attestation in profile metadata keys `attestation`/`attestation_ts`/`attestation_kid` (`Storage/Models/Profile.swift:111-113`), `AgentAttestationVerifier` (Ed25519 over inboxId, 24h max age), `AgentKeyset` JWKS from `.well-known/agents.json`, `AGENT_DEBUG_JWKS` override for local dev. Profile messages flow in any group, so the verified badge works in a DM group with zero new crypto.
- The agent's inboxId is already known client-side wherever it matters: as a member of the primary group (member list) and from provisioning (`AgentJoinResponse.inboxId`, `SessionManager.awaitProvisionedAgentInbox` :1571-1614).
- `ConversationCustomMetadata` (ConvosAppData) is the existing mechanism for app-level conversation metadata — used here to mark a conversation as an agent DM so all of the user's devices classify it consistently.

## 4. Architecture

```
                         ┌────────────────────────────────────────────────┐
                         │  Agent instance (one Herald inbox, one DO,     │
                         │  one Hermes session)                           │
                         │                                                │
  Group (primary) ───────┤  primary_conversation_id                       │
  member A ──2p group────┤  dm: convA  (peer_inbox_id = A)                │
  member B ──2p group────┤  dm: convB  (peer_inbox_id = B)                │
                         └────────────────────────────────────────────────┘

DM creation (happy path):
1. iOS: member taps Chat on the agent's contact card (scoped to the group).
   Lookup-first (existing agent-DM for this agent inbox? open it), else:
   create a 2-member group, stamp ConversationCustomMetadata (agent-dm
   marker + agent inboxId), addMembers([agentInboxId]), send first message.
2. Herald's welcome observer sees the agent inbox land in an unknown
   conversation -> webhook `conversation_added` { conversation_id,
   member_inboxes } to the worker (no policy in Herald).
3. Worker policy: exactly 2 members, and peer_inbox_id ∈ current members
   of the primary conversation (GET /v1/conversation/:primary/members —
   on-network truth, no account mapping needed)
   -> pass: POST /v1/conversations/attach (existing endpoint — publishes
      the agent profile + attestation into the DM group as it does on any
      attach) + register the DM in the conversation registry
   -> fail: POST /v1/conversation/:id/leave (existing endpoint). Silent to
      the prober; nothing to clean up.
4. Agent replies; DO routes outbound to the DM's conversation_id.
5. Ongoing: attached conversations stream like any group; downstream
   trusts that whatever Herald delivers was accepted by the worker
   (the spirit of Nick's option 1, with attach/leave in place of consent).

Revocation:
- group_updated on the primary (member removed) -> worker matches
  removedInboxes against the DM registry -> agent LEAVES the DM group
  (cryptographic removal, visible to the user) + status=revoked +
  transcript marker
- reconciliation sweep (cron, e.g. hourly): diff DM registry peers vs
  current primary members; leave any orphans. Two independent layers.
```

## 5. Design decisions in detail

### 5.1 DM transport: 2-member MLS group, classified as DM locally (D4)

Recommended: the DM is a standard 2-member MLS group — exactly how user↔user 1:1s ship today — created by the member, with the agent added via `addMembers`. iOS classifies it as a DM locally (GRDB kind and/or a dedicated flag) driven by a `ConversationCustomMetadata` marker stamped at creation, so every device of the user renders it as a DM after sync.

Why this wins for the agent case:

- **Consistency with shipped reality.** Every visible conversation in the app is an MLS group; user 1:1s are 2-member groups (`composeOneToOne`). Agent DMs introduce no second transport shape. The XMTP `dm` type would have introduced the app's first *visible* dm-type conversation — pure new territory (today's dm-type usage is hidden internal transport only).
- **Herald's machinery works unchanged.** Attach (with its profile+attestation publish), the 12h attestation republish, member/metadata reads, group streaming/routing, and `leave` all pass for a 2-member group. Under the dm type, four of those were blockers needing endpoint changes.
- **Revocation is stronger** (§5.5): the agent *leaves* — cryptographic MLS state, visible to the user — instead of a silent consent preference.
- **No stitching liabilities.** The dm type's stitching would have helped only if both peers had many installations; the agent has one (Herald). What stitching would have cost us: N MLS groups per logical DM on user-device races, push-topic enumeration, and an unresolved SDK question about whether conversation-level consent covers all stitched groups. All moot with groups.

What the group transport costs, and how we pay:

- **Nothing enforces 2-members at the protocol level.** The creating user is admin and could add a third member. Worker policy handles it: `group_updated` adding a member to a registry-DM conversation → the agent leaves (MLS forward secrecy means the newcomer reads no history). See §6.2.
- **Uniqueness is by convention, not protocol.** iOS does lookup-first (the existing `findExistingOneToOne` pattern, keyed on the agent inboxId); the worker registry enforces one active DM per peer (a second welcome for an already-registered peer → leave the new group). Cross-device create races resolve to the registry's first-accepted conversation.
- **Local classification needs care.** The phase-1 retro in `dm-from-group.md` flagged "store group conversations as `.dm` locally" as a smell: code that branches on `kind == .dm` and then assumes dm-type XMTP semantics (e.g. `ConversationWriter.inviteTag` throws for `.dm`). The iOS work includes an audit of `kind == .dm` branch sites (§6.4); alternatively classification can use a dedicated `isAgentDm` flag and reuse the plain 1:1 rendering path — decide in implementation, the wire format is identical either way.

Documented alternative (not chosen): native XMTP `dm` type. Gains structural 2-member invariance and protocol-level dedupe; costs Herald endpoint relaxations (attach, profile, metadata), consent-only invisible revocation, dm special-casing in the runtime refresh loops, stitching liabilities, and a consent-scope-under-stitching SDK unknown. Revisit only if the group approach hits something unexpected in Phase 0.

### 5.2 Acceptance policy: welcome-webhook + worker-owned attach/leave (D3, D5)

Nick's three options, evaluated against the research:

1. **Herald signals, worker decides** — chosen, adapted to group transport: Herald gains one generic primitive (a `conversation_added` webhook when the agent inbox lands in a conversation nobody attached) and zero business logic. The worker owns policy — the same place that already owns lifecycle, billing hooks, and the destroy workflow. Accept = the existing `attach` endpoint; deny = the existing `leave` endpoint. Herald delivers messages only for attached conversations (already true — it streams only stored rows), so downstream keeps the "whatever Herald delivers was accepted" trust model.
2. Herald trusts everything, filter per-message downstream — rejected: every layer downstream must re-derive trust on every message; the "layers of gates" problem the ticket complains about, reborn with more steps.
3. Herald auto-accepts based on group co-membership — rejected per Nick's own note: bakes app policy into Herald, which would also need to learn which conversation is "primary" — an application concept.

Policy check detail: membership is verified from **on-network state** (Herald's member list for the primary conversation), never from caller claims. The backend cannot participate (no inboxId↔account map — §3) and doesn't need to. The check is idempotent per peer and enforces the registry's one-active-DM-per-peer rule (§5.1).

Sender-side gating (iOS) hides the CTA when the viewer isn't a current co-member, but the worker check is the enforcement; the CTA is UX.

### 5.3 Session model: one Hermes session + channel metadata (D1, D2)

Per the ticket thread: one Hermes sessionID; every message entering the transcript carries a channel tag. Hermes has no `channel_id` field, so the worker/DO owns the mapping and the delivery path injects it. The concrete contract:

**Channel labels.** `main` for the primary conversation; `dm-<first 8 hex of conversation_id>` for DMs (extend to 12 on the rare collision). Labels are minted at registry insert and never change; the registry is the authoritative label ↔ conversation_id map. Labels never derive from display names (names change; labels must not).

**Per-message tag (token-lean).** Every message delivered to the model is prefixed with the label only:

```text
[#dm-3f9a8c12] <sender>: <message text>
[#main] <sender>: <message text>
```

No kind field (the prefix encodes it), no participants field (DM rosters are static and carried by the notes below). Rationale: the tag is paid on every message forever; roster/context is paid once per event.

**Channel context, injected once per event, not per message:**
- *Session boot*: a registry summary in the injected context — `Channels: #main = the group conversation. #dm-3f9a8c12 = private DM with Alice. ...` Regenerated every boot, so context truncation can never orphan a label.
- *Channel opened*: system note `[#dm-3f9a8c12] Channel opened: private DM with Alice (group member).`
- *Channel revoked/closed*: system note `[#dm-3f9a8c12] Channel closed: Alice is no longer in the group. Do not address this channel again.`

**Send-tool contract.** Send tools gain one optional string parameter `channel` (a label, e.g. `"dm-3f9a8c12"`); default is the channel of the message that triggered the turn. The DO resolves label → conversation_id against the registry and rejects unknown or revoked labels with a tool error the model can read (`channel #dm-3f9a8c12 is closed`). Reply/reaction tools derive the channel from the target message; an explicit `channel` that disagrees is an error, not a redirect. Read receipts are automatic per channel, never model-controlled. Enforcement lives at the DO — an agent must never be able to send to a revoked channel regardless of what the prompt says.

Other placement rules:
- **The conversation registry lives in the DO** (new SQLite table, §6.2) — conversation_id, kind, peer_inbox_id, status, label.
- **Tag injection happens at DO→container delivery** (`herald-helpers.ts` / the drain path), not in Herald and not in Hermes. The tag never appears on the wire (§2, layer separation).
- Memory files, cron/scheduled work, and self-initiated sends default to `main` unless explicitly targeted.

### 5.4 Channel-aware runtime (the ticket's `Map<String, Map<String, String>>` work)

Inventory of single-conversation state to make per-channel, all in `runtime/hermes/src/convos/` and the DO:

- **Interruption management + burst buffers**: keyed by conversation. A burst in DM-A must not interrupt or merge with a burst in the group. (`channel.py` — the buffering/interruption logic around the session event loop.)
- **Delivery cursors**: per conversation (Herald already cursors per `(accountId, conversationId)` — the runtime-side cursors must match).
- **Member lists / metadata cache**: `_refresh_metadata_if_stale` (`runtime.py:412-413`) becomes per-channel; a DM group has a fixed 2-member list — same endpoints, smaller answers.
- **Read receipts**: send per conversation, batched within a conversation only (the ticket calls this out; the read-receipt endpoint is conversation-scoped already).
- **Attestation republish**: the 12h `update_profile` refresh (`runtime.py:362-404`) iterates all active channels instead of only the primary; endpoints are unchanged (group profile publish works in DM groups). Initial DM publish rides the attach (§5.2), same as the primary join.
- **Prompt updates**: rules written for one thread ("don't send more than two messages in a row unless tagged") become per-channel rules; add channel-behavior guidance (see §5.6 for the confidentiality rules). Response-discipline evals extend across channels (§9).

### 5.4.1 Scheduled/self-initiated sends: findings from the local prototype

Confirmed live: a message scheduled from a DM delivers to the primary
conversation. Replies are conversation-correct (the DO's outbound box
override routes them), but cron fires deliver inside the runtime via the
direct Herald client, which resolves every send against the pinned
conversation (`herald/client.py` `_messages_url` reads
`self.conversation_id`). The job records no origin conversation.

**Status: implemented and verified on the local stack (2026-07-23)** — a job scheduled from a DM now fires back into that DM. The map below was the design; two build-time findings joined it: the tool executor runs tools off the turn's task, so the origin needs a thread-visible mirror beside the ContextVar (turns are serialized under the agent lock, making a module attribute race-safe), and wrangler dev does not rebuild container images on source changes — local Hermes iteration must rebuild over wrangler's cached tag manually. Jobs freeze their target at creation; pre-fix jobs keep firing into the primary.

- `events.py`: additive `origin_conversation_id: str | None` on
  `InboundMessage`. Do NOT stamp `conversation_id` with the true id —
  `channel.py` keys the Hermes session on `msg.conversation_id`
  (`session_key=`, ~line 1886), so truthful stamping forks a session per DM,
  which is exactly the multi-session model D1 rejected.
- `herald/runtime.py` `_handle_message` (~line 648): populate the new field
  from the webhook payload's `conversationId` when it differs from the
  pinned conversation.
- `channel.py`: capture the current turn's origin; cron job creation stamps
  it on the job (the `deliver` field is already colon-namespaced —
  `convos:<conversationId>` is the natural encoding, see
  `convos_cron/targeting.py`); `dispatch_system_trigger` gains an optional
  conversation override threaded to the response send.
- `herald/runtime.py` `send_message` + `herald/client.py`: optional
  per-call conversation override down to the URL builder.
- Requires a Hermes container image rebuild; regression risk concentrates in
  `dispatch_system_trigger` (also used by notify + onboarding) — default
  every new parameter to current behavior.

Related worker-side leftover: the webhook classifier stamps
`conversation_id` only on `message` events, so DM typing indicators reach
the runtime attributed to the primary (cosmetic locally; fix alongside).

- **Renames** (D9): `HERALD_CONVERSATION_ID` → `PRIMARY_CONVERSATION_ID` (env), `herald_conversation_id` → `primary_conversation_id` (DO store), `assistants.conversation_id` → semantic "primary" (D1). Keep read-side aliases for one deploy cycle; the direct-add cross-repo deploy order (worker → backend → apps) is the template.

### 5.5 Revocation: two independent layers (D6)

The ticket's hardest requirement: "when a user is removed from a conversation we need to invalidate its DM session with the agent or we have a serious privacy problem."

- **Layer 1 — event-driven (seconds):** Herald already emits `group_updated`-derived events for the primary group. The worker's webhook handler, on member-removal events, matches `removedInboxes` against the DM registry and for each hit: registry status → `revoked` (DO refuses all sends to the channel), Herald **detaches** the conversation (stops streaming/delivering — unilateral and immediate), the agent calls `requestRemoval()` on the DM group, and a system marker lands in the session transcript (`[Channel dm-3f9a revoked: peer left the group]`). Leave semantics, measured (Phase 0): `requestRemoval` is a request — the *peer's* client auto-commits the removal on its next sync (no UI action, honest clients complete it within one sync), after which the peer's sends can't reach the agent at the MLS layer and the ending is visible. A hostile client can delay that visible commit indefinitely — but gains nothing, because the detach + DO refusal already cut delivery and response on the agent side.
- **Layer 2 — reconciliation sweep (bounded staleness):** a scheduled job (piggyback the DO alarm cadence or worker cron, e.g. hourly) fetches current primary members and leaves any registry-DM whose peer is not in the set. Catches missed webhooks, Herald restarts mid-stream, and any ordering races. The sweep is idempotent and cheap (one members call + registry diff).
- **Failure posture:** leaving is enforced *at the protocol layer* — after the leave, there is no channel for a confused model to answer on; the DO's outbound validation (§5.3) blocks sends to revoked registry entries even before the leave lands. Prompt-level behavior is a nicety on top, not the enforcement.
- **UX comes for free:** the user sees the agent leave the conversation — a comprehensible ending, not a ghost town. An optional farewell message before the leave is a product choice (§10).
- The revoked DM's *past* content remains in the transcript — same standing as the group history the member saw while present. What's cut off is the live channel. (Called out in §5.6 and for product sign-off.)

### 5.6 Confidentiality stance: shared brain, disclosed (D7 — needs product sign-off)

One transcript means member A can try to extract what member B told the agent privately. Prompt rules cannot make an LLM keep secrets against a motivated extractor — we must not pretend otherwise.

Proposed stance for v1:
- **Product framing: the agent is the group's agent.** Its memory is shared across the group and all its DMs. The DM is private *from other members reading it directly*; it is not private *from the agent's shared memory*.
- **Disclosure in UI**: one line in the DM header/first-open state: "This agent shares memory with [group name]." Copy pass needed.
- **Prompt policy as etiquette, not security**: instruct the agent to treat DM content as confidential-by-default in other channels. This reduces casual leakage; the disclosure covers adversarial extraction.
- **Eval, don't assume**: a cross-channel leakage eval (§9) measures how often the agent volunteers channel-B content in channel-A under benign and adversarial prompting, so the stance is grounded in measured behavior before TestFlight.

Rejected alternative for v1: per-channel context filtering (build the LLM context per channel, excluding other DMs) — this is the multi-session model through the back door, reintroducing exactly the amnesia/complexity the thread decided against. Revisit only if the leakage eval fails badly AND product wants hard isolation more than coherence.

### 5.7 Billing and abuse (D8)

Today: every turn bills the `ownerAccountId` captured at join; no per-conversation attribution or cap (§3). Under agent DMs, **any group member could drain the owner's wallet** by spamming the agent in a DM.

V1 (no backend changes):
- **Worker-side caps** in the DO before generation: per-DM-conversation turn budget per rolling window, plus a global per-instance daily budget across DM channels. Over budget → agent replies with a canned back-off in that DM (no LLM call) or goes silent; primary channel unaffected.
- Caps are registry fields so support can tune per instance.

Later (backend, optional): per-conversation ledger attribution — `CreditLedger.scope` exists and is unused for conversations; a `conversation` scope would let the owner see per-DM spend, and opens the door to "DM peer pays" models if product ever wants them. Explicitly out of scope for v1.

### 5.8 Capability signaling + identity in DMs

- **`accepts_dms`**: DM-capable runtime versions publish `accepts_dms: true` in the agent's ProfileUpdate metadata for the primary group (additive metadata map; old clients/instances simply lack the key). iOS gates the Chat CTA on: verified agent AND `accepts_dms` AND viewer is a current co-member AND feature flag. Scope this honestly: the fleet converges on the new runtime by itself (the Hermes image rides the worker deploy; containers pick it up on their next wake/refresh — convergence check is Phase 0 S5), so the flag is not a hard shipping requirement. It buys three cheap things: an honest rollout window (the CTA appears exactly when that instance is actually capable, no deploy-timing choreography), a backstop for instances that never cycle (agents nobody has messaged since the deploy), and the natural carrier for a future owner-facing "no DMs" toggle (§10). The minimal alternative — client flag timed after fleet convergence, worker-side deny as safety net — is workable but trades a published per-instance fact for an ops-timing assumption.
- **Attestation in the DM**: the attach publishes the agent's profile+attestation into the DM group exactly as it does on the primary join (existing `attach.ts:189-195` behavior), and the 12h refresh iterates active channels (§5.4). iOS renders the verified badge in the DM with zero new crypto — `AgentAttestationVerifier` doesn't care which conversation the profile message arrived in.

### 5.9 Lifecycle

- **Primary group destroyed / agent removed** → existing destroy workflow runs; add a fan-out step: leave all registry DMs (and optionally a farewell message per DM before leaving — product choice, §10). DMs end visibly with the instance.
- **DM-side exit**: the user can simply delete the conversation locally, or remove the agent (creator is admin — removing the agent triggers the same `removed_from_conversation` handling as any group, which the worker interprets as "close this channel," not "destroy the instance"; `classify.ts:isSelfRemoval` becomes conversation-aware, §6.2). Either way the registry entry closes.
- **Explode**: a DM group explodes like any conversation if the user chooses; the agent's removal lands as self-removal on that channel. When the primary group explodes, the destroy fan-out above covers the DMs.

## 6. Work breakdown by repo

Deploy order mirrors direct-add: **herald-lite → convos-assistants → convos-ios** (backend has no required v1 changes). Every stage is backward-compatible; old agents without `accepts_dms` never see the feature.

### 6.1 herald-lite

1. **New-conversation observation**: stream conversation welcomes for each agent account (node SDK conversation stream) and emit a `conversation_added` webhook event `{ conversation_id, member_inboxes, created_at }` for conversations that are not in the stored/attached set. No policy — observation only. This is the one net-new Herald capability.
2. **Attach idempotence for observed conversations**: `/v1/conversations/attach` already handles "welcome already landed" (it polls until membership is active); verify it short-circuits cleanly when called for a conversation the welcome observer already saw. Expect minimal or no change.
3. **Read receipts**: endpoints are already conversation-scoped; verify the streamer's receipt batching batches per conversation (ticket item).
4. Nothing else: profile publish on attach, attestation republish, member/metadata reads, `leave`, and group streaming all already work for 2-member groups.

### 6.2 convos-assistants (worker)

1. **Conversation registry**: DO SQLite migration — `conversations(conversation_id, kind, peer_inbox_id, status, label, attached_at, budget fields)`. Primary conversation becomes row zero; `herald_conversation_id` → `primary_conversation_id` with a read alias (D9).
2. **Policy module**: handle `conversation_added` webhooks — require exactly 2 members, peer ∈ primary members (Herald members list), no existing active DM for that peer; then attach + registry insert, else leave. Idempotent per conversation and per peer. All decisions logged/metric'd.
3. **Membership-change policy**: extend the `group_updated` handling — third member added to a registry DM → leave; peer removed from primary → revocation Layer 1 (§5.5); agent removed from a registry DM → close that channel (not instance destroy — make `classify.ts:isSelfRemoval` conversation-aware against the registry).
4. **Reconciliation sweep** on the DO alarm; destroy-workflow fan-out (§5.9).
5. **Outbound plural**: `herald-helpers.ts` send/reply/receipt take a conversation_id from the registry (validated) instead of the single pinned id.
6. **Channel header injection** at delivery into the container; send-tool `channel` parameter surfaced to the runtime.
7. **Spend caps** (§5.7) checked in the drain path before generation.

### 6.3 convos-assistants (Hermes runtime)

1. Keep the primary-id requirement at `start` (`channel.py:1642-1665`); DM channels arrive as additional registry-driven channels, not at boot.
2. Per-channel interruption/burst/cursor/member-list state (§5.4).
3. Attestation/metadata refresh loop iterates active channels (same endpoints; §5.4).
4. Prompt updates: channel-awareness rules + confidentiality etiquette (§5.6); read-receipt behavior per channel.

### 6.4 convos-ios

1. **Flip the CTA**: `ContactDetailView.swift` `canSendMessage` — enable Chat for verified agents when `accepts_dms` is present and the viewer shares the conversation (`.scopedToConversation` mode). Flow: lookup-first (existing agent-DM for this agent inboxId → open), else create a 2-member group + stamp the marker + `addMembers([agentInboxId])`. The agent's inboxId comes from the member list.
2. **The marker (decided)**: new field on `ConversationCustomMetadata` (`conversation_custom_metadata.proto` — field 8 is free):

   ```proto
   message AgentDmInfo {
       optional bytes originConversationId = 1;  // the primary group this DM was started from
   }
   // in ConversationCustomMetadata:
   optional AgentDmInfo agentDm = 8;
   ```

   Presence of `agentDm` drives classification. The agent's identity comes from the membership itself, not the marker: hydration only honors the marker when the conversation has exactly 2 members AND the other member is an agent (`member_kind == AGENT`, verified via the existing attestation path). That is both stronger than a marker-asserted inboxId (cryptographic vs creator-written) and closes the abuse case of stamping the marker on an ordinary conversation to distort other members' UI. `originConversationId` enables "Agent from [group]" context and lets the app find the primary group locally. Classification may land after the agent's profile message syncs — tolerated (item 5).
3. **Local DM classification (decided)**: a dedicated `isAgentDm` flag on the (group-kind) conversation row — reuses the shipped 1:1 rendering path unchanged, no `kind == .dm` branch-site audit. UI driven by the flag: hide the add-member "+" button, hide the QR/invite-link surfaces, show the shared-brain disclosure (§5.6). Promote to kind `.dm` later only if DM-specific rendering demands it.
4. **`accepts_dms` plumbing**: read the metadata key through the existing profile pipeline (additive map — no proto change).
5. **Push + NSE**: nothing new structurally — the DM group rides standard group topics and welcome handling. Verify the welcome path classifies (marker may arrive with/after the welcome; tolerate late classification).
6. **UI**: "agent left" rendering on revocation is the standard member-left treatment; verified badge renders from the DM group's own profile messages (§5.8).
7. **QA doc** under `qa/tests/` covering create/deny/revoke flows (see §9).

### 6.5 convos-backend

No required v1 changes. Optional fast-follows: per-conversation ledger scope (§5.7); a `dm` capability surfaced on agent-template metadata if the gallery ever wants "DM-able" filtering.

## 7. Phasing and PR sequencing

- **Phase 0 — protocol validation spike** (throwaway code, local stack): S1 confirm Herald can observe a welcome for a 2-member group it was never asked to attach (conversation stream) and measure add→observation latency; S2 confirm attach-then-stream works for such a group end to end (profile publish renders + verifies on iOS, agent replies land); S3 exercise the membership edges — third member added (revocation fires), peer removed from primary (revocation fires), agent removed from the DM (channel closes, instance survives); S4 confirm `ConversationCustomMetadata` classification syncs to a second device of the same user; S5 confirm fleet convergence — a rebooted container of a pre-deploy instance boots the *new* Hermes image. Exit criteria: all five demonstrably true, add→first-reply latency acceptable (< ~10s including container wake). *This closes CON-761 with a viability verdict and hard numbers.*

  **Results so far (2026-07-22, XMTP dev network, node-sdk 6.1.0-nightly):**
  - **S1 PASS.** A fresh inbox running `conversations.stream()` observed the welcome for a 2-member group it never attached in **609-678ms** across runs, conversation id matching. A first message then arrived on `streamAllMessages()` in **182ms** with zero consent action on the observer side. Welcome observation is not the latency bottleneck; container wake will be.
  - **S3 (leave semantics) MEASURED.** `requestRemoval()` in a 2-member group where the other member is sole admin: no membership change until the *peer's* client syncs, at which point the SDK **auto-commits the removal** (2 members → 1, no UI action). After removal, a message sent by the peer was never seen by the leaver's stream. Consequence baked into §5.5: guaranteed cutoff is agent-side detach + DO refusal; MLS removal is the visible layer honest clients complete within one sync.
  - **S5 PASS (desk check).** `wrangler.toml` containers config sets `rollout_step_percentage = 100` — the new Hermes image rolls to all container instances at deploy; prod agents are not version-pinned (only dev-only per-PR `AgentVariant` deployments are separate). Fleet convergence rides the deploy, not organic wake.
  - **S2 (protocol side) PASS** — run against the *local stack* with a real registered Herald agent account, on a prototype herald-lite branch (`jarod/con-761-conversation-added`, local-only) implementing the `conversation_added` observer: (a) live path — Herald's group-welcome stream observed a 2-member group created by an external inbox and dispatched the webhook; (b) **catch-up path** — a welcome that landed while Herald was down was reported on the next boot (the observer needs this sweep; without it, boot/warmup/restart gaps silently swallow DM requests — now part of the design); (c) the *existing* `/v1/conversations/attach` returned `attached` for the externally-created group with zero changes; (d) the agent's `convos.org/profile_update` landed in the DM group, visible from the user's client. Caveats for Phase 2: the profile publish carries a verified badge only when attach is called with attestation fields — the worker (which holds the signing key) must do the attach, so iOS badge verification is a Phase 2 checkpoint; the local worker 503'd all webhooks for the June-era instance (worker-side handling, including the `conversation_added` handler, is Phase 2 scope). Operational note: herald's single-writer `flock` child survived a naive restart and blocked boot for 10 minutes — the sweep exists precisely for windows like this.
  - **Open:** S2 iOS badge render (Phase 2 gate), S3's remaining edges against the real worker policy, S4 (marker sync across devices).
- **Phase 1 — Herald observation** (§6.1): `conversation_added` webhook. Independently deployable; nothing consumes it yet.
- **Phase 2 — worker registry + policy + revocation** (§6.2 items 1-4): agent accepts/denies DMs; replies still single-channel — internal testing via CLI/local stack.
- **Phase 3 — runtime channel-awareness** (§6.2 items 5-7, §6.3): full multi-channel behavior behind an instance-level flag; evals run here.
- **Phase 4 — iOS surface** (§6.4) behind a feature flag; internal dogfood on the local stack + dev network.
- **Phase 5 — hardening**: reconciliation sweep soak, spend-cap tuning, leakage eval gate, TestFlight.

Within each repo, stack PRs per the standard checkpoint conventions (plan PR first — this document).

## 8. Privacy & security review points

- **Removed-member lockout** is enforced agent-side (Herald detach + DO send-refusal — unilateral, immediate; two layers, §5.5), with MLS removal as the visible layer honest peer clients auto-complete. Not enforced by prompting. Verify in QA: removed member's post-revocation sends are never delivered to the agent, and the DO refuses sends to revoked registry entries even before the MLS removal commits.
- **Cross-DM/adversarial extraction** is *not prevented*, it is disclosed (§5.6) and measured (§9). Product/safety must sign off on that stance explicitly.
- **Non-member DM attempts** (anyone who learns the agent inboxId and adds it to a group): the worker leaves immediately; the prober learns only that the agent left — no response, no attach. Watch `conversation_added` denial metrics for probe spam; a leave is cheap and terminal per conversation.
- **Third-member injection** into an active DM: worker leaves on the membership event; MLS forward secrecy keeps history unreadable to the newcomer. QA case.
- **Spend abuse** by legitimate members: capped per §5.7; alert on cap hits.
- **Attestation in DMs** keeps the verified-agent trust story intact outside the primary group (no unverified look-alike agents in DM lists).

## 9. Testing & evals

- **Unit/integration**: Herald welcome observation + webhook; worker policy decision table (member/non-member/removed/re-added/second-DM-same-peer/third-member); revocation sweep idempotence; conversation-aware `isSelfRemoval`; DO outbound validation against revoked channels.
- **E2E on the local stack**: scripted flow — create group + agent, DM from member (accepted, badge verifies), DM from non-member (agent leaves), remove member then DM behavior (agent leaves within sweep interval), re-add member (fresh DM re-evaluated), third-member injection (agent leaves). Codify as a QA doc in `qa/tests/`.
- **Evals (extend the existing response-discipline suite)**: channel confusion (does the agent reply in the right channel; does it address the right person); response discipline across channels (the "two messages in a row" rule per channel); cross-channel leakage (benign + adversarial extraction attempts, §5.6); DM cold-open quality (first DM turn should show it knows the group context — the payoff of single-session).
- **Metrics for rollout**: DM accept/leave counts by reason, add→first-reply latency, revocation event→leave latency, sweep catches (should trend to zero), spend-cap hits, leakage-eval scores per runtime release.

## 10. Open questions

1. **Product sign-off on the shared-brain stance** (§5.6) — the one decision that could reshape the architecture; needed before Phase 3.
2. Farewell message before the agent leaves on revoke/destroy (§5.5, §5.9) — nice or noise?
3. `accepts_dms` granularity: per-instance bool (v1) vs owner-configurable toggle in the builder — builder UI implications.
4. Does the reconciliation sweep cadence need to be tighter than hourly for the privacy bar? (Layer 1 handles the common case in seconds; the sweep only bounds the miss window.)
5. ~~iOS classification shape~~ **Decided**: dedicated `isAgentDm` flag on a group-kind row (§6.4 item 3); kind `.dm` promotion deferred until DM-specific rendering demands it.
6. Should a user-initiated "remove agent from DM" (creator-as-admin removal) be surfaced as an explicit affordance, or is delete-conversation enough for v1?
