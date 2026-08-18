# Agent chat server contract

> **Status:** In Review<br>
> **Audience:** Convos Backend, Assistants Runtime, Herald, Billing, Privacy/Security<br>
> **Client:** iOS agent-chat prototype based on PR #1325<br>
> **Last updated:** 2026-08-16

## Decision request

The iOS prototype can ship to internal testers now, but production activation needs the server team to commit to four contracts:

1. A server-owned model catalog and a per-user, per-agent model preference.
2. Entitlement checks and credit charging at runtime, never in the client.
3. Multi-agent private lanes that preserve each agent's existing DM and in-flight work.
4. A real Ghost Mode isolation boundary with explicit retention and export rules.

The recommended scope is incremental. Model selection is the first production slice. The agent switcher mostly composes existing XMTP and agent-DM primitives. Ghost Mode is a separate privacy project and must not be represented as private until its runtime and data boundaries are verified.

## Existing system we should preserve

- iOS authenticates Convos APIs with the existing SIWE-bound account JWT.
- Agent instances already expose `instanceId`, `templateId`, and `inboxId` through provisioning/profile metadata.
- Agent private lanes are 2-member XMTP groups carrying `agentDm.originConversationId`.
- Each verified agent instance owns its own private lane with each eligible group member.
- Normal agent DMs intentionally share one Hermes session and memory with the origin group.
- StoreKit purchases are confirmed through `POST /v2/accounts/me/subscription/verify`; `GET /v2/accounts/me/subscription` is authoritative afterward.
- Credit balance is server-owned at `GET /v2/accounts/me/credits`.

Do not create a second conversation store, notification system, or client-authored entitlement source for the first two features.

## Product invariants

These are acceptance rules, not implementation suggestions:

- A model shown as active must be the model the runtime will use for the next eligible turn.
- A client request can never bypass plan, regional, model-availability, or credit checks.
- A purchase result from StoreKit is not an entitlement until the backend confirms it.
- A model change affects only the requesting user's interactions with that agent. It must not silently change another group member's cost or behavior.
- Switching visible agent lanes is navigation. It does not cancel, redirect, or merge in-flight work.
- Normal agent DMs may use the agent's shared group memory; Ghost Mode may not.
- Nothing from Ghost Mode can enter a group, another agent, shared memory, analytics content, or a desktop device without a deliberate message-level export.
- “Off the record” must be backed by a concrete retention/provider/logging policy returned by the service and approved by Privacy/Security.

## Ownership by service

| Area | Authoritative service | Responsibility |
|---|---|---|
| Model catalog | Convos Backend/config service | Stable IDs, display metadata, availability, plan labels, metering policy |
| Model preference | Convos Backend | Desired/effective state scoped to account + agent instance |
| Model routing | Assistants Runtime | Resolve effective model for every turn and call the correct provider |
| Entitlements | Convos Backend/Billing | Evaluate verified subscription and feature grants |
| Credit ledger | Convos Backend/Billing | Reserve, settle, refund, and deduplicate turn charges |
| Agent DM existence | Assistants Runtime + Herald | One private XMTP lane per agent instance and eligible member |
| Agent switcher directory | iOS/XMTP state | List verified agents in the origin group; no new directory API in v1 |
| Ghost session | Separate Assistants runtime namespace | Isolated memory, tools, retention, and delivery |
| Ghost export authorization | Convos Backend/Ghost service | Verify ownership and bind one message to one destination |

---

## 1. Model catalog and selection

### Scope

The preference is keyed by `(accountId, agentInstanceId)`, not just `agentInstanceId`.

This lets Shane choose Claude Fable for his Space Abilities lane without forcing every other member of the origin group onto the same model or charging them at Shane's rate. For a user-authored turn, the invoking account owns the preference and charge. Scheduled/background work uses the account that created the automation and must record that owner explicitly.

### Model identifiers

Model IDs are opaque, stable server identifiers. Display names and provider routing must not be parsed from the ID.

Prototype labels may map to IDs such as:

```text
openai:gpt-5.6-sol
anthropic:claude-opus
anthropic:claude-fable
droc:4.6
```

The actual launch catalog is a server-team decision. Removing a model does not delete its historical usage records or make old clients fail to decode the catalog.

### `GET /v2/agent-models`

