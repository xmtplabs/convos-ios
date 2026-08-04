# Agent-owned DM creation — rework spike (CON-761)

> **Status**: Spike / design proposal (draft)
> **Author**: jarod
> **Created**: 2026-08-04
> **Ticket**: CON-761 (Agent DMs)
> **Amends**: [`agent-dms.md`](./agent-dms.md) — this changes **who creates the DM** (D-level change to the flow in agent-dms.md section 4 and section 6.4.2). Everything else in that plan (2-member group transport D4, worker registry + atomic per-peer reserve section 5.2.1, revocation section 5.5, shared-brain section 5.6) is reused unchanged.
> **Spikes**: convos-ios, convos-assistants (worker + herald-lite). Draft PRs are cut against `dev` for a clean review surface; in delivery they stack on the in-flight CON-761 backend branches (herald `conversation_added` observer, worker DM registry/reserve/revocation).

## 1. Why

The shipped client-side eager creator (`AgentDmReconciler`, agent-dms.md section 6.4.2) is causing DM pile-up on Dev TestFlight: it re-attempts DM creation for every verified agent it can't find a *verified* DM with, once per app session, and a failed/partial create (or an agent that left) leaves an orphan the lookup can't see — so a fresh orphan accrues per launch, per agent. See the field report in convos-ios #1274.

The root defect is architectural, not a bug in the loop: **the client both creates DMs and infers their existence from lossy local MLS state** (a 2-member group carrying the marker). Any client is a poor authority here:

- Multiple devices per user each run the loop and race to create the same DM.
- In-memory dedup (`attemptedAgents`) resets on cold launch.
- MLS group creation is inherently non-transactional (create group, then add member), so a mid-flight failure strands a group.
- "Existence" is derived from live membership count, which drops to 1 the moment the agent leaves — indistinguishable from "never created."

#1274 mitigates the *visible* symptom (hidden shells + a cleanup sweep) but leaves the underlying "attempt-per-launch for dead agents, no durable dedup, no backoff, no dead-agent marking" intact — now happening silently.

## 2. The fix: the agent owns DM existence

Flip creation ownership. The DM is fundamentally *"the agent has a channel with each human it shares a group with"* — so the **agent** (server-side, in convos-assistants, acting through its herald-lite XMTP identity) creates and owns the DM. The client stops creating and becomes a pure reflector.

This dissolves the whole bug class rather than mitigating it:

| Failure mode (client-owned) | Under agent-owned |
|---|---|
| N devices race to create | One writer (the agent). Every user device receives the one DM via welcome/sync. |
| Cold-launch resets dedup → recreate | Existence is a durable server registry row, not inferred from local state. |
| Agent left → looks missing → recreate | Registry knows the DM is `revoked`, not missing. Never recreated. |
| Dead agent hammered every launch | Durable backoff + `dead` status in the registry; stop trying. |
| Half-built orphan group | Agent is group admin and creates atomically server-side; a failed create leaves a server-side `pending` row that is retried/cleaned, not a client-visible shell. |
| No verify-before-create | The agent only DMs current members of its own primary group, and it *is* the verified party. Verification is inherent. |

It also **finishes the design already documented**: agent-dms.md section 5.2.1 calls the backend atomic per-peer reserve "the cross-device authority," and section 5.5 already has a server-side *revocation* reconciliation sweep. Agent-owned creation is the symmetric other half — a *creation* sweep — reusing the same registry, reserve, and trigger surface. The client eager reconciler was the interim wrong turn.

## 3. Architecture

```
                        convos-assistants (worker DO)          herald-lite (agent XMTP identity)
                        ┌────────────────────────────┐         ┌──────────────────────────────┐
 primary group  ──────► │ ensureDmsForPrimaryMembers  │ ──────► │ POST /v1/conversations/       │
  member A (human)      │  for each human member w/o   │  create │   create-dm { peer, origin }  │
  member B (human)      │  an active/pending reg row:  │   DM    │  newGroup([peer]) + stamp     │
  agent (herald inbox)  │   1. atomically RESERVE peer │         │  agentDm marker + publish     │
                        │   2. call herald create-dm   │ ◄────── │  profile/attestation          │
                        │   3. pending→active on ok    │  conv_id└──────────────────────────────┘
                        │   backoff + dead on repeated │                     │ welcome
                        │   failure (registry fields)  │                     ▼
                        └────────────────────────────┘         every user device syncs the DM,
                              ▲                                 reads the marker, renders it as a
                              │ triggers                        DM page in the primary's pager.
              conversation_added (primary attached)             iOS creates nothing.
              member_added  (new human joins) [new event]
              DO alarm reconciliation sweep (mirror of revoke)
```

