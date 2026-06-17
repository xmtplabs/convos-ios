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
  end-to-end (API -> domain -> persisted columns -> publisher), behind a
  removable stub until backend PR #309 deploys.
- **Creation-prompt card** preserved at the top of the chat (reuses
  `AgentBuilderSummary`), shown for both home and in-chat flows.
- **Progressive "activating" card** (new `MessagesListItemType.agentActivating`
  cell): client-paced reveal name -> emoji -> description + cycling phrases +
  progress bar, mapped to `pending -> running -> done -> join`, then hands off
  to the real agent contact card.
- Related fix: `getAgentTemplate` now authenticated so owners resolve their
  own `draft` templates (was a 404 in the template cache).

### Phase 3 — media inputs (image / file / voice) via the presigned uploader

- Reuse the app's existing presigned uploader; upload the plaintext the app
  already holds; send an array of attachment refs (`inputs.attachments[]`)
  instead of base64. Includes the voice-memo entry mode.
- Requires a private bucket + backend-side presigned GET (don't park
  E2E-decrypted content at a public URL). Backend (PR #310 / CON-533): array
  schema, coalescer, multi-part generator, caps, attachment moderation.
- The prompt card + `AgentBuilderSummary` already model attachments, so they
  render once populated.

### Phase 4 — connections integration

- `connections[]` input + the `GET /connections/services` catalog
  (PR #311 / CON-532): the generated prompt/welcome lean on the service and
  the template records it.
- Post-join grants need a **new driver** keyed off the
  `AgentTemplateRepository` / generation state — the legacy
  `AgentBuilderConnectionGrantReplayer` keys off the XMTP `AgentBuilderSummary`
  the direct flow never writes.

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