Authenticated. Returns the account-aware catalog. Support `ETag`/`If-None-Match` and a five-minute private cache.

```json
{
  "catalogVersion": "2026-08-16.1",
  "defaultModelId": "openai:gpt-5.6-sol",
  "models": [
    {
      "id": "openai:gpt-5.6-sol",
      "displayName": "GPT-5.6 Sol",
      "providerDisplayName": "OpenAI",
      "summary": "Fast, capable, and balanced for everyday work.",
      "relativeCreditUse": 1,
      "relativeCreditLabel": "Standard credit use",
      "requiredEntitlement": null,
      "requiredPlanDisplayName": null,
      "availability": "available",
      "unavailableReason": null,
      "capabilities": ["text", "vision", "tools"]
    },
    {
      "id": "anthropic:claude-fable",
      "displayName": "Claude Fable",
      "providerDisplayName": "Anthropic",
      "summary": "Maximum depth for complex reasoning and long-form work.",
      "relativeCreditUse": 4,
      "relativeCreditLabel": "4× standard credit use",
      "requiredEntitlement": "agent_models.premium",
      "requiredPlanDisplayName": "Plus",
      "availability": "requires_entitlement",
      "unavailableReason": null,
      "capabilities": ["text", "vision", "tools"]
    }
  ]
}
```

Allowed `availability` values:

- `available`
- `requires_entitlement`
- `temporarily_unavailable`
- `region_unavailable`
- `retired`

`relativeCreditUse` and `relativeCreditLabel` are product copy. The client never multiplies or submits charges from them.

### `GET /v2/agents/instances/{instanceId}/model-preference`

Authenticated. Returns the caller's preference plus the model that is actually effective.

```json
{
  "agentInstanceId": "agent-instance-123",
  "desiredModelId": "anthropic:claude-fable",
  "effectiveModelId": "openai:gpt-5.6-sol",
  "state": "requires_entitlement",
  "requiredEntitlement": "agent_models.premium",
  "requiredPlanDisplayName": "Plus",
  "revision": 7,
  "updatedAt": "2026-08-16T19:40:00Z",
  "canManage": true
}
```

Allowed states:

- `active`: desired and effective model match.
- `requires_entitlement`: desired choice is saved, but runtime remains on the safe fallback.
- `unavailable`: desired model cannot currently run; fallback remains effective.
- `invalid_agent`: instance no longer exists or is not visible to this account.

`canManage` lets the server turn the selector read-only if a future agent type is owner-managed rather than per-user.

### `PUT /v2/agents/instances/{instanceId}/model-preference`

Authenticated and idempotent.

```json
{
  "desiredModelId": "anthropic:claude-fable",
  "expectedRevision": 7,
  "idempotencyKey": "0b70df39-623a-4fc6-b941-b1c72d4c7332"
}
```

Return the complete representation from the GET. Saving a locked model is allowed, but it must return `requires_entitlement` and leave the default model effective. This supports the inline upgrade state without pretending the new model is already active.

Errors:

| Status | Code | Meaning |
|---|---|---|
| 400 | `invalid_model` | Unknown or malformed model ID |
| 401 | `authentication_required` | No valid account JWT |
| 403 | `agent_access_denied` | Caller cannot access this instance |
| 404 | `agent_not_found` | Instance does not exist |
| 409 | `revision_conflict` | Preference changed elsewhere; response includes current state |
| 422 | `model_retired` | Model cannot be newly selected |
| 503 | `model_catalog_unavailable` | Safe retry; no state change |

### Entitlement lifecycle

- The catalog and preference service evaluate feature grants, not client-supplied plan names.
- `trial`, `active`, `grace`, and `billingRetry` eligibility must be a single Billing-owned policy. iOS must not duplicate it.
- After `subscription/verify` changes grants, re-resolve pending model preferences immediately or enqueue a durable reconciliation job.
- The client refreshes subscription and preference state after purchase. It only renders the premium model as active when `effectiveModelId` changes.
- On expiration/revocation, preserve `desiredModelId`, move state to `requires_entitlement`, and immediately fall back to the default model.
- If the catalog retires a model, preserve it for history, return `unavailable`, and use the catalog default for new turns.

### Runtime contract

For every agent turn, the runtime receives or resolves:

