# Agent DMs — Implementation Plan

> **Status**: Draft (spike output for CON-761)
> **Author**: jarod
> **Created**: 2026-07-22
> **Ticket**: [CON-761 — Spike: Agent DM Viability](https://linear.app/convos/issue/CON-761/spike-agent-dm-viability)
> **Builds on**: `dm-single-inbox.md` (user-DM design, not yet built), ADR 011 (single-inbox identity), the direct-add agent-join architecture (convos-assistants #2074, herald-lite #109, convos-backend #302, convos-ios #1033)

## 1. Summary

Let a member of a group that contains an agent open a private DM with that agent. The target shape from CON-761: **one agent instance in 1 group conversation + N DM conversations with current group members**. Same agent brain everywhere — the DMs are extra channels into the group's agent, not fresh agent instances.

Verdict from this spike: **viable**. No hard protocol blockers. Herald already half-models DMs (kind mapping, `is_dm` column, cursors, a running-but-dead-end DM stream), all message send/reply/receipt endpoints already accept DMs, iOS already has DM transport (pairing + invites) and complete agent verification. The work is: route Herald's DM lane to the agent webhook, make the worker/runtime conversation-plural, and flip one deliberately-disabled iOS CTA. The risk concentrates in three places: the acceptance/revocation policy, channel-aware runtime behavior, and the shared-transcript confidentiality stance.

## 2. Decisions locked (ticket + comment thread + this plan)

| # | Decision | Source |
|---|---|---|
| D1 | **One Hermes session ID for everything**; a per-message field differentiates conversations inside that session | Nick + Saul in CON-761 comments (both explicitly converged) |
| D2 | DM messages appear in the main transcript and vice versa — one bidirectional transcript | Saul, CON-761 comments |
| D3 | **Herald stays policy-free**: consent state drives delivery; Herald webhooks on DM welcome; the worker decides whether to allowlist | Nick's option 1 in CON-761 (recommended here over options 2/3 — see §5.2) |
| D4 | DM transport is a **native XMTP DM** (`findOrCreateDm`), not a 2-member group | This plan, §5.1 (fallback documented) |
| D5 | Acceptance policy: peer inbox must be a **current member of the agent's primary group**, verified from on-network state | This plan, §5.2 |
| D6 | Revocation: **event-driven consent deny + periodic reconciliation sweep** | This plan, §5.5 |
| D7 | Product stance: the agent's memory is **shared across the group and its DMs** ("shared brain"), disclosed in UI | This plan, §5.6 — needs product sign-off |
| D8 | Billing: owner pays (unchanged); worker adds per-DM spend caps | This plan, §5.7 |
| D9 | `conversation_id` → `primary_conversation_id` rename with back-compat aliases | CON-761 |

### Answer to Nick's open question ("does single-session make life easier client-side?")

Yes, or at worst neutral — the client is indifferent to Hermes session topology. iOS sees N XMTP conversations either way; read receipts, push topics, consent, and rendering are all per-XMTP-conversation regardless of how the runtime organizes context. Where single-session actively helps the client:

- **No cold-start UX.** The agent never greets a DM user as a stranger, so iOS needs no "context bridging" affordance (no "share group context with agent?" sheet, no explainer for why the agent forgot everything).
- **Behavioral coherence is free.** Task state started in the group carries into the DM with zero client work. There is no client-visible inconsistency to design around.
- The costs land server-side and in product copy, not in client code: the confidentiality stance (§5.6) becomes a disclosure the app owns, and revocation (§5.5) must be watertight because the shared transcript raises the stakes of a stale DM.

Multi-session would have forced the client to explain amnesia. Single-session forces it to explain omniscience. The second is one line of copy; the first is a UX project. Single-session is the right call from the client side.

## 3. Current state (research summary, verified 2026-07-22 on default branches)

### Herald (herald-lite)

- Models both kinds: `src/xmtp-mappers/conversation.ts:43-54` emits `kind: "group" | "dm"`; DB has `is_dm` + per-conversation cursors (`src/db/schema.ts:50-68`).
- **A DM stream already runs** (`src/agent-streamer/stream.ts:611-642`, `streamAllDmMessages`, listing `consentStates: [Unknown, Allowed]`) but is a deliberate dead-end: `handleDmMessage` (`stream.ts:720-780`) only processes legacy `invite_join_error` replies and drops everything else. The comment at `stream.ts:714-719` explicitly says: "If we ever route general DM text, mirror the diag block from `handleGroupMessage` here."
- `POST /v1/conversations/attach` **rejects DMs** (`src/api/conversations/attach.ts:161-167` asserts `isGroupLike`; row hardcoded `isDm: false` at `:173-181`; only `attachGroup` is wired).
- Group-gated endpoints (`requireGroup` → 400 on DM): `name`, `permissions`, `profiles`, `profile`, `metadata`, `description`, `last-read-times`, `profile-image`. DM-safe (`requireConversation`): all of `messages/*` (text, reply, reaction, attachment, remote-attachment, **read-receipt**), `members`, `conversation`.
- No consent machinery exists at all: nothing calls `updateConsentState`; group joins ride the inviter's `addMembers`.
- `catchUpDms` skips DMs with no cursor row (`stream.ts:670-691`) — fresh DM welcomes are invisible even to catch-up.

### Worker + runtime (convos-assistants)

- Single-conversation pinning end to end: DO stores one `herald_conversation_id` (`durable-objects/assistant/migrations.ts:22`, `assistant-store.ts:237-243`); container env `HERALD_CONVERSATION_ID` (`hermes-env.ts:225-226`); Hermes hard-requires one id at start and keys the session to it (`runtime/hermes/src/convos/channel.py:1642-1665`, `HERMES_SESSION_CHAT_ID = conversation_id`); all outbound sends pinned to the stored id (`durable-objects/assistant/herald-helpers.ts:84-172`).
- Inbound: Herald group stream → HMAC webhook → `POST /api/webhooks/herald/:instanceId` → DO enqueue → container drain (`api/webhooks/herald.ts:41-208`).
- Identity: `buildJoinIdentity` (`workflows/create-assistant-workflow.ts:536-577`) rides the attach/join profile publish; the runtime republishes attestation every 12h via `update_profile` (`runtime/hermes/src/convos/herald/runtime.py:362-404`) which hits the **group-only** Herald profile endpoint.
- Teardown is keyed to group removal: `router.ts:445-458` emits `removed_from_conversation` from `group_updated` removedInboxes; `api/webhooks/herald.ts:121-145` dispatches the destroy workflow on self-removal. No DM equivalent exists; Herald's `leave` refuses DMs (`api/conversation/leave.ts:50-56`).
- Hermes has no `channel_id` field in its message schema (confirms the ticket).

### Backend (convos-backend)

- Stateless control plane for agents: **no agent Prisma model**; instances live in the runtime's D1. `POST /v2/agents/join` requires exactly one of `slug`/`conversationId` (`api/v2/agents/handlers/join.ts:91-126`).
- Billing is per-owner-account only: turns are charged to the `ownerAccountId` captured at join via `POST /v2/accounts/:accountId/credits/transactions` under the shared `X-Agent-API-Key` (`api/v2/index.ts:89-94`). No per-conversation attribution, no participation verification, no per-conversation spend cap.
- Backend has **no inboxId↔account mapping** and no membership data — it cannot police DM participation. Policy must live where the on-network state is: the worker + Herald.
- Notifications are conversation-kind-agnostic: XMTP DMs ride `g-<groupId>` topics like groups (`src/notifications/topics.ts:4-8`). Push "just works."

### iOS (convos-ios, dev)

- **No user-facing DM feature is merged.** The `dm-single-inbox.md` plan is unbuilt; "1:1" is a 2-member group (`ConversationsRepository.swift:190-205`, `composeOneToOne` requires `COUNT(*) = 2`). No `allows_dms`, no `dm_links`, no ConvoRequestManager.
- DM transport exists and is production-tested internally: `XMTPClientProvider.findOrCreateDm(with:disappearingMessageSettings:)` (`Messaging/XMTPClientProvider.swift:86-96,177-180`), used by device pairing and invite join-requests. `.dm` kind hydrates and renders (`Conversation.swift:206-211` etc.).
- The insertion point is explicit: `ContactDetailView.swift:340-369` — `canSendMessage` deliberately disables the Chat CTA for verified agents with the comment "doesn't accept 1:1 DMs today." Template agents route to *new group + new instance* (`handleChatWithAgentTemplate` :642), which is not what CON-761 wants.
- Agent verification is complete and reusable: attestation in profile metadata keys `attestation`/`attestation_ts`/`attestation_kid` (`Storage/Models/Profile.swift:111-113`), `AgentAttestationVerifier` (Ed25519 over inboxId, 24h max age), `AgentKeyset` JWKS from `.well-known/agents.json`, `AGENT_DEBUG_JWKS` override for local dev.
- The agent's inboxId is already known client-side wherever it matters: as a member of the group (member list) and from provisioning (`AgentJoinResponse.inboxId`, `SessionManager.awaitProvisionedAgentInbox` :1571-1614).
- Push topic machinery has the exact pattern to copy: `PushTopicSubscriptionManager.subscribeToInviteDMTopic` / `unsubscribeFromInviteDMTopic`.

## 4. Architecture

```
                         ┌────────────────────────────────────────────────┐
                         │  Agent instance (one Herald inbox, one DO,     │
                         │  one Hermes session)                           │
                         │                                                │
  Group (primary) ───────┤  primary_conversation_id                       │
  member A ──DM──────────┤  dm: convA  (peer_inbox_id = A)                │
  member B ──DM──────────┤  dm: convB  (peer_inbox_id = B)                │
                         └────────────────────────────────────────────────┘

DM creation (happy path):
1. iOS: member taps Chat on the agent's contact card (scoped to the group)
   -> findOrCreateDm(agentInboxId) -> sends first message
2. Herald DM stream observes the new DM + message (consent Unknown)
   -> webhook `dm_request` { conversation_id, peer_inbox_id, message } to worker
3. Worker policy: peer_inbox_id ∈ current members of primary conversation
   (GET /v1/conversation/:primary/members — on-network truth, no account
   mapping needed)
   -> pass: worker calls Herald `PUT /v1/conversation/:id/consent {allowed}`
      + registers the DM in its conversations table + enqueues the message
   -> fail: worker calls consent {denied}; Herald never delivers again;
      silent to the sender (matches the user-DM silent-deny philosophy)
4. Agent replies; DO routes outbound to the DM's conversation_id
5. Ongoing: Herald delivers only consented conversations; downstream trusts
   Herald (Nick's option 1)

Revocation:
- group_updated (member removed) -> worker matches removedInboxes against
  its DM registry -> consent {denied} + status=revoked + context marker
- reconciliation sweep (cron, e.g. hourly): diff DM registry peers vs
  current primary members; deny any orphans. Two independent layers.
```

## 5. Design decisions in detail

### 5.1 DM transport: native XMTP DM (D4)

Recommended: the user calls `findOrCreateDm(agentInboxId)` — a real XMTP DM, not a 2-member group.

For: matches Nick's framing throughout the ticket ("Herald is added to a DM", "inbound DM requests"); aligns with the future user-DM design (`dm-single-inbox.md` is native-DM based, so agent DMs pioneer the shared infrastructure instead of diverging); DM uniqueness per (user, agent-inbox) pair is free via XMTP stitching — no duplicate-DM bookkeeping; iOS `.dm` rendering already exists; the peer cannot add members by construction (no lock-the-group work).

Against (and why acceptable): Herald's group-only gates (attach, profile endpoints) need DM variants — but the DM stream + `is_dm` schema already exist, and the profile endpoints just need `requireGroup` relaxed to `requireConversation` where semantics allow (§6.1). Teardown has no `removed_from_conversation` — but our teardown lever is consent (§5.5), which is strictly better anyway.

Documented fallback: a locked 2-member MLS group ("DM-shaped group") would make every Herald group path work unchanged and matches how iOS models 1:1s today. If the spike's protocol validation (§9, S1-S3) surfaces XMTP DM issues (welcome observation latency, consent semantics under stitching), we switch: same policy layer, same worker registry, only the transport and iOS creation call change. We do not build both.

Note: each agent instance registers its own inbox, so instance destruction + recreation yields a new inboxId and a fresh DM — no stitching collisions across instances.

### 5.2 Acceptance policy: consent-driven, worker-owned (D3, D5)

Nick's three options, evaluated against the research:

1. **Consent drives delivery; webhook on DM welcome; worker allowlists** — chosen. Herald gains two generic primitives (a `dm_request` webhook event and a consent endpoint) and zero business logic. The worker owns policy — the same place that already owns lifecycle, billing hooks, and the destroy workflow. Crucially, consent doubles as the revocation lever (§5.5): one choke point for accept and kill.
2. Herald trusts all DMs, filter per-message downstream — rejected: every layer downstream must re-derive trust on every message; the "layers of gates" problem the ticket complains about, reborn with more steps. Also leaves denied peers consuming stream/webhook resources forever.
3. Herald auto-accepts DMs from accepted-group co-members — rejected per Nick's own note: bakes app policy into Herald. Also Herald would need to know which group is "primary" — an application concept.

Policy check detail: membership is verified from **on-network state** (Herald's member list for the primary conversation), never from caller claims. The backend cannot participate (no inboxId↔account map — §3) and doesn't need to. The check re-runs per DM welcome, is idempotent per peer (stitching can deliver multiple welcomes for one logical DM — reuse the recorded decision, mirroring the receiver-decision-function idempotence in `dm-single-inbox.md`).

Sender-side gating (iOS) hides the CTA when the viewer isn't a current co-member, but the worker check is the enforcement; the CTA is UX.

### 5.3 Session model: one Hermes session + channel metadata (D1, D2)

Per the ticket thread: one Hermes sessionID; every message entering the transcript carries a channel header. Hermes has no `channel_id` field, so the worker/DO owns the mapping and the delivery path injects a prefix, per Nick's sketch:

```text
[Channel: dm-3f9a] [Kind: dm] [Participants: Alice, <agent>]
<message text>
```

Implementation choices within that:
- **The conversation registry lives in the DO** (new SQLite table, §6.2) — conversation_id, kind, peer_inbox_id, status, label. The label (`dm-3f9a`) is short and stable so the model can refer to channels cheaply.
- **Prefix injection happens at DO→container delivery** (`herald-helpers.ts` / the drain path), not in Herald and not in Hermes — the layer that owns the registry stamps the header. Group messages get a header too (`[Channel: main]`) so the model never has to infer defaults.
- **Outbound routing**: replies target the channel of the message being handled. The agent's send tools gain an optional `channel` parameter defaulting to the triggering channel; the DO validates the target against the registry (an agent must never be able to send to a revoked channel — enforced at the DO, not by prompt).
- Memory files, cron/scheduled work, and self-initiated sends default to the primary channel unless explicitly targeted.

### 5.4 Channel-aware runtime (the ticket's `Map<String, Map<String, String>>` work)

Inventory of single-conversation state to make per-channel, all in `runtime/hermes/src/convos/` and the DO:

- **Interruption management + burst buffers**: keyed by conversation. A burst in DM-A must not interrupt or merge with a burst in the group. (`channel.py` — the buffering/interruption logic around the session event loop.)
- **Delivery cursors**: per conversation (Herald already cursors per `(accountId, conversationId)` — the runtime-side cursors must match).
- **Member lists / metadata cache**: `_refresh_metadata_if_stale` (`runtime.py:412-413`) becomes per-channel; DMs have a fixed 2-member list and no group metadata — skip, don't 400.
- **Read receipts**: send per conversation, batched within a conversation only (the ticket calls this out; Herald's read-receipt endpoint is already DM-safe).
- **Attestation republish**: the 12h `update_profile` refresh (`runtime.py:362-404`) targets the primary group today. Extend to also publish into each active DM (needs the Herald profile endpoint relaxed, §6.1) so the verified badge renders in DMs (§5.8).
- **Prompt updates**: rules written for one thread ("don't send more than two messages in a row unless tagged") become per-channel rules; add channel-behavior guidance (see §5.6 for the confidentiality rules). Response-discipline evals extend across channels (§9).
- **Renames** (D9): `HERALD_CONVERSATION_ID` → `PRIMARY_CONVERSATION_ID` (env), `herald_conversation_id` → `primary_conversation_id` (DO store), `assistants.conversation_id` → semantic "primary" (D1). Keep read-side aliases for one deploy cycle; the direct-add cross-repo deploy order (worker → backend → apps) is the template.

### 5.5 Revocation: two independent layers (D6)

The ticket's hardest requirement: "when a user is removed from a conversation we need to invalidate its DM session with the agent or we have a serious privacy problem."

- **Layer 1 — event-driven (seconds):** Herald already emits `group_updated`-derived events for the primary group. The worker's webhook handler, on member-removal events, matches `removedInboxes` against the DM registry and for each hit: Herald consent → `denied` (delivery stops at the source), registry status → `revoked`, and a system marker into the session transcript (`[Channel dm-3f9a revoked: peer left the group]`) so the model stops addressing that channel.
- **Layer 2 — reconciliation sweep (bounded staleness):** a scheduled job (piggyback the DO alarm cadence or worker cron, e.g. hourly) fetches current primary members and denies any registry peer not in the set. Catches missed webhooks, Herald restarts mid-stream, and any ordering races. The sweep is idempotent and cheap (one members call + registry diff).
- **Failure posture:** consent-denied is enforced *upstream* of the agent (Herald won't deliver), so even a confused model cannot respond to a revoked peer; the DO's outbound validation (§5.3) blocks the reverse direction. Prompt-level behavior is a nicety on top, not the enforcement.
- The revoked DM's *past* content remains in the transcript — same standing as the group history the member saw while present. What's cut off is the live channel. (Called out in §5.6 and for product sign-off.)
- iOS: the revoked user's DM goes quiet (their sends are never delivered; no error). Acceptable v1; a tombstone UX ("this agent is no longer available") is a fast-follow candidate, likely driven by the agent sending a final system-style message before consent flips — decide in design review.

### 5.6 Confidentiality stance: shared brain, disclosed (D7 — needs product sign-off)

One transcript means member A can try to extract what member B told the agent privately. Prompt rules cannot make an LLM keep secrets against a motivated extractor — we must not pretend otherwise.

Proposed stance for v1:
- **Product framing: the agent is the group's agent.** Its memory is shared across the group and all its DMs. The DM is private *from other members reading it directly*; it is not private *from the agent's shared memory*.
- **Disclosure in UI**: one line in the DM header/first-open state: "This agent shares memory with [group name]." Copy pass needed; the `dm-single-inbox.md` "profiles are display, not identity" section is the precedent for naming a property honestly instead of patching it.
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

- **`accepts_dms`**: runtime versions that support DMs publish `accepts_dms: true` in the agent's ProfileUpdate metadata for the primary group (the same additive-metadata-map pattern as the planned user `allows_dms` bit; old clients/instances simply lack the key). iOS gates the Chat CTA on: verified agent AND `accepts_dms` AND viewer is a current co-member AND feature flag. No key → CTA stays hidden — old agent instances are automatically excluded.
- **Attestation in the DM**: on DM attach, the worker publishes the agent's profile+attestation into the DM (same `buildJoinIdentity` payload; requires the Herald profile endpoint relaxed to `requireConversation`, §6.1), and the 12h refresh includes active DMs (§5.4). iOS then renders the verified badge in the DM with zero new crypto — `AgentAttestationVerifier` doesn't care about conversation kind.

### 5.9 Lifecycle

- **Primary group destroyed / agent removed** → existing destroy workflow runs; add a fan-out step: deny consent on all registry DMs (and optionally a farewell message per DM before the flip — design call). DMs die with the instance; the iOS side sees a quiet conversation.
- **DM-side exit**: users can't "remove" an agent from a DM (Herald `leave` refuses DMs, and there's no admin). V1: deleting the DM client-side + the agent's inactivity handling is enough; the container already sleeps on idle, and Herald streams are cheap. A user-initiated "end DM" affordance can send a control message the worker interprets as consent-deny — fast-follow, not v1.
- **Explode**: DMs with agents don't participate in explode (explode is remove-all-then-leave, group-only — `ConversationExplosionWriter`). When the primary group explodes, the destroy fan-out above covers the DMs.

## 6. Work breakdown by repo

Deploy order mirrors direct-add: **herald-lite → convos-assistants → convos-ios** (backend has no required v1 changes). Every stage is backward-compatible; old agents without `accepts_dms` never see the feature.

### 6.1 herald-lite

1. **DM welcome/request webhook**: extend the DM lane (`stream.ts:611-642` + `handleDmMessage`) to emit a `dm_request` event (conversation_id, peer_inbox_id, first message) for DMs in `Unknown` consent, and route consented-DM messages through the same routing as `handleGroupMessage` (the mirror the comment at `stream.ts:714-719` anticipates). Bootstrap cursor rows for new DMs so `catchUpDms` (`stream.ts:670-691`) stops skipping them.
2. **Consent endpoint**: `PUT /v1/conversation/:id/consent { state }` wrapping `updateConsentState`. Delivery honors consent: `denied` conversations are not streamed/dispatched. This is the accept AND kill switch.
3. **DM attach**: either extend `/v1/conversations/attach` with a `kind: "dm"` mode (drop the `isGroupLike` assert path, insert `isDm: true`, wire the DM lane) or make consent-allow imply attachment for DMs. Decide during implementation; the latter is less API surface.
4. **Relax profile publish to DMs**: `profile.ts` (and only what's needed — not `permissions`/`name`/`description`, which are genuinely group-only) from `requireGroup` to `requireConversation`, so attestation republish works in DMs. `members.ts` is already DM-safe for the policy check.
5. **Read receipts**: already conversation-scoped at the endpoint level; verify the streamer's receipt batching batches per conversation (ticket item).

### 6.2 convos-assistants (worker)

1. **Conversation registry**: DO SQLite migration — `conversations(conversation_id, kind, peer_inbox_id, status, label, attached_at, budget fields)`. Primary conversation becomes row zero; `herald_conversation_id` → `primary_conversation_id` with a read alias (D9).
2. **Policy module**: handle `dm_request` webhooks — membership check via Herald members list on the primary conversation, idempotent per peer, then consent-allow + registry insert + profile publish into the DM, or consent-deny. All decisions logged/metric'd.
3. **Revocation**: member-removal webhook handling (extend `classify.ts` / `api/webhooks/herald.ts:121-145` neighborhood) + the reconciliation sweep on the DO alarm; destroy-workflow fan-out (§5.9).
4. **Outbound plural**: `herald-helpers.ts` send/reply/receipt take a conversation_id from the registry (validated) instead of the single pinned id.
5. **Channel header injection** at delivery into the container; send-tool `channel` parameter surfaced to the runtime.
6. **Spend caps** (§5.7) checked in the drain path before generation.

### 6.3 convos-assistants (Hermes runtime)

1. Remove the single-conversation assertion path where it blocks (`channel.py:1642-1665` keeps requiring a *primary* id; DMs arrive as additional channels, not at `start`).
2. Per-channel interruption/burst/cursor/member-list state (§5.4).
3. Attestation/metadata refresh loop iterates active channels, skipping group-only calls for DMs.
4. Prompt updates: channel-awareness rules + confidentiality etiquette (§5.6); read-receipt behavior per channel.

### 6.4 convos-ios

1. **Flip the CTA**: `ContactDetailView.swift` `canSendMessage` — enable Chat for verified agents when `accepts_dms` is present and the viewer shares the conversation (`.scopedToConversation` mode); route to `findOrCreateDm(agentInboxId)` + open the conversation. The agent's inboxId comes from the member list.
2. **`accepts_dms` plumbing**: read the metadata key through the existing profile pipeline (additive map — no proto change, same pattern as the planned user `allows_dms`).
3. **Push topics**: subscribe the agent-DM topic on creation (copy the `subscribeToInviteDMTopic` pattern into a durable variant); NSE needs no changes (DMs ride `g-` topics; welcomes for a known DM are already deduped by conversation).
4. **UI**: shared-brain disclosure line (§5.6); DM list row renders via existing `.dm` kind handling; verified badge renders from the DM's own profile messages (§5.8).
5. **QA doc** under `qa/tests/` covering create/deny/revoke flows (see §9).

### 6.5 convos-backend

No required v1 changes. Optional fast-follows: per-conversation ledger scope (§5.7); a `dm` capability surfaced on agent-template metadata if the gallery ever wants "DM-able" filtering.

## 7. Phasing and PR sequencing

- **Phase 0 — protocol validation spike** (throwaway code, local stack): S1 confirm Herald's DM stream observes a fresh iOS-initiated DM to an agent inbox end-to-end and measure welcome→observation latency; S2 confirm `updateConsentState(denied)` stops delivery and survives peer re-sends + a second installation (stitching); S3 confirm a ProfileUpdate sent into a DM renders + verifies on iOS. Exit criteria: all three demonstrably true, latency acceptable (< ~10s to first response wake). *This closes CON-761 with a viability verdict and hard numbers.*
- **Phase 1 — Herald primitives** (§6.1): dm_request webhook, consent endpoint, DM routing, profile relax. Independently deployable; nothing consumes it yet.
- **Phase 2 — worker registry + policy + revocation** (§6.2 items 1-3): agent accepts/denies DMs but replies still land via the primary-channel path — internal testing via CLI/local stack.
- **Phase 3 — runtime channel-awareness** (§6.2 items 4-6, §6.3): full multi-channel behavior behind an instance-level flag; evals run here.
- **Phase 4 — iOS surface** (§6.4) behind a feature flag; internal dogfood on the local stack + dev network.
- **Phase 5 — hardening**: reconciliation sweep soak, spend-cap tuning, leakage eval gate, TestFlight.

Within each repo, stack PRs per the standard checkpoint conventions (plan PR first — this document).

## 8. Privacy & security review points

- **Removed-member lockout** is enforced by consent upstream of the model (two layers, §5.5) — not by prompting. Verify in QA: removed member's DM sends are never delivered, and the agent cannot be tricked into sending to a revoked channel (DO-validated).
- **Cross-DM/adversarial extraction** is *not prevented*, it is disclosed (§5.6) and measured (§9). Product/safety must sign off on that stance explicitly.
- **Non-member DM attempts** (anyone with the inboxId): silently denied by policy; peers learn nothing (matches user-DM silent-deny philosophy). Watch webhook volume metrics for denial spam; Herald-side denial means no repeat cost after the first decision.
- **Spend abuse** by legitimate members: capped per §5.7; alert on cap hits.
- **Attestation in DMs** keeps the verified-agent trust story intact outside the group context (no unverified look-alike agents in DM lists).

## 9. Testing & evals

- **Unit/integration**: Herald DM routing + consent honoring; worker policy decision table (member/non-member/removed/re-added/second-installation); revocation sweep idempotence; DO outbound validation against revoked channels.
- **E2E on the local stack**: scripted flow — create group + agent, DM from member (accepted), DM from non-member (silent deny), remove member then DM (denied within sweep interval), re-add member (fresh request re-evaluated). Codify as a QA doc in `qa/tests/`.
- **Evals (extend the existing response-discipline suite)**: channel confusion (does the agent reply in the right channel; does it address the right person); response discipline across channels (the "two messages in a row" rule per channel); cross-channel leakage (benign + adversarial extraction attempts, §5.6); DM cold-open quality (first DM turn should show it knows the group context — the payoff of single-session).
- **Metrics for rollout**: DM request accept/deny counts, welcome→first-reply latency, revocation event→consent-deny latency, sweep catches (should trend to zero), spend-cap hits, leakage-eval scores per runtime release.

## 10. Open questions

1. **Product sign-off on the shared-brain stance** (§5.6) — the one decision that could reshape the architecture; needed before Phase 3.
2. Revoked-DM UX on iOS: silent-quiet vs tombstone message (§5.5) — design review.
3. Farewell message before consent-deny on destroy/revoke (§5.9) — nice or noise?
4. `accepts_dms` granularity: per-instance bool (v1) vs owner-configurable toggle in the builder — builder UI implications.
5. Does the reconciliation sweep cadence need to be tighter than hourly for the privacy bar? (Layer 1 handles the common case in seconds; the sweep only bounds the miss window.)
6. Group spinoff interaction: when user DMs land (`dm-single-inbox.md`), do agent DMs and user DMs share the home-list origin-context treatment? (Likely yes — "Agent from Book Club" — but that plan owns the label design.)
