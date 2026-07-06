# Agent Builder Flow Simplification — Phase 4 detail

Phase 4 = **connections** for the direct builder: let a build declare the
services the agent should use (e.g. Google Calendar, Apple Health), so the
generated template is aware of them, and the actual authorization grants fire
after the agent joins.

Context and earlier phases live in `agent-builder-flow-simplification.md`;
media inputs are in `-phase-3.md`. The backend contract is in
`docs/plans/agent-generation-api.openapi.yaml`.

**Status: planned.** Backend PR **#311** (CON-532) is merged/deployed on Dev.

## The two halves (they are independent)

Connections split cleanly into two unrelated mechanisms; both are needed for a
useful result, but they touch different code:

1. **Generation-time awareness (`connections[]`, PR #311).** The request carries
   a list of neutral service ids (e.g. `["googlecalendar"]`). The backend
   validates them against the catalog, makes the generated prompt/welcome lean
   on the capability, and reflects them in the template's `connections` array.
   **No grant is issued here** — stamping a connection grants nothing; it's
   metadata that shapes the generated agent.

2. **Post-join authorization grants.** After the agent joins the conversation,
   the real per-agent grant is issued (cloud grant via `createConnectionGrant`,
   or a device `EnablementStore` write). This is the existing legacy machinery
   and is **completely separate** from #311.

## Key realization — the post-join half is already built

The main plan's earlier note ("post-join grants need a new driver keyed off the
`AgentTemplateRepository`, because the legacy replayer keys off the XMTP
`AgentBuilderSummary` the direct flow never writes") is **out of date**. Since
Phase 2, the direct flow **does** persist an `AgentBuilderSummary` (the
creation-prompt card, via `persistCreationPromptCard` ->
`agentBuilderSummaryWriter().save`).

And the legacy `AgentBuilderConnectionGrantReplayer`:

- is **already started for every session** (`SessionManager.swift:157` calls
  `agentBuilderConnectionGrantReplayer()`, which `.start()`s it),
- observes **all** `DBAgentBuilderSummary` rows (not just legacy ones) joined
  against verified agent members (`DBMemberProfile`),
- for each summary `.connection` attachment, fires the device
  (`EnablementStore`) or cloud (`grantWriter.grantConnection`) grant to every
  verified agent inbox, then stamps `connectionsAppliedAt` to prevent re-fire.

So the direct flow gets post-join grants **for free** the moment its summary
carries the connection attachments + `cloudConnectionIds` — no new driver, no
new observation loop, no new idempotency marker. We just have to populate the
summary we already write.

## Backend contract (PR #311)

`GenerationRequest` gains an optional `connections: string[]`:

- Bare **neutral service ids** (`googlecalendar`), no `composio:` prefix.
- Validated against the catalog (`GET /connections/services`); unknown id ->
  `400`.
- Part of the **idempotency dedupe** body; omitted compares equal to a stored
  `[]`, and ids are normalized/deduped (`["GoogleCalendar","googlecalendar"]` ->
  `["googlecalendar"]`) before comparison. Persist what we send so resume/retry
  stays stable.
- Awareness only: appended as a capabilities directive to the generator and
  overlaid onto `template.connections`. No grant, no privilege gate.

## Part 1 — generation-time `connections[]`

Map the composer's enabled connections to **cloud** neutral ids and send them.

- **Map**: `enabledConnections.compactMap { $0.cloudServiceId }` —
  `AgentBuilderConnection.googleCalendar.cloudServiceId == "googlecalendar"`;
  `appleHealth.cloudServiceId == nil`. **Device connections are not sent** —
  they aren't catalog services, so sending `"appleHealth"` would 400. (Apple
  Health still gets its post-join device grant; it just has no generation-time
  awareness via #311.)
- **API**: thread `connections: [String]` through
  `createAgentTemplateGeneration` (protocol + `ConvosAPIClient` +
  `MockAPIClient` + test stub default + the two fixtures + the throwing
  protocol-ext default) into the request body's `connections` (omit when
  empty, like `attachments`).
- **Repository**: `startGeneration` gains `connections: [String]`; persist on
  the row (new nullable `connections` JSON column + additive migration, mirrors
  the `attachments` column) so a resumed/retried submit sends the identical
  body and dedupes instead of `409`ing. `submit` reads them and passes them on.