```json
{
  "accountId": "account-123",
  "agentInstanceId": "agent-instance-123",
  "conversationId": "xmtp-conversation-id",
  "triggerMessageId": "xmtp-message-id",
  "effectiveModelId": "anthropic:claude-fable",
  "catalogVersion": "2026-08-16.1",
  "meteringPolicyVersion": "credits-2026-08-1"
}
```

Runtime requirements:

1. Resolve the authenticated sender/automation owner to an account.
2. Fetch the effective server preference; never accept a model ID embedded by the client in a chat message.
3. Re-check entitlement and model availability before provider invocation.
4. Reserve credits atomically before the provider call.
5. Settle actual use or refund the reservation after completion/failure.
6. Deduplicate by `(agentInstanceId, triggerMessageId)` so retries cannot double-charge.
7. Emit the actual model ID and metering policy to internal turn telemetry.
8. On a stale-cache or provider failure, either use the declared fallback and record it or fail visibly. Never silently charge at one rate while reporting another model.

Recommended usage-ledger fields:

```text
account_id, agent_instance_id, conversation_id, trigger_message_id,
desired_model_id, effective_model_id, provider_request_id,
input_units, output_units, reserved_credits, settled_credits,
catalog_version, metering_policy_version, status, created_at
```

No message text belongs in billing or product analytics.

---

## 2. Multi-agent switcher

### Minimal server work

iOS can build the switcher from verified agent members already present in the origin XMTP group. Do not add a duplicate `GET conversation agents` endpoint for v1.

The server/runtime must guarantee:

- Every verified agent in the origin group publishes `instanceId`, `templateId`, name/avatar metadata, attestation, and `accepts_dms`.
- Each agent instance creates or reconciles one agent-owned DM per eligible human member using the existing `agentDm.originConversationId` marker.
- DM creation remains unique per `(agentInboxId, peerInboxId)` and idempotent across device races.
- The origin group may contain multiple agent instances. One instance failing to create a DM must not block lanes for the others.
- Each lane retains its own conversation ID, unread state, typing state, delivery stream, and response lifecycle.
- A message arriving in Flight Tracker's DM can only trigger Flight Tracker. The currently visible lane on an iPhone is irrelevant to server routing.
- Switching away does not cancel an active turn. Completion is delivered to the original DM and appears as activity/unread on that lane.

### No server-side “selected agent” state

The selected row, composer draft, attachments, scroll position, and active screen are device UI state. Persisting one global selected agent would cause devices to fight each other and risks misrouting drafts. Server state remains lane-based.

### Operational status

If the runtime wants to expose more than XMTP's typing/delivery events, add a non-content status channel keyed by agent instance and DM conversation:

```json
{
  "agentInstanceId": "agent-instance-123",
  "conversationId": "agent-dm-conversation-id",
  "state": "idle",
  "updatedAt": "2026-08-16T19:40:00Z"
}
```

Allowed states should stay coarse: `provisioning`, `idle`, `working`, `unavailable`. Do not expose provider chain-of-thought or message content.

---

## 3. Ghost Mode

### Hard boundary

Ghost Mode cannot reuse the ordinary agent-DM Hermes session. Current agent DMs intentionally share transcript and memory with their origin group. Reusing that session would allow Ghost content to influence later group/DM answers and would violate the product promise.

Ghost Mode requires a distinct runtime session and memory namespace, even when it uses the same model/tooling code.

Recommended isolation key:

```text
ghost:{accountId}:{ghostSessionId}
```

Never alias this to an agent instance's primary Hermes session ID.

### Proposed transport

Use a dedicated, attested Ghost agent identity in a 2-member XMTP group with the user. Add a new custom-metadata marker rather than overloading `agentDm`:

```protobuf
message GhostModeInfo {
  string session_id = 1;
  string policy_version = 2;
}
```

Classification must require:

- exactly two members;
- the other member has a valid Convos agent attestation;
- the `ghostMode` marker is present;
- the session registry binds that conversation ID to the authenticated user's inbox/account.

The Ghost identity must not join the origin group, subscribe to its transcript, use its memory, or publish messages to its push topics.

### `POST /v2/ghost-sessions`

Authenticated and idempotent. The backend must verify/bind the user's XMTP inbox to the authenticated account; accepting an arbitrary unverified inbox ID is insufficient.