Creation sweep and revocation sweep are two directions of the same registry-vs-primary-members diff, run on the same DO alarm:

- **Revocation (exists):** registry DM peer not in current primary members -> leave + revoke.
- **Creation (new):** current primary human member with no registry DM -> reserve + create.

## 4. Work by repo

### 4.1 herald-lite — one net-new primitive

Herald already holds the agent's XMTP identity and can create conversations (`src/api/conversations/join.ts:135`, `client.conversations.createDm(...)`) and publish profile+attestation on attach (`src/api/conversations/attach.ts:189-195`).

- **New endpoint** `POST /v1/conversations/create-dm { peer_inbox_id, origin_conversation_id }`, registered alongside `attach`/`join` (`src/app.ts:69`, `registerConversationsRoutes`) with a matching method added to the generated `@convos/herald-api-client` (`packages/herald-api-client`): create the 2-member group (agent is admin -> structurally enforces the 2-member invariant), stamp the `agentDm` `ConversationCustomMetadata` marker with `originConversationId`, publish the agent profile+attestation (reuse the attach path, `attach.ts:189-195`), return `{ conversation_id }`. Herald already calls `client.conversations.createDm(peerInboxId)` internally (`join.ts:135`); this exposes that capability over HTTP so the worker DO can drive it. Idempotency: keyed on `(agent, peer)`; if the agent already has a 2-member group with `peer`, return it instead of creating a second.
- **Optional** `member_added` webhook event: today only `conversation_added` (whole-group, on first appearance) carries member ids; incremental human joins to an already-attached group surface as `conversation_metadata_updated` with no ids (herald `router.ts:494`, by design). Add a `member_added` branch in `routeGroupUpdated` reading `content.addedInboxes` (mirrors the committed `member_removed` shape) so a human joining an existing group triggers ensure-DM promptly. Without it, the DO alarm sweep still covers the case, just less promptly.
- Reuses: the `conversation_added` observer + catch-up sweep (already on the CON-761 branch) as the primary-group discovery trigger; `leave` for revocation.

### 4.2 convos-assistants (worker) — the trigger + durable idempotency

The worker `AssistantDO` already owns the DM registry and, crucially, **already runs the exact sweep this rework needs — in the opposite direction**. `reconcileDmConversations` (`durable-objects/assistant/index.ts:1894`) runs on a standing DO alarm (`runPendingDmAttachesSweep`, `index.ts:1722`; 45s while pending, 6h steady-state, `constants.ts` `DM_ATTACH.RECONCILE_DELAY_SECONDS`), loads the **primary group's** live member list via `heraldListMembers` (`index.ts:1904`), and **revokes** DMs whose peer left. Agent-owned creation is the mirror added to that same pass.

