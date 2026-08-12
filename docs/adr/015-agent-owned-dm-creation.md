# ADR 015: Agent-Owned DM Creation (iOS Reflector)

> **Status**: Accepted (2026-08-12).
> **Author**: jarod
> **Ticket**: CON-761 (Agent DMs)
> **Scope**: Cross-repo. DM creation is owned by the agent
> (`convos-assistants` + vendored `herald-lite`); `convos-ios` is a reflector.
> The backend half is recorded in `convos-assistants` ADR 015. Full cross-repo
> design and migration notes live in
> [`docs/plans/agent-owned-dm-creation.md`](../plans/agent-owned-dm-creation.md);
> this ADR is the durable decision record and documents the iOS behavior.

## Context

An "agent DM" is the private 1:1 channel between a human and an agent they share
a group with. It is transported as a 2-member MLS group (the agent's herald
identity plus the human; the agent is admin) carrying an `agentDm` marker in
`ConversationCustomMetadata` (proto field 8) whose `originConversationId` names
the primary group the pair shares. iOS renders it as a DM page nested under that
primary in the conversation pager.

DM existence is owned by a single durable authority: the agent's worker Assistant
DO (see `convos-assistants` ADR 015), which creates the marked group through its
herald identity and tracks it in a server-side registry. **iOS never creates an
agent DM.** It receives the agent-created DM via welcome/sync and reflects it.

The authority sits server-side because DM existence must be single-writer and
durable, and a client cannot be either: multiple devices per user would race to
create the same DM; in-memory dedup resets on cold launch; MLS group creation is
non-transactional, so a mid-flight failure strands an orphan; and "existence"
inferred from live membership count is indistinguishable from "the agent left."
A single server-side creator with a durable registry removes that whole class of
failure, and leaves iOS a well-scoped job: classify, place, gate, and render what
syncs down. (An earlier iOS-side creator was removed as part of this change; the
migration is covered in the plan doc.)

## Decision Drivers

- [x] One durable authority for DM existence; no device races or inference from
      lossy local state.
- [x] Deterministic placement: a synced DM nests under exactly one primary group
      with zero client inference.
- [x] Do not auto-allow a conversation a peer could forge - the `agentDm` marker
      is member-writable appData.
- [x] Backward-compatible: iOS renders whatever the agent creates; an older
      client simply receives the DM via sync.

## Decision

**iOS is a pure reflector for agent DMs.** It creates none and implements four
responsibilities over the DM that syncs down:

1. **Classification** - `ConversationWriter.extractConversationMetadata`
   classifies a conversation as an agent DM (`isAgentDm`) only when all three
   hold: the `agentDm` marker is present, there are exactly 2 members, and one
   member is an **attested/verified agent** (`anyMemberIsVerifiedAgent` reads
   `DBProfile.agentVerification.isVerified`, which a human peer cannot forge).
   The marker reader is `agentDmOriginConversationId` on `XMTPiOS.Group`
   (`XMTPGroup+CustomMetadata.swift`), returning the origin conversation id from
   `metadata.agentDm.originConversationID`. A one-way `applyingAgentDmLatch`
   keeps a row classified once it was, while it stays 2-member with a verified
   agent present.

2. **Placement** - `DBAgentDmOrigin` (`agent_dm_origin` table, PK
   `conversationId` with a foreign key to `conversation` `onDelete: .cascade`,
   plus an `originConversationId` column) persists the DM -> primary link, so iOS
   nests the DM page under exactly the marker's origin group. `record(...)`
   no-ops on a nil/empty origin, so a marker written without an origin never
   clears a good link.

3. **Consent** - an agent DM arrives as a welcome with `unknown` consent.
   `ConversationWriter` auto-allows it (`.unknown` -> `.allowed`) only when both
   `isAgentDm` is true and `userStillSharesOrigin(originConversationId:selfInboxId:)`
   holds - i.e. the marker's origin conversation still exists locally, lists the
   user as a current member, and has no recorded departure. Otherwise the DM
   keeps its `unknown` consent and surfaces as a normal request. This is a purely
   local reflector decision (no server consent write); the shared-origin gate is
   what stops a verified agent from forging an auto-allowed DM without a live
   shared primary.