```json
{
  "peerInboxId": "user-xmtp-inbox",
  "originConversationId": "optional-origin-for-ui-only",
  "idempotencyKey": "fa327e72-05cd-48c3-87b6-8c848b8ffbe4"
}
```

Response:

```json
{
  "sessionId": "ghost-session-123",
  "status": "provisioning",
  "agentInboxId": "ghost-agent-inbox",
  "conversationId": null,
  "policy": {
    "version": "ghost-privacy-2026-08-1",
    "contentRetentionHours": 24,
    "auditRetentionDays": 30,
    "providerRetention": "zero_data_retention",
    "providerTrainingAllowed": false,
    "contentAnalyticsAllowed": false,
    "sharedMemoryAllowed": false,
    "deletionSlaHours": 24
  }
}
```

Follow existing join semantics: return `provisioning` when the conversation is not ready, and support `GET /v2/ghost-sessions/{sessionId}` for bounded polling.

### Runtime restrictions

- No access to the origin group's transcript or normal agent memory.
- No write-capable tool by default. Search/read tools may run only under the user's existing grants and must not persist results into shared memory.
- No proactive outreach, scheduled messages, group updates, member pings, or automatic forwarding.
- Provider requests must use the approved no-training/retention settings for the selected provider.
- Prompt/response bodies must not enter Sentry, PostHog, request logs, traces, or billing metadata.
- Safety logging, if legally required, must be explicitly represented in the policy and UI copy.
- Deleting the Ghost session revokes the runtime, removes retained content within the stated SLA, and makes outstanding exports unusable.
- Backups and replicas must honor the same eventual deletion policy; document any unavoidable delay separately.

### Retention decisions required before production

Privacy/Security and the server team must sign off on:

1. Content retention duration and why it is needed.
2. Provider processing/retention terms for every selectable model.
3. Whether abuse/safety systems retain content and for how long.
4. Whether humans can access content for support or incident response.
5. Backup deletion behavior and maximum deletion latency.
6. Whether attachments/search results follow the same policy.
7. What metadata remains after content deletion.

Until these are answered, production copy should say **Private from the group** rather than **Completely off the record**.

### Message-level export

Only completed individual messages are exportable. A share action must never infer “the surrounding conversation.”

Proposed authorization endpoint:

`POST /v2/ghost-sessions/{sessionId}/messages/{messageId}/exports`

```json
{
  "destination": {
    "type": "agent",
    "agentInstanceId": "agent-instance-456",
    "conversationId": "destination-agent-dm-id"
  },
  "contentDigest": "sha256-of-canonical-selected-message",
  "idempotencyKey": "3a222c67-cdfc-4565-a71b-1f1fd4d2f151"
}
```

The service verifies:

- the session belongs to the authenticated account;
- the message belongs to that Ghost session;
- the message is final and not deleted;
- the digest matches exactly one canonical message;
- the destination is a verified agent lane accessible to the user;
- the same idempotency key has not exported a different payload.

Return a short-lived, single-use export permit bound to source message ID, digest, destination, and expiry. iOS then sends the selected content through the user's own XMTP identity into the destination lane. The server must not impersonate the user.

The destination receives one structured `GhostExport` message containing the selected body plus the permit. It does not receive the Ghost session ID, prior messages, hidden prompt context, search history, or attachments unless the user selected those attachments explicitly.

For **Save to Desktop**:

- If this means the native iOS share sheet, AirDrop, Files, or copy, no server endpoint is required; export stays client-side.
- If this means a Convos desktop inbox, use the same permit design with `destination.type = "desktop_device"` and end-to-end encrypt the payload to a registered device key. Do not store a plaintext desktop artifact on the server.

### Content-free audit event

Record only:

```text
event_id, account_id, ghost_session_id, source_message_id,
destination_type, destination_id, result, policy_version, created_at
```

Do not record the message body, attachment body, search query, model prompt, or content digest in general analytics. If the security audit store needs the digest, keep it in that restricted store only.

---

## Cross-cutting security

