# Agent Builder Flow Simplification — Phase 1 detail

Detailed spec for the first chunk of work. Context and later phases live in
`agent-builder-flow-simplification.md`.

## Goal

With the feature flag **on**, text-based agent creation works exactly as a
user expects, end to end — identical first screen, submit -> poll -> invite
-> agent joins -> real conversation. "Complete" here means we do **not**
leave out important error handling or state management: every failure and
lifecycle transition on the text path is either handled in Phase 1 or
explicitly listed as deferred (see "Explicitly out of scope" below). To
avoid botching state management, the persistent `DBAgentTemplateGeneration`
table is part of Phase 1, not a later add-on.

Out of scope for Phase 1 (media, connections, in-chat variant, etc.) is
enumerated at the end so nothing falls through a crack.

## Engine seam + feature flag

- Introduce an `AgentBuilderEngine` protocol with two implementations:
  `LegacyConversationBuilderEngine` (today's conversation-as-transport
  path) and `DirectTemplateBuilderEngine` (the new direct-API path).
- A feature flag selects which engine `AgentBuilderViewModel` constructs.
  The flag must be read at **construction time**, not in `commit()` — the
  legacy path provisions the agent on `.ready` (just building
  `NewConversationViewModel` creates the draft group and fires
  `requestAgentJoin`), so a commit-time check is too late. The new engine
  simply never builds the inner conversation VM chain.
- `AgentBuilderView` + composer state stay identical across engines, so
  the first screen is indistinguishable and flipping the flag is trivial.

## Conversation provenance — use the pre-warmer

"Use the pre-warmer system instead" in `notes.md` refers to
`UnusedConversationCache` (`ConvosCore/.../Messaging/UnusedConversationCache.swift`).
It's an actor that pre-creates a published XMTP group — already has an
invite tag/slug and image encryption key — and parks it as a hidden
`DBConversation` row (`isUnused = true`). Callers
`consumeUnusedConversationId` to claim one, then
`commitClaimedConversation` to make it visible (or
`releaseClaimedConversationId` to drop it).

So rather than building a fresh draft group on commit and waiting on
`publish()` + `ensureInviteTag()` + invite generation synchronously, the
new engine claims a ready-made conversation from the pool at commit — the
invite **slug is already available**, which is exactly what the
`requestAgentJoin(slug:templateId:)` invite needs. For Phase 1 this is
both the simplest path and the one that yields a slug instantly:

1. On Make, `consumeUnusedConversationId` -> conversation id + invite slug.
2. `POST /v2/agent-templates/generations` with the prompt as `inputs.text`,
   a generated UUID `Idempotency-Key`, and the conversation id passed
   through (per notes.md, the generation call carries the conversationID).
3. Poll `GET /generations/:generationId` (or `?wait_ms`) until
   `done` + `templateId` (or `failed`).
4. `requestAgentJoin(slug:templateId:)` to invite the template instance.
5. `commitClaimedConversation` so the conversation becomes visible.

(If the pool is empty, fall back to creating a conversation inline — but
the pool should be the primary path since the slug is pre-baked.)

**Design for the conversation target from day one.** The engine should take
a *conversation target* — either "claim a pre-warmed conversation" or "use
this existing conversationId" — and the generation/poll/invite core sits
underneath it unchanged. Phase 1 only wires and tests the **pre-warmed
(home) path**, but making the target a parameter now means the in-chat
"New Agent" variant (Phase 3) is an added entry point plus a few lifecycle
branches, not a refactor. The branches that differ by target — provenance
(claim vs reuse), visibility commit (yes vs no), and discard/teardown
(release+orphan vs never touch the group) — are the only places the target
leaks into behavior; keep them isolated so the shared core stays target-
agnostic.

## Poll loop in a repository

Own the `generationId` poll loop in an `AgentTemplateRepository` (per
notes.md), not the view, so it survives sheet dismissal. It drives the
local "fake card / fake thinking" UI while `pending`/`running`, then the
invite + visibility commit on `done`. The repository is the single owner of
generation lifecycle state — the view observes it, never the reverse.

## State management & persistence

Persist the in-flight generation from day one via a new
`DBAgentTemplateGeneration` table so a build survives sheet dismissal and
app restart, and the repository has a single source of truth to drive the
state machine and retries. Suggested columns:

- `generationId` (PK), `idempotencyKey`, `conversationId`
- `status` (`pending` / `running` / `done` / `failed` / `invited`)
- `templateId?`, `prompt`, `error?`
- `createdAt`, `updatedAt`

State machine the repository owns (each transition persisted):

1. `submitting` -> write row with the UUID `idempotencyKey` + claimed
   `conversationId` **before** the `POST`, so a crash between write and
   response replays safely (idempotent `POST`) instead of double-creating.