- **VM**: `startDirectGenerationIfReady` computes the cloud ids from
  `enabledConnections` and passes them to `startGeneration`.

## Part 2 — post-join grants (reuse the existing replayer)

Populate the direct flow's summary so the already-running replayer fires the
grants. In `AgentBuilderViewModel` at Make (the direct path), mirror what the
legacy `commit()` does:

- Build `.connection(id:identifier:)` summary attachments for every enabled
  connection (device + cloud), reusing the existing `buildSummaryAttachments`
  helper (or its connection branch). `identifier` is the
  `AgentBuilderConnection.rawValue` (`"appleHealth"` / `"googleCalendar"`).
- Snapshot `cloudConnectionIds: [rawValue: CloudConnection.id]` from the VM's
  `capturedCloudConnectionIds` (already populated by `toggleConnection` /
  the OAuth kickoff) and pass it into the `AgentBuilderSummary` the direct flow
  persists (`persistCreationPromptCard` currently hardcodes `[:]` / no
  connection attachments).

That's the whole change for Part 2. The replayer then:

- waits until a verified agent is a member of the conversation,
- fires `EnablementStore` writes for `appleHealth` and
  `grantWriter.grantConnection(connectionId, to: conversationId,
  grantedToInboxId: agentInboxId)` (whole-toolkit, `bundleIds: nil`) for
  `googleCalendar`,
- sends the in-chat "granted" event and stamps `connectionsAppliedAt`.

Cloud OAuth still happens **in the composer before Make** (unchanged
`toggleConnection` / `startCloudOAuth`); the direct flow only needs the captured
`CloudConnection.id`.

## Why not a new generation-keyed driver

A new `AgentTemplateConnectionGrantReplayer` keyed off `DBAgentTemplateGeneration`
(status `invited` + verified agent) is the alternative. It would duplicate the
observation loop, the device/cloud fire logic, the inflight-dedup, and a new
`connectionsAppliedAt` column — all to re-implement a battle-tested component.
The only reason to prefer it is if we want to stop writing the prompt-card
`AgentBuilderSummary` in the direct flow. We don't (Phase 2 relies on it), so
reusing the replayer is clearly better. Keep this as the fallback only if a
future change drops the summary.

## Edges / decisions

- **Device vs cloud**: cloud (`googleCalendar`) -> `connections[]` **and**
  post-join cloud grant; device (`appleHealth`) -> post-join `EnablementStore`
  grant only (no `connections[]` entry).
- **`bundleIds`**: legacy grants whole-toolkit (`nil`); keep the same for parity.
  Per-bundle selection is a later refinement.
- **Idempotency**: `connections[]` rides the dedupe body, so persist + reuse on
  resume; the deterministic idempotency key should already fold them in
  (consistent with the attachments handling in Phase 3).
- **Existing-conversation (in-chat) variant**: the replayer already grants to
  every verified agent in the conversation, so the in-chat maker works without
  extra wiring.
- **Summary lifetime**: the prompt card's 180s display window is irrelevant to
  the replayer — it reads the persisted row regardless of whether the card is
  on screen.
- **Catalog/bundle scope + `serviceVersion`** are resolved inside
  `CloudConnectionGrantWriter` as today; the direct flow doesn't need to touch
  them.

## Acceptance checks

1. Enabling Google Calendar in the composer, then Make: the generation POST
   carries `connections: ["googlecalendar"]`, the build completes, and the
   template's `connections` reflects it.
2. After the agent joins, a cloud grant is issued to the agent's inbox
   (`createConnectionGrant` fires once), and the in-chat granted event shows.
3. Enabling Apple Health issues the device `EnablementStore` grant post-join
   and is **not** sent in `connections[]`.
4. Grants fire exactly once (the summary's `connectionsAppliedAt` marker), and
   survive an app relaunch between Make and agent-join.
5. A build with no connections sends no `connections` field and is byte-identical
   to a Phase 1-3 body; no regression to the legacy maker (flag off).

## Out of scope (later)

- Per-bundle (vs whole-toolkit) grant scoping in the direct flow.
- Generation-time awareness for device connections (would need a catalog entry).
- Revocation UX changes.