- Every public endpoint uses the existing authenticated account JWT and App Check posture.
- Internal runtime calls use a separate scoped service credential and cannot select an arbitrary account.
- Agent instance access must be derived from trusted provisioning/XMTP membership state, not a client claim alone.
- Add rate limits by account and instance/session.
- Require idempotency keys for preference writes, Ghost provisioning, and exports.
- Encrypt server-held Ghost content at rest with a key namespace separate from ordinary agent memory.
- Redact message text and provider prompts from logs by construction; add automated log-scrubbing tests.
- Treat model catalog configuration as security-sensitive: changes require review, validation, and an audit trail.

## Observability

Required dashboards/alerts:

- Model selection success, pending-entitlement, conflict, and fallback rate.
- Turns by desired/effective model and catalog version.
- Credit reservation/settlement mismatch and duplicate-turn suppression.
- Agent DM provisioning latency/failure by instance, without message content.
- Ghost provisioning latency, deletion SLA, export success/failure, and any policy violation.
- Alert if a Ghost session reads/writes a non-Ghost memory namespace or sends to a destination without an export permit.

## Delivery sequence

### Phase A — model selection

1. Backend publishes model catalog.
2. Backend stores per-account/per-instance preference.
3. Billing maps entitlements and metering policy.
4. Runtime resolves preference and charges server-side.
5. iOS replaces its local prototype store with these endpoints.
6. Enable in Dev/Firebase, then production behind a server flag.

### Phase B — multi-agent switcher

1. Confirm agent-owned DM reconciliation works for every agent in a multi-agent group.
2. Add load/race coverage for three agents × multiple members.
3. iOS lists verified group agents and binds one `AgentDmSession` per selected inbox.
4. Validate in-flight completion/unread behavior while switching.

### Phase C — Ghost Mode

1. Approve the privacy/retention policy.
2. Add the new conversation marker and session registry.
3. Deploy isolated runtime/memory/provider policy.
4. Implement deletion and message export permits.
5. Complete adversarial privacy tests and incident-response runbook.
6. Only then enable “off the record” copy.

### Phase D — external context handoffs and Home return connectors

1. Treat the external lane as an explicit export, not a hosted agent session. iOS submits a context window (`1h`, `24h`, `7d`, or bounded all-available), whether to include visible Home summaries, and the destination label.
2. Build a deterministic export manifest before returning content: exact start/end timestamps, included message count, included Home object IDs/revisions, truncation reason, policy version, and excluded content classes. Require active convo membership at assembly time.
3. Export only ordinary visible group messages inside the selected window plus optional visible Home object summaries. Exclude Ghost content, agent/private/member DMs, other convos, membership lists, deleted/hidden messages, raw credentials, tool traces, and unsaved files.
4. Return one paste-ready plaintext block to the authenticated iOS client. Never put exported content, identifiers, or a pairing key in the provider deep-link URL; iOS opens only a fixed allowlisted destination after the user copies the block. Grok Bot is a separate macOS/iOS app from Grok and uses the native `sand://app/v1/open` route already used by the companion project.
5. Do not create a provider credential or automatic outbound request for context-only handoff. Clipboard exposure is explicit in the client copy and privacy review.
6. For optional return access, mint a random single-use pairing code with at least 128 bits of entropy, a 10-minute maximum lifetime, one convo ID, one owner, and requested scopes limited to `home.visible_summary.read`, `home.link.proposal.create`, and `home.widget_update.proposal.create`.
7. The external agent's secure Convos connector exchanges the code over TLS while proving its connector identity (public-key/PKCE or stronger). The exchange returns short-lived access tokens plus a revocable refresh credential bound to that connector; iOS never receives those credentials.
8. Return connectors can create idempotent Home edit proposals against stable object IDs/revisions. They cannot read messages, publish/delete/share Home objects, expand their own scopes, or bypass the existing user preview/approval flow.
9. Store return credentials in the connector's secret store, never in a model prompt, tool result, analytics event, push payload, crash report, or general log. Support immediate owner revocation and expiry-driven cleanup.

Suggested shapes:

```text
POST /v1/conversations/{conversation_id}/context-exports
POST /v1/conversations/{conversation_id}/external-return-pairing-sessions
POST /v1/external-return-pairing-sessions/{pairing_id}/exchange
GET  /v1/external-return-connectors/{connector_id}
POST /v1/external-return-connectors/{connector_id}/revoke

context_export_request = {
  window: "1h" | "24h" | "7d" | "all_bounded",
  include_home: boolean,
  destination_label: string,
  policy_version: string
}

pairing_session = {
  id: string,
  display_code: string,
  conversation_id: string,
  scopes: string[],
  expires_at: timestamp,
  consumed_at: timestamp | null
}
```

