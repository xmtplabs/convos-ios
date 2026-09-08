# Agent-owned DM creation — design + as-built (CON-761)

> **Status**: Merged to `dev` (2026-08-12) across all 5 PRs (below). Sections 1-3 are the design rationale; **section 0 (As-built) is authoritative** for what actually shipped.
> **Author**: jarod
> **Created**: 2026-08-04
> **Ticket**: CON-761 (Agent DMs)
> **Decision record**: [ADR 015 — Agent-Owned DM Creation (iOS Reflector)](../adr/015-agent-owned-dm-creation.md) (iOS) and `convos-assistants` ADR 015 (backend). This plan doc holds the full cross-repo design + build notes.
> **Amends**: [`agent-dms.md`](./agent-dms.md) — changes **who creates the DM** (the flow in agent-dms.md section 4 and section 6.4.2). The 2-member group transport (D4), the DM registry + atomic per-peer reserve (5.2.1), revocation (5.5), and the shared-brain stance (5.6) are reused unchanged.

## 0. As-built (authoritative)

The rework moves agent-DM creation from the iOS client to the agent (server-side). The client stops creating and becomes a pure reflector. Built on **latest `dev`** across all repos (the stale `worker-dm-handling` line, which still used the older `isDmDeliverable` DM-delivery model, was dropped).

**PRs:**
- convos-assistants **#3191** — Herald `create-dm` + `member_added` event; worker `ensureDmsForPrimaryMembers` + durable backoff.
- convos-cli **#116** — `agentDm` marker (field 8) added to the `ConversationCustomMetadata` codec (patch → 0.10.16 via Changesets).
- convos-ios **#1284** — iOS reflector reduction (this PR).
- convos-assistants **#3193** — Bug: classify Herald probe failures by HTTP status, not body substring (#3164 regression).
- convos-assistants **#3195** — Bug: route background-delegation progress badges to the DM, not the group (#3163 follow-up).

