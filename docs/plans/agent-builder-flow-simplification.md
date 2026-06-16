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

### Phase 1 — text-based agent creation (complete + robust)

- `AgentBuilderEngine` protocol with `LegacyConversationBuilderEngine` +
  `DirectTemplateBuilderEngine`; a feature flag picks one at construction
  time. Same composer UI either way.
- Text-only happy path: claim a pre-warmed conversation -> `POST
  /v2/agent-templates/generations` (202) -> poll -> `requestAgentJoin(slug,
  templateId)` -> agent joins -> commit conversation visibility.
- `AgentTemplateRepository` owns the poll loop (survives the view). New
  persistent `DBAgentTemplateGeneration` table is the state source of truth
  so a build survives dismissal/restart and resumes.
- Complete: full error handling + lifecycle state machine, nothing
  important deferred silently.
- Out of scope: media, connections, in-chat variant, real poll-driven
  name/photo/thinking (uses fake/local pending UI for now).

### Phase 2 — media inputs via the presigned-URL uploader (skip encryption)

- Reuse the app's existing presigned uploader; upload plaintext the app
  already holds; send an array of attachment refs instead of base64.
- Requires a private bucket + backend-side presigned GET (don't park
  E2E-decrypted content at a public URL). Backend: array schema, coalescer,
  multi-part generator, caps, attachment moderation (CON-527).

### Phase 3 — in-chat "New Agent" (existing-conversation) variant

- Second entry point: build into a conversation the user is already in.
- Same generation/poll/invite core; reuses the Phase 1 "conversation
  target" parameter. Adds: reuse existing slug, no visibility commit, never
  tear down the group, pending UI rendered into an existing chat.

### Remaining (before retiring the flag)

- Connections + post-join grants (new driver; legacy keyed off the XMTP
  summary).
- Poll-driven agent name / profile photo / thinking UI + pending->real
  handoff; profile-screen gating.
- Voice-memo entry mode; error/edge parity; discard/cancel; background vs
  foreground polling.
- Metrics + analytics parity, verification/attestation, no
  credit/entitlement regression.
- Tests (engine, repository, idempotency, QA suites); staged flag rollout
  then delete the legacy engine.
- Backend dependencies: uploaded media beyond inline base64, poll-response
  fields for name/photo/thinking, connections via API vs client grant,
  conversationId on the generation call.