4. **Notifications** - the DM lane is tracked separately from the active
   conversation because a DM's own id never appears in the parent-keyed
   `activeConversationChanged`. `AgentDmPageView` posts `activeDmConversationChanged`;
   `SessionManager` tracks `activeDmConversationId` and `shouldDisplayNotification(for:)`
   suppresses a banner while the DM is on screen. Taps route through
   `ConversationsRepository.agentDmTapRouting(forConversationId:)` (resolving the
   parent group and verified-agent inbox from `DBAgentDmOrigin`) to
   `.selectAgentDmPageRequested`, opening the DM page under its parent rather than
   a bare group page.

`AgentDmPageView` renders all of this: before the DM has synced it shows a
disabled "setting up" composer, and it binds the real conversation
(`findAgentDm(with:)`) once the agent-created DM appears. The former "Chat"
entry points (`ContactDetailView.handleChatWithAgentDm`) open the existing DM if
present and otherwise no-op - they never create.

## Consequences

### Positive

- Placement is deterministic and local: iOS resolves the parent group from the
  marker with no membership inference.
- Auto-allow is safe against a forged marker because it is gated on both an
  attested-agent classification and a live shared origin.
- The client carries no DM-creation subsystem - just render, place, gate.

### Negative / trade-offs

- iOS depends on the agent to create the DM, so there is a brief window after a
  user opens the agent's DM page before the DM has synced. It is handled with a
  disabled "setting up" composer, not a client-side create.
- Before the marker syncs, iOS cannot classify or place the DM. Tolerated - the
  DM is simply not shown until its welcome/marker arrives.

### Neutral

- Deploy order across repos is herald-lite -> convos-assistants -> convos-ios;
  every stage is backward-compatible.

## Related Decisions

- `convos-assistants` **ADR 015 - Agent-Owned DM Creation** (the backend half:
  the Herald `create-dm` primitive, the worker `ensureDmsForPrimaryMembers`
  loop, and the durable `dm_create_backoff`).
- [ADR 011 - Single-Inbox Identity Model](./011-single-inbox-identity-model.md)
  (agents join as members of the single-inbox conversation).
- [ADR 014 - Idempotent Agent Join](./014-idempotent-agent-join.md) (the join
  that makes a human a member of the agent's primary group - the trigger that
  ensures a DM).
- [`docs/plans/agent-owned-dm-creation.md`](../plans/agent-owned-dm-creation.md)
  (full cross-repo design + migration notes) and
  [`docs/plans/agent-dms.md`](../plans/agent-dms.md) (the transport, registry,
  and revocation design).

## References

Shipped across five PRs: convos-assistants #3191 (Herald `create-dm` + worker
ensure-DM loop), convos-cli #116 (`agentDm` field-8 codec, published 0.10.16),
convos-ios #1284 (iOS reflector), convos-assistants #3193 and #3195 (two
follow-up bug fixes). iOS landings: #1284 (`91a3c7fd`) and #1271 (`c8dde3f5`).

iOS files:

- Marker reader: `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`
  (`agentDmOriginConversationId`).
- Classification + consent gate: `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationWriter.swift`
  (`extractConversationMetadata`, `isAgentDm`, `userStillSharesOrigin`,
  `applyingAgentDmLatch`, `createDBConversation`).
- Origin link: `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBAgentDmOrigin.swift`;
  migration in `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift`
  (`registerAgentDmMigrations`); marker write + record in
  `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift`
  (`markAsAgentDm`).
- Notifications: `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`
  (`shouldDisplayNotification`, `activeDmConversationId`),
  `Convos/ConvosAppDelegate.swift`,
  `Convos/Conversations List/ConversationsViewModel.swift`
  (`routeToTappedConversation`),
  `Convos/Contacts/ContactDetailView.swift`,
  `Convos/Conversation Detail/AgentDmPageView.swift`.
- Tests: `AgentDmTapRoutingTests.swift`, `AgentDmRegressionTests.swift`.