2. `pending`/`running` -> poll; persist `status` transitions.
3. `done` (+ `templateId`) -> fetch template detail into `DBAgentTemplate`,
   then invite.
4. `invited` -> `requestAgentJoin` issued (tracked via the existing
   `DBAgentJoinRequest`); on confirmed join, `commitClaimedConversation`.
5. `failed` -> terminal; surface the error and release the claimed
   conversation.

On launch the repository rehydrates non-terminal rows and resumes the
pipeline (re-poll, or re-issue the invite if `done` but not yet `invited`).
The claimed pre-warmed conversation has its own lifecycle that must stay in
lockstep: `registerClaimedConversation`/`consumeUnusedConversationId` on
start, `commitClaimedConversation` on join, `releaseClaimedConversationId`
on discard or terminal failure — never leave a row claimed-but-orphaned.

## Error handling (text path — all handled in Phase 1)

Submit (`POST /generations`):

- `422` content moderation -> "we can't build that" message; release the
  claimed conversation, mark row `failed`.
- `400` / `413` (bad/oversized body) -> shouldn't happen for plain text,
  but surface a generic failure and log; release + `failed`.
- `409` idempotency reuse with different body -> treat as a logic bug;
  log loudly, don't silently swap results.
- `5xx` / network failure / timeout -> retryable: keep the row `pending`,
  back off and retry the (idempotent) `POST`; show "still working".

Poll (`GET /generations/:id`):

- terminal `failed` -> surface `error`, release conversation, row `failed`.
- `404` (expired/not found) -> terminal failure with a "build expired"
  message; release.
- network loss mid-poll -> keep polling with backoff; never drop the build
  silently.
- long-poll timeout -> reissue the poll (no user-visible error).

Invite (`requestAgentJoin`):

- `502` provision failed / `503` no agents / `504` pool timeout -> retry
  with backoff (the generation already succeeded; the template exists, so
  retrying the join is safe and cheap); surface a transient "agent is
  joining" state, not a hard failure, until a retry budget is exhausted.
- `410` template archived / `404` -> hard failure; surface and release.

Conversation/pre-warmer:

- empty pre-warm pool -> fall back to inline conversation creation (slower,
  but correct); if that also fails, mark `failed` before any `POST`.
- discard/back-out before join -> release the claim; for a 1:1 left in a
  pending state, title it "Agent Pending Creation" (resolved decision).

## Acceptance checks

The chunk is done when, after a text-only Make:

1. The expected agent **joins the conversation** (appears in the member
   list with the right inbox).
2. That inbox is recorded as an **agent contact** — a `DBContact` keyed by
   the agent inbox with `agentVerification` verified and `agentTemplateId`
   mirrored (the existing `ContactsRepository` / member-profile mirror
   pipeline).
3. It resolves to an **agent-template contact** — the template is cached in
   `DBAgentTemplate` via `AgentTemplateCacheCoordinator` (from
   `GET /v2/agent-templates/:id`), and `dedupingAgentsByTemplate` collapses
   the instance into its canonical template row.

Checks 2 and 3 are existing pipelines keyed off member profile metadata and
the template cache; the point of the check is to confirm they still fire
when the join arrives via the direct-API path rather than the legacy XMTP
build flow.

## DB tables for Phase 1

One new table, the rest reused:

- **New: `DBAgentTemplateGeneration`** (schema + lifecycle above) — the
  persistent source of truth for the in-flight generation. Single-table
  migration; in Phase 1 from the start so state management is correct, not
  retrofitted.
- **Resolved template identity** -> `DBAgentTemplate` (already the
  read-through cache the contacts pipeline reads; populate it via the
  existing `AgentTemplateCacheCoordinator` on `done`).
- **Invite/join status** -> `DBAgentJoinRequest` (already tracks
  per-conversation join status).
- **Contacts** -> `DBContact` / `DBMemberProfile` pipeline, unchanged.
- The legacy `DBAgentBuilderSummary` is XMTP-bundle-oriented
  (`bundledMessageIds`) and should **not** be reused for the new card.

## Explicitly out of scope for Phase 1 (deferred, not forgotten)

These do not exist on the text path and are picked up in later phases /
the parity checklist — listed here so the Phase 1 boundary is unambiguous:

- All non-text inputs: images, PDFs/files, video, voice memo (Phase 2).
- Connections + post-join grants (Remaining).
- Real poll-driven agent name / profile photo / thinking updates — Phase 1
  uses local/fake pending UI until the backend adds those fields
  (Remaining).
- In-chat "New Agent" (existing-conversation) variant (Phase 3) and the
  voice-memo entry mode (Remaining).