- **`ensureDmsForPrimaryMembers(primaryConversationId)`** (inverse of the existing revoke): from the same `heraldListMembers` roster, exclude the agent's own inbox and any non-human members, and for each human with no `active`/`pending` row in `dm_conversation`: call `reserveDmConversation` (`assistant-store.ts:349` — the atomic conditional INSERT keyed on `lower(peer_inbox_id)`, already single-DM-per-peer), then call the new Herald **create-dm** endpoint, then `promotePendingDmConversation` (`assistant-store.ts:316`, pending -> active) on success; on failure `clearPendingDmConversation` + record backoff. This replaces `attachConvosConversation` (`index.ts:1622`) as the primary path: today the DO reserves-then-**attaches** a client-made group; now it reserves-then-**creates**.
- **Triggers**: (a) the reconcile sweep above (add the create-if-missing branch next to the revoke branch); (b) primary-group `conversation_added` / member-add — currently additions to the *primary* aren't acted on for DM creation (`router.ts:461-464`, and the primary branch of `handleMemberRemoved`, `index.ts:1778`), so wire `ensureDmsForPrimaryMembers` there for promptness.
- **Durable backoff + dead-agent** (directly answers the deploy feedback): extend the `dm_conversation` table (append-only migration, `migrations.ts:160`) with `attempt_count` and `next_attempt_at`, and add a `dead` status after N consecutive failures. Durable in DO SQLite — survives cold launch, process restarts, everything (unlike the client's in-memory `attemptedAgents`). The sweep skips `dead` peers.
- Note: the acceptance policy "peer must be a current member of the primary" (`index.ts:1547`, `isPeerInPrimary`) becomes inherent — the loop only ever iterates current primary members. The existing `conversation_added` *attach* path can stay during migration for any straggler client-made groups.
- **Hermes runtime is untouched** — it holds no XMTP identity and creates no conversations (per-turn `inbox_id`/`conversation_id` context only). The DM-lane guardrails (`delivery-drain.ts` `dmLaneLabel`) are downstream of the registry and unaffected by who creates the row.

### 4.3 convos-ios — reduce to a reflector

**Delete** (client no longer creates):
- `ConvosCore/.../AgentBuilder/AgentDmReconciler.swift` + `AgentDmReconcilerTests.swift`
- `ConvosCore/.../Sessions/SessionManager+AgentDmReconciler.swift` and its start at `SessionManager.swift:202`
- `ConvosCore/.../AgentBuilder/AgentDmFlow.swift`
- The DM-page first-send create fallback (`AgentDmPageView.handleDraftSend`) and the `ContactDetailView` "Chat" create path become "open the agent-created DM once it syncs" (a brief pending state), not a create.

**Keep** (the reflector — already built):
- Marker classification (`isAgentDm`), `DBAgentDmOrigin` + the `agentDmOriginConversationId` getter, the pager / `AgentDmPageView` rendering, the `accepts_dms` gate, and the push-notification suppression + tap routing from #1271.

**Reuse for migration**: `StrandedConversationSweeper` (#1274) as a one-time cleanup of the client-created orphans/duplicates already on Dev; after the fleet is clean it can be retired.

## 5. Migration & sequencing

1. **#1274 lands first** as the stopgap (hidden shells + sweeper) — stops active Dev bleeding while the rework is built. Its `commitClaimedConversation` Bool and `awaitReadyConversationId` `.error` fixes are general and survive; its deferred-visibility rework of `AgentDmFlow.createDm` is interim (deleted here).
2. **herald-lite**: `create-dm` primitive (+ optional `member_added`). Independently deployable.
3. **convos-assistants**: `ensureDmsForPrimaryMembers` + triggers + backoff/dead fields, reusing the registry/reserve/revocation from the CON-761 backend work.
4. **convos-ios**: delete client creation; keep reflector; reuse the sweeper as one-time migration.
5. **Cleanup**: run the migration sweep once across Dev to retire the accumulated orphans.

Deploy order matches direct-add: **herald-lite -> convos-assistants -> convos-ios**. Every stage is backward-compatible (old clients simply stop being the creator; the agent takes over).

## 6. Open questions

- **Non-agent-DM 1:1s.** This applies only to agent DMs; user<->user 1:1s keep client creation. The ensure loop is scoped to verified-agent members of the agent's own primary group.
- **Consent on agent-initiated DMs.** Because peer and agent already share a group, the DM should land auto-allowed, not as an unknown/spam request. Confirm the consent state herald sets on `newGroup`-created groups and whether the client needs to auto-allow on the marker.
- **Pending UX.** When a user opens the agent's DM page before the agent-created DM has synced, show a brief pending state rather than creating one client-side. Define the timeout/retry.
- **Backoff cadence + `dead` threshold** (N failures, base/max delay) — pick values; expose as registry fields so support can tune.
- **`member_added` event vs sweep-only.** Decide whether prompt per-join creation is worth the new herald event, or the alarm sweep's latency is acceptable for v1.
