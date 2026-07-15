# ADR 014: Idempotent Agent Join

> **Status**: Proposed (2026-07-02).
> **Scope**: Cross-repo decision driven by the iOS/messaging team. Client
> changes land in `convos-ios`; the passthrough lands in `convos-backend`; the
> deduplicating change lands in `convos-assistants`.

## Context

Creating an agent occasionally produces **two back-to-back agents with the same
name**: the first is orphaned (typically stuck retrying herald-attach and
surfaced as a failed join), the second succeeds. It is largely invisible to
users but pollutes agent-provisioning success metrics. It is triggered when the
app is backgrounded mid-generation and returns during the join phase.

An agent build is three calls:

1. **Generation** — `POST /v2/agent-templates/generations` returns a
   `generationId` immediately; the client polls to `done`, yielding a
   `templateId`. Already retry-safe (it takes an `idempotencyKey`).
2. **Join / provision** — `POST /v2/agents/join` with `templateId` +
   `conversationId` provisions an agent instance and returns an `instanceId`.
3. **Join-status poll** — `GET /v2/agents/join/:instanceId`, keyed on
   `instanceId`.

The failure we observe on the client is:

```
POST /v2/agents/join threw before returning an instance: NSURLError - The request timed out.
```

That is `NSURLErrorTimedOut` (-1001), raised by URLSession when the join POST's
35s request timeout elapses / the connection is torn down on app suspension —
**before** an `instanceId` comes back. Two facts make this unfixable on the
client alone:

- The request reached the server, so the backend may already have provisioned an
  agent. The client cannot distinguish "provision failed" from "provision
  succeeded, response lost."
- A join is pollable only by `instanceId`, which is delivered solely in that lost
  response. The client has no handle to the orphan, so its only recovery is to
  POST again — creating a second instance.

An iOS-side resume fix was tested (persist `agentInstanceId` once the POST
returns it; resume on retry). It closes interruptions that happen **after** the
id is returned, but not this one — the POST times out **before** returning an
id, so nothing is persisted and the retry re-provisions. Reproduced with the
resume fix in place.

No client-side lever closes the remaining window: a longer timeout does not
survive suspension; a background `URLSession` could complete the POST but still
cannot un-create a duplicate once a connection dropped mid-request. The
ambiguity can only be resolved by the server, which sees the request and owns
the instance.

## Decision Drivers

- [x] Stop duplicate provisions so the agents page / success metrics reflect one
      instance per build.
- [x] Make the join retry-safe across lost responses (backgrounding, timeout,
      dropped connection) — the actual failure mode.
- [x] Do not break shipped iOS builds. The join request contract must stay
      backward-compatible (any new field optional + tolerated when absent).
- [x] Preserve the future ability to add multiple same-template agents to one
      conversation — do not bake in a uniqueness constraint.
- [x] Minimal new infrastructure; prefer reusing existing identifiers and
      persistence over new tables/columns.

## Decision

Introduce a **join idempotency key**: a client-minted, stable identifier sent on
every retry of a given join. The assistant service deduplicates on it and
returns the already-provisioned instance instead of creating a new one.

Chosen over **natural-key dedup** on `(ownerAccountId, conversationId,
templateId)` because natural-key is a uniqueness constraint (forecloses
intentional duplicates), needs `conversationId` written at instance-create time
(today it is `NULL` until join), and models identity rather than retry-safety.
The idempotency key directly models "this is a retry of one create," matches the
generation endpoint's existing `idempotencyKey`, and keeps duplicates possible.

Key design points:

1. **The key is the assistant instance id.** In `convos-assistants`,
   `POST /api/assistants` calls `CREATE_ASSISTANT_WORKFLOW.create({ id:
   idempotencyKey, params })`. Cloudflare Workflows enforces instance-id
   uniqueness, so a duplicate create throws → catch, `get(id)`, return that
   instance. This gives dedup with **no new D1 column and no race window** (the
   Workflows engine serializes concurrent creates). Today the instance id is a
   Cloudflare-auto-generated v4 UUID; the client simply supplies it instead.
2. **The key is a lowercase v4 UUID.** Instance ids are lowercase today
   (Cloudflare auto-ids are lowercase; `db/assistant.ts` admin search relies on
   `WHERE instance_id = LOWER(?1)`), and the id flows into the Herald webhook URL
   path and `GET /api/assistants/:instanceId`'s `INSTANCE_ID_RE` validation.
   `Foundation.UUID().uuidString` is **uppercase**, so the client must emit
   `.lowercased()`, and the assistant boundary normalizes to lowercase as the
   authoritative backstop.
3. **Client reuse policy.** Reuse the same key on an **ambiguous** failure
   (`NSURLErrorTimedOut`, connection lost) so the server adopts the in-flight
   instance; mint a **new** key on an **explicit** failure
   (`502 AGENT_PROVISION_FAILED`, or a `failed` poll) so the server provisions
   fresh. This resolves liveness without server-side failure-remap and respects
   Cloudflare retaining terminated instance ids (see Consequences).
4. **Backend is a passthrough.** `convos-backend` accepts an optional
   `idempotencyKey` on the join body and forwards it into the `/api/assistants`
   dispatch; no other logic changes.

## Consequences

Positive:

- One provision per build; the duplicate-agent metric pollution stops.
- The join becomes retry-safe for the real failure mode (lost response), not
  just the narrower post-instance-id window the shipped resume fix covered.
- No new persistence in `convos-assistants` (the Workflows engine is the source
  of uniqueness) and no new persistence in `convos-backend` (stays a proxy).
- The invariant "instance ids are lowercase UUIDs" is enforced for **all**
  callers because normalization happens where the value becomes the id.

Negative / trade-offs:

