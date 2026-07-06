# Agent Builder Flow Simplification — Notes

Full plan: `docs/plans/agent-builder-flow-simplification.md`
Phase 1 detail: `docs/plans/agent-builder-flow-simplification-phase-1.md`

## Prior Notes

### Agent Builder UI

- Bypass the agentBuilderVm→newConversationVm→conversationVm
    - Attachments don’t go to the new conversation, get enqueued in agent template repo
    - No pre-invitation to conversation
    - No pre-creation of conversationVm, use the pre-warmer system instead

### Conversation Screen UI

- Fake agent card
- Fake thinking messages
- Fake attachments

### Profile Screen UI

- Unavailable until template is ready and invited

### Agent Template Repository

- Kick off the template builder flow via template builder API call
- Handle long polling and retries
- Send invitation on template completion
- Send connection grant after agent join
- Profile info
- Thinking messages\
- Domain model
    - generationId + templateId
    - Profile info
    - Thinking messages*
    - Related conversation ID (post-creation, invite to conversation, retry if fails)
    - Related grants (post-approval, post-join send grants)

### Template Builder API Client

- Image/video/wav uploader (Convos backend w/o encryption keys)
- Encode to JSON array of message content and upload, custom schematization

## Other Considerations

- Backing out of a conversation, what do we title the conversation?
- Deleting the chat before the agent template is created? Stop? Orphan?

## Implementation Outline

The builder stops being a conversation. It becomes a plain text-entry that
calls the backend `agent-templates/generations` endpoints directly, polls
for the result, and invites the resulting `templateId` into a conversation.
Built behind a feature flag as an alternative engine alongside the legacy
path, with an identical first screen, so we can flip it on and delete the
old path once parity is proven.

### Phase 1 — text-based agent creation — DONE

Detail: `agent-builder-flow-simplification-phase-1.md`.

- Flag-gated direct path in `AgentBuilderViewModel` alongside the legacy
  bundle path; same composer UI either way.
- Text-only happy path: claim a pre-warmed conversation -> `POST
  /v2/agent-templates/generations` (202) -> poll -> `requestAgentJoin(slug,
  templateId)` -> agent joins -> commit conversation visibility.
- `AgentTemplateRepository` owns the poll loop (survives the view); the
  persistent `DBAgentTemplateGeneration` table is the state source of truth
  so a build survives dismissal/restart and resumes.
- Full error handling + lifecycle state machine.
- The **in-chat "New Agent" variant shipped here too** — it was a one-branch
  change (route the existing-conversation commit through the same core), not
  a separate phase.
- Used a generic local pending placeholder (no real identity yet — that's
  Phase 2).

### Phase 2 — progress updates + creator-facing cards — DONE (pending backend PR #309)

Detail: `agent-builder-flow-simplification-phase-2.md`.

- `preview` (agentName/emoji/description) + `progressPhrases` modeled
  end-to-end (API -> domain -> persisted columns -> publisher), driven by the
  real backend PR #309 responses (the temporary stub + flag were removed once
  #309 deployed to Dev).
- **Creation-prompt card** preserved at the top of the chat (reuses
  `AgentBuilderSummary`), shown for both home and in-chat flows.
- **Progressive "activating" card** (new `MessagesListItemType.agentActivating`
  cell): client-paced reveal name -> emoji -> description + cycling phrases +
  progress bar, mapped to `pending -> running -> done -> join`, then hands off
  to the real agent contact card.
- Related fix: `getAgentTemplate` now authenticated so owners resolve their
  own `draft` templates (was a 404 in the template cache).

### Phase 3 — media inputs (image / photo / voice / PDF) via the presigned uploader

Detail: `agent-builder-flow-simplification-phase-3.md`.

- Upload the plaintext bytes the app already holds to a **separate**
  agent-templates presigned endpoint (`GET
  /v2/agent-templates/attachments/presigned` -> `{ objectKey, uploadUrl }`,
  private bucket, no public URL), then reference each by `objectKey` in
  `inputs.attachments[]`. Backend: PR #310 / CON-533.
- These are **not** XMTP `RemoteAttachment`s and there's no attachment crypto:
  the backend reads the bytes itself, so we skip `encodeEncrypted` entirely and
  reuse only the image compression + presigned-`PUT` mechanics. "Unencrypted"
  is inherent — no shared conversation, no message, just plaintext by key.
- Allowlist drives scope: image (`image/png`, `image/jpeg` <= 5 MB), PDF
  (`application/pdf` <= 25 MB), audio (m4a/etc <= 25 MB, transcribed). **No
  video** -- hidden/rejected for direct builds. Caps: <= 9 files, <= 60 MB
  aggregate, <= 40 MB body.
- The builder composer already stages photos/files/voice; wire those into the
  direct flow, persist them on `DBAgentTemplateGeneration` (so a build survives
  relaunch), and add a repository upload step before submit. Object keys are
  part of the idempotency body, so persist + reuse them across retries.
- The prompt card + `AgentBuilderSummary` already model attachments, so they
  render once populated.

### Phase 4 — connections integration

Detail: `agent-builder-flow-simplification-phase-4.md`.

- **Two independent halves.** (1) Generation-time awareness: send
  `connections[]` (neutral cloud service ids, e.g. `["googlecalendar"]`,
  validated against `GET /connections/services`) so the generated prompt/welcome
  lean on the service and `template.connections` records it (PR #311 / CON-532).
  (2) Post-join grants: the real per-agent authorization, issued after the agent
  joins.
- **No new driver needed.** The earlier assumption is out of date: since Phase 2
  the direct flow **does** write an `AgentBuilderSummary` (the prompt card), and
  the legacy `AgentBuilderConnectionGrantReplayer` is already started for every
  session (`SessionManager.swift:157`) and observes all summary rows. Populating
  the direct flow's summary with `.connection` attachments + `cloudConnectionIds`
  makes the existing replayer fire device (`EnablementStore`) and cloud
  (`grantConnection`) grants post-join for free.
- Device connections (Apple Health) get only the post-join device grant (not a
  `connections[]` entry — not a catalog service); cloud (Google Calendar) gets
  both. `connections[]` rides the idempotency body, so persist + reuse on resume.

### Remaining (before retiring the flag)

- Error/edge UX parity (moderation/failed/expired), discard/cancel,
  background vs foreground polling.
- Metrics + analytics parity, verification/attestation, no
  credit/entitlement regression.
- Tests (engine, repository, idempotency, QA suites); staged flag rollout,
  then delete the legacy engine.
- Deferred polish from Phase 2: prompt-card lifetime beyond the 180s window,
  networking the prompt card to other members, a precise existing-chat
  "this agent joined" signal.
- Backend dependencies: #309 (preview/progress), #310 (uploaded media),
  #311 (connections).