The context-only flow works with any destination that accepts pasted text and requires no provider integration. Return access works only where the external environment can install or invoke a secure Convos connector/tool; the consumer Grok app must not be presented as supporting this until such a connector path is verified. Provider app authentication remains entirely provider-owned.

### Phase E — chat links and Home edit commands

1. Emit an idempotent `HomeLinkProjection` whenever any visible group message contains a supported URL/link preview.
2. Key the projection by `(conversation_id, source_message_id, canonical_url)` and retain the immutable source message reference.
3. Publish projection changes through the existing encrypted conversation/Home sync path so every authorized desktop sees the same link object.
4. Give Home objects stable IDs, revisions, visibility, layout metadata, and an optional preview image/title cache.
5. Agent edits submit typed commands against object ID + expected revision; the server validates the agent grant and returns a preview diff.
6. Require an explicit user approval token for publish/delete/share operations. Read-only summaries do not require a publish token.

```text
GET  /v1/conversations/{conversation_id}/home/objects
POST /v1/conversations/{conversation_id}/home/edit-previews
POST /v1/conversations/{conversation_id}/home/edit-previews/{preview_id}/publish

edit_preview = {
  connector_or_agent_id: string,
  object_id: string,
  expected_revision: integer,
  command: typed_operation,
  diff: object,
  expires_at: timestamp
}
```

Never send the full Home, full transcript, private agent DMs, or Ghost content when one object is sufficient. Context assembly must be capability-scoped and recorded in a content-free authorization audit.

### Phase F — cross-convo shared agents

1. Add an owner-scoped query for agents the user owns in other active convos. Return the origin convo label plus summaries of durable memory, abilities, connections, and installed skills without returning memory content to the picker.
2. Model a link as one agent identity and one durable memory namespace authorized for two or more convo IDs. Do not clone the agent, copy memory records, or merge message histories.
3. Require the actor to own the agent and be an active member of every linked convo at creation. Re-check ownership and membership on every memory read/write and ability, connection, or skill invocation.
4. The agent's full versioned capability manifest travels with the link: abilities, vault-backed connections, installed skills, runtime/model configuration, and policy version. Secrets never leave the existing credential vault.
5. Tag every durable memory item with source convo, author/agent, content class, creation time, and policy version. Only reviewed durable-memory classes may enter the shared namespace.
6. Exclude raw messages/transcripts, Ghost content, private agent DMs, member DMs, membership lists, and unsaved attachments from shared-memory retrieval and indexing.
7. Publish visible link-state events to every linked convo. Disconnecting a convo must immediately stop its retrieval, writes, and capability invocations without deleting the surviving agent or its memory.

Suggested shapes:

```text
GET    /v1/owned-agents?exclude_conversation_id={conversation_id}
POST   /v1/agents/{agent_id}/convo-links
GET    /v1/agents/{agent_id}/convo-links/{link_id}
DELETE /v1/agents/{agent_id}/convo-links/{link_id}/conversations/{conversation_id}

convo_link = {
  id: string,
  agent_id: string,
  memory_namespace_id: string,
  conversation_ids: string[],
  capability_manifest_version: string,
  policy_version: string,
  created_by_inbox_id: string
}
```

## Server acceptance tests

### Model selection

- Two members choose different models for the same agent instance; each next turn uses and charges the correct model.
- A non-Plus user saves Fable; desired becomes Fable, effective stays default, and no premium provider call occurs.
- After verified subscription activation, effective becomes Fable without an optimistic client unlock.
- Subscription revocation during an in-flight turn does not corrupt billing; the next turn uses the fallback.
- Retired/unavailable model returns a stable fallback reason and never strands the agent.
- Retried trigger message settles credits exactly once.

### Agent switching

- Three verified agents in one origin group each produce one DM per member with no duplicates.
- Concurrent DM reconciliation does not cross-bind agent identities.
- A turn started in Space Abilities completes there after the user switches to Flight Tracker.
- Removing one agent leaves its lane unavailable without affecting the others.

### Ghost Mode