- Three-repo change (client mint/persist/resend, backend passthrough, assistants
  dedup) rather than a single-repo patch.
- Correctness now depends on the client emitting a **lowercase** UUID; a stray
  uppercase path would produce mixed-case instance ids that break the lowercase
  assumption. Mitigated by a single client factory + tests and server-side
  normalization.
- Cloudflare **retains terminated Workflow instances**, so a key whose instance
  failed cannot be recycled (a same-key retry would `get()` the corpse). This is
  why the client mints a new key on explicit failure; it must be enshrined, not
  assumed.
- The duplicate-create throw is **deployed-engine behavior only**. Miniflare's
  local Workflows shim (used by `wrangler dev` and the vitest workers pool)
  keeps no instance registry: `create()` fire-and-forgets an init onto a
  name-derived Durable Object, swallows its errors, and unconditionally
  resolves `{ id }`, so a duplicate create resolves instead of throwing and
  the dedup branch never executes locally. (Locally the same key maps to the
  same DO, so responses still coincidentally agree.) Consequences: the engine
  contract cannot be integration-tested locally — it is pinned by the
  documented API contract, by handler tests with a mocked duplicate throw,
  and by same-key replay against a deployed environment (dev/staging run the
  real engine; only local dev is simulated). That post-deploy replay check is
  load-bearing, not optional.

Neutral:

- The key is optional end-to-end, so rollout is server-first and shipped clients
  are unaffected (they simply get today's non-deduped behavior until updated).

## Implementation Notes

**`convos-ios`** — Represent the key as a dedicated
`ConvosAPI.JoinIdempotencyKey` type rather than `String` or `UUID`: minting
goes through `JoinIdempotencyKey.mint()` (`UUID().uuidString.lowercased()`),
rehydration validates and lowercases, and the type is unconstructible from
arbitrary strings — so the generation idempotency key (an uppercase UUID on
the same row) cannot be wired in by accident, and Foundation `UUID`'s
uppercase Codable encoding is avoided by design. Persist the raw value on
`DBAgentTemplateGeneration` and resend it on every retry via
`AgentTemplateRepository.invite()` → `requestAgentJoin`. Apply the
reuse-on-ambiguous / new-on-explicit-failure policy. Tests: minted keys are
lowercase v4 UUIDs (regex without `/i`, over many iterations); the type
rejects non-UUIDs and normalizes case on rehydrate; the persisted key and the
encoded wire value are lowercase; reused across an ambiguous-timeout retry and
re-minted on explicit failure. Neighbors the existing
`AgentTemplateRepositoryTests`.

**`convos-backend`** — Add `idempotencyKey: z.string().uuid().optional()` to the
join `bodySchema` (`src/api/v2/agents/handlers/join.ts`) and forward it into the
dispatch body. Optional + tolerated-when-absent per the append-only
request-contract rule; pin the legacy (no-key) shape with
`assertLegacyShapeValidates`. May also lowercase-normalize as an earlier gate.

**`convos-assistants`** — Add `idempotencyKey: z.string().uuid().transform(v =>
v.toLowerCase())` (optional) to `CreateAssistantBodySchema` (`schemas.ts`); when
present, `create({ id: idempotencyKey, params })` and handle the duplicate-id
throw by returning the existing instance via `get(id)`. Normalize to lowercase
here as the authoritative backstop; keep `.uuid()` validation for malformed
input. Tests: the duplicate-id throw cannot be exercised in the local vitest
workers pool (see Consequences), so pin the handler's dedup logic with a
mocked duplicate throw in `api/assistants/index.test.ts`, and pin the `get()`
disambiguation the catch path relies on (known id resolves, unknown id throws)
in `create-assistant-workflow.test.ts`. Verify the real engine contract by
same-key replay against dev after deploy. No schema migration required.

## Alternatives Considered

- **Natural-key dedup** `(owner, conversation, template)` — assistants-only, no
  client change, but bakes in a uniqueness constraint (forecloses intentional
  duplicates) and needs `conversationId` at create time (currently `NULL` until
  `setJoined`). Rejected for flexibility and semantic correctness.
- **D1 `idempotency_key` column + reservation** — more server-side control over
  failure-remap, but adds a table/column and a race window the Workflows-id
  approach avoids. Held as fallback if same-key failure-remap is ever needed.
- **Bump the client join timeout (35s → 60s)** — does not survive app
  suspension, so the reproduced case still fails; only helps genuinely-slow
  foreground responses. Rejected as a fix; at best a marginal mitigation.

## Related Decisions

- [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md)
  (agents join as members of the single-inbox conversation).

## References

- Client join path: `ConvosCore/Sources/ConvosCore/AgentBuilder/AgentTemplateRepository.swift`,
  `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift` (`request.timeoutInterval = 35`).
- Backend join handler: `convos-backend/src/api/v2/agents/handlers/join.ts`.
- Assistants create + instance id: `convos-assistants/workers/assistant/src/api/assistants/index.ts`,
  `.../src/workflows/create-assistant-workflow.ts`, `.../src/db/assistant.ts`
  (`INSTANCE_ID_RE`, lowercase-instance-id assumption).
- UUID format: RFC 4122 / RFC 9562 (v4 = random).
- Workflows `create()` duplicate-id contract:
  https://developers.cloudflare.com/workflows/build/workers-api/ ("an error is
  thrown if the provided ID is already used by an existing instance that has
  not yet passed its retention limit").
- Local simulator gap: miniflare `dist/src/workers/workflows/binding.worker.js`
  (`create()` resolves without a uniqueness check; errors swallowed). Observed
  with miniflare 4.20260625 / `@cloudflare/vitest-pool-workers` 0.16.19.