**Flow (happy path):**
1. A human is a member of an agent's primary group (agent join, or a later member-add).
2. The worker DO's `ensureDmsForPrimaryMembers` (runs inside the existing `reconcileDmConversations` DO-alarm sweep — the mirror of its revoke pass — and on the new `member_added` webhook) finds each current human member with no `active`/`pending` `dm_conversation` row, skipping the agent's own inbox, in-flight peers, and backed-off/dead peers.
3. For each, guarded by an in-memory per-peer `dmCreateInFlight` set, the DO calls Herald **`POST /v1/conversations/create-dm { peer_inbox_id, origin_conversation_id }`**. Herald (which holds the agent's XMTP identity) `createGroup([peer])` — a 2-member group, agent = admin — stamps the `agentDm` marker via `updateAppData(serializeAppData({ agentDm: { originConversationId } }))` (needs convos-cli's field-8 codec), and returns the conversation id. `findExistingDm` makes it idempotent, reusing only a group that already carries the `agentDm` marker (origin-agnostic: one DM per `(agent, peer)`).
4. The DO `reserveDmConversation(realId, peer)` then runs the **existing** `performDmAttach` (peer-in-primary check, profile/attestation publish, `promotePendingDmConversation`). On failure it clears the reservation and records durable backoff (`dm_create_backoff`: `attempt_count`/`next_attempt_at`/`dead` after N).
5. Every user device syncs the DM, reads `agentDm.originConversationId`, and **deterministically** nests the DM page under exactly that primary group (persisted in `DBAgentDmOrigin`; also drives the #1271 push-tap routing). iOS auto-allows the DM (consent `.unknown` → `.allowed`) gated on the existing `isAgentDm` classification (marker + 2 members + attested verified agent) — a client-side reflector decision, no server consent change.

**Determinism (DM → which group):** the DM group carries `agentDm.originConversationId` = the agent's *primary* conversation id, stamped by Herald at creation. One DM per `(agent, peer)`, anchored to that primary, so iOS resolves the parent group with zero inference. Before the marker syncs, iOS simply doesn't classify/place the DM yet (tolerated).

**Key implementation decisions that emerged during the build:**
- **`member_added` does not short-circuit the metadata path** (router.ts): a pure add emits `member_added`; an add that coincides with a metadata change emits `conversation_metadata_updated` (so the profile/custom-metadata snapshot is never dropped) and the added member still gets its DM via the reconcile sweep.
- **`findExistingDm` requires the `agentDm` marker**, not just any 2-member group with the peer (would otherwise reuse an unrelated group).
- **Concurrency**: create-side is serialized by the worker's per-peer `dmCreateInFlight` (one DO per agent, single-threaded) plus the registry reserve; the Herald endpoint is idempotent via `findExistingDm`.
- **convos-cli is a runtime peer of node-sdk**, so consuming the field-8 codec doesn't double-load node-sdk. The field-8 build is the merge gate: convos-cli 0.10.16 must publish (Changesets) and the assistants catalog bump to it before #3191's `lint-javascript` (an `agentDm`-not-in-type typecheck) goes green.
- **iOS** deleted `AgentDmReconciler` / `AgentDmFlow` / wiring; the two former create call sites now open the agent-created DM if present, else no-op (it arrives via sync).

**Local-stack QA:** brought up non-disruptively via `ASSISTANTS_DIR`/`HERALD_DIR`/`CLI_DIR` overrides pointing at rework worktrees (main checkouts untouched). Fixed en route: a Node-25 `better-sqlite3` ABI rebuild for herald, and the Infisical/`.dev.vars` migration gap (stack tooling writes `.dev.vars`, which the worker rejects) worked around with `.env.local` + `CONVOS_INFISICAL_INJECTED=local`. Backend + herald + worker all come up running the rework code; the agent-creates-DM E2E (create an agent via `/api/assistants` + a convos-cli human, verify the agent auto-creates one marked DM) is the final validation step, run once the worker's Hermes container image finishes building.

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
- **`member_added` webhook event (decided: include)** — this is the per-join creation trigger. Today only `conversation_added` (whole-group, on first appearance) carries member ids; incremental human joins to an already-attached group surface as `conversation_metadata_updated` with no ids (herald `router.ts:494`, by design), so a new member wouldn't get a DM until the next alarm sweep. Add a `member_added` branch in `routeGroupUpdated` reading `content.addedInboxes` (mirrors the committed `member_removed` shape at `router.ts:469-491`) and a `MemberAddedEventSchema` in `webhooks/index.ts` alongside `MemberRemovedEventSchema`. The dispatch plumbing already handles any new payload variant unchanged. The DO alarm sweep remains the backstop for missed events; `member_added` makes the common case (a human joins, gets a DM within seconds) prompt.
- Reuses: the `conversation_added` observer + catch-up sweep (already on the CON-761 branch) as the primary-group discovery trigger; `leave` for revocation.

### 4.2 convos-assistants (worker) — the trigger + durable idempotency

The worker `AssistantDO` already owns the DM registry and, crucially, **already runs the exact sweep this rework needs — in the opposite direction**. `reconcileDmConversations` (`durable-objects/assistant/index.ts:1894`) runs on a standing DO alarm (`runPendingDmAttachesSweep`, `index.ts:1722`; 45s while pending, 6h steady-state, `constants.ts` `DM_ATTACH.RECONCILE_DELAY_SECONDS`), loads the **primary group's** live member list via `heraldListMembers` (`index.ts:1904`), and **revokes** DMs whose peer left. Agent-owned creation is the mirror added to that same pass.

- **`ensureDmsForPrimaryMembers(primaryConversationId)`** (inverse of the existing revoke): from the same `heraldListMembers` roster, exclude the agent's own inbox and any non-human members, and for each human with no `active`/`pending` row in `dm_conversation` (and no `revoked` tombstone): call the new Herald **create-dm** endpoint, then `reserveDmConversation` (`assistant-store.ts:349` — the atomic conditional INSERT keyed on `lower(peer_inbox_id)`, already single-DM-per-peer) and `performDmAttach` -> pending -> active on success; on failure `recordDmCreateFailure` accrues backoff. This replaces `attachConvosConversation` (`index.ts:1622`) as the primary path: today the DO reserves-then-**attaches** a client-made group; now it reserves-then-**creates**.
- **Triggers**: (a) the reconcile sweep above (add the create-if-missing branch next to the revoke branch); (b) the primary group's `conversation_added` (agent first joins a group -> ensure DMs with its existing human members); (c) the new `member_added` herald event (a human joins an already-attached primary -> ensure a DM with that joiner, within seconds). Today additions to the *primary* aren't acted on for DM creation (`router.ts:461-464`, and the primary branch of `handleMemberRemoved`, `index.ts:1778`); `ensureDmsForPrimaryMembers` is the single routine all three call.
- **Durable backoff + dead-agent** (directly answers the deploy feedback): a **separate** `dm_create_backoff` table (append-only migration, keyed on `lower(peer_inbox_id)`) with `attempt_count`, `next_attempt_at`, and a `dead` flag after N consecutive failures. Kept out of `dm_conversation` on purpose: the failure path drops the pending reservation (`clearPendingDmConversation` deletes the `dm_conversation` row), so backoff on that row would be lost — `recordDmCreateFailure` accrues it in its own table, and `isDmCreateBlocked` / the sweep skip backed-off and `dead` peers. Durable in DO SQLite — survives cold launch, process restarts, everything (unlike the client's in-memory `attemptedAgents`).
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

**Consent — auto-allow (decided)**: an agent-created DM arrives at the user's device as a welcome with `unknown` consent. The client auto-allows it only when **both** hold (`ConversationWriter.swift`):

1. `isAgentDm` classification — exactly 2 members, the `agentDm` marker present, the other member an **attested/verified agent**; and
2. a **shared-origin** check (`userStillSharesOrigin`) — the marker's `originConversationId` is still present locally, lists the user as a current member, and carries no recorded departure (`member_departure`).

Otherwise the DM keeps its synced `unknown` consent and surfaces as a normal request rather than silently allowed. The marker is member-writable appData, so the origin check is what stops a verified agent from opening an auto-allowed DM without a shared primary — or one whose primary the user has since left or deleted. Consent stays a client-side reflector decision (no server consent change).

**Reuse for migration**: `StrandedConversationSweeper` (#1274) as a one-time cleanup of the client-created orphans/duplicates already on Dev; after the fleet is clean it can be retired.

## 5. Migration & sequencing

1. **#1274 lands first** as the stopgap (hidden shells + sweeper) — stops active Dev bleeding while the rework is built. Its `commitClaimedConversation` Bool and `awaitReadyConversationId` `.error` fixes are general and survive; its deferred-visibility rework of `AgentDmFlow.createDm` is interim (deleted here).
2. **herald-lite**: `create-dm` primitive + `member_added` event. Independently deployable.
3. **convos-assistants**: `ensureDmsForPrimaryMembers` + triggers + backoff/dead fields, reusing the registry/reserve/revocation from the CON-761 backend work.
4. **convos-ios**: delete client creation; keep reflector; reuse the sweeper as one-time migration.
5. **Cleanup**: run the migration sweep once across Dev to retire the accumulated orphans.

Deploy order matches direct-add: **herald-lite -> convos-assistants -> convos-ios**. Every stage is backward-compatible (old clients simply stop being the creator; the agent takes over).

## 6. Decisions & open questions

Decided:

- **Consent — auto-allow.** The agent-created DM lands allowed on the user's device because the other member is an already-known **agent contact** (verified agent from a shared group). Client-side reflector decision on the existing contact/verified-agent check; no server consent change. See section 4.3.
- **`member_added` event — include it.** Add the `member_added` herald webhook so a human joining an already-attached primary gets a DM within seconds; the alarm sweep stays as the backstop. See section 4.1 / 4.2 trigger (c).

Open:

- **Non-agent-DM 1:1s.** This applies only to agent DMs; user<->user 1:1s keep client creation. The ensure loop is scoped to verified-agent members of the agent's own primary group. (Scoping note, not a blocker.)
- **Pending UX.** When a user opens the agent's DM page before the agent-created DM has synced, show a brief pending state rather than creating one client-side. Define the timeout/retry.
- **Backoff cadence + `dead` threshold** (N failures, base/max delay) — pick values; expose as registry fields so support can tune.