- Ghost content never appears in group/normal-DM transcript retrieval or shared memory search.
- A later normal-agent answer cannot retrieve facts stated only in Ghost Mode.
- Group members/admins receive no Ghost push, unread, or audit content.
- Exporting message B sends B only; A/C, system prompts, tool traces, and attachments remain absent.
- Reusing, changing, or replaying an export permit fails closed.
- Deletion meets the stated content and backup SLA.
- Logs/traces/analytics contain no Ghost message or search text.
- Provider requests carry the approved retention/training flags for every catalog model.

### External agents

- Every time window uses inclusive/exclusive timestamp boundaries consistently and cannot return messages outside the requested range.
- Turning Home off yields zero Home object content; turning it on returns only visible summaries and stable IDs/revisions, never hidden fields or credentials.
- Ghost, private agent/member DMs, other convos, memberships, deleted/hidden messages, tool traces, and unsaved files never appear in an export fixture.
- Exported plaintext never appears in a deep-link URL, analytics, push payloads, crash reports, or general logs.
- A replayed, expired, wrong-owner, wrong-convo, or already-consumed return pairing code fails closed and cannot create a second connector.
- A return connector cannot request or self-expand beyond Home summary/proposal scopes and cannot retrieve any message transcript.
- Proposal writes are idempotent, revision-checked, visibly attributed to the connector, and require the normal user preview/approval before publish.
- Revoking a return connector blocks the next read/proposal immediately and invalidates refresh credentials.
- Pairing codes, access tokens, and refresh credentials never appear in model prompts, iOS responses after exchange, analytics, push payloads, or general logs.

### Home link projections and editing

- The same link message processed twice creates one Home object.
- Links from every member and agent are eligible; hidden/deleted/inaccessible messages are not projected.
- A card always preserves its source message and canonical URL.
- Editing a stale revision returns a conflict and a refreshed preview; it never overwrites silently.
- An agent without `home.write` can summarize but cannot create a publish token.
- Publishing one card diff cannot mutate unrelated Home objects.
- Ghost content never becomes a Home object without an explicit message-level export.

### Cross-convo shared agents

- A non-owner cannot create, expand, or disconnect an agent link.
- A user who is not an active member of every target convo cannot create the link.
- Linking never copies raw transcript rows or changes their convo IDs.
- Retrieval returns only allowed durable-memory content classes and records the requesting convo.
- Ghost, private DM, membership, and unsaved-attachment fixtures never appear in shared-memory indexes or provider prompts.
- The same versioned abilities, connections, and skills are resolvable from both convos, while provider secrets remain absent from responses, prompts, analytics, and logs.
- Disconnecting one convo immediately blocks its reads, writes, and capability invocations while preserving the agent and memory for remaining authorized convos.
- Every linked convo receives a visible, idempotent link-state update and can resolve the other linked convo's display label.

## Launch gates

- [ ] Model IDs, relative credit copy, and entitlements approved by Product/Billing.
- [ ] Runtime model routing and ledger reconciliation tested in Dev.
- [ ] Account-to-agent access rules documented and enforced.
- [ ] Multi-agent DM creation tested under race and partial-failure conditions.
- [ ] Ghost Mode memory is technically separate from the group/DM Hermes session.
- [ ] Privacy policy fields reflect deployed behavior, not aspirational copy.
- [ ] Ghost deletion and export authorization pass security review.
- [ ] External context export windows, Home inclusion, exclusions, truncation, and fixed-URL handoff pass privacy/security review.
- [ ] Return pairing codes are single-use, short-lived, owner/convo-bound, and exchanged for vault-backed revocable connector credentials.
- [ ] Return connectors are limited to visible Home summaries and approval-gated link/widget proposals; message and direct-publish access fail closed.
- [ ] Home object revisions, preview diffs, and approval tokens pass concurrency and authorization tests.
- [ ] Cross-convo links enforce agent ownership, membership in every convo, content-class exclusions, portable capability versioning, visible link state, and immediate disconnect.
- [ ] Rollback returns all model preferences to the safe default without losing desired state.

## Client handoff after server readiness

iOS needs the final OpenAPI/schema definitions, Dev base URLs, feature-flag names, catalog fixtures, test accounts for each entitlement state, and a way to force model/provider failures. Once those are available, the current local `AgentModelPreferenceStore` can be replaced with an API-backed service without redesigning the profile UI.
