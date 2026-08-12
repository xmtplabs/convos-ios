# ADR 015: Agent-Owned DM Creation (iOS Reflector)

> **Status**: Accepted (2026-08-12).
> **Author**: jarod
> **Ticket**: CON-761 (Agent DMs)
> **Scope**: Cross-repo decision driven by the iOS/messaging team. The creation
> authority moves to the agent (`convos-assistants` + vendored `herald-lite`);
> `convos-ios` is reduced to a reflector. The backend half of this decision is
> recorded in `convos-assistants` ADR 015. The full cross-repo design and build
> notes live in [`docs/plans/agent-owned-dm-creation.md`](../plans/agent-owned-dm-creation.md);
> this ADR is the durable decision record and documents the iOS as-built.

## Context

An "agent DM" is the private 1:1 channel between a human and an agent it shares
a group with. It is transported as a 2-member MLS group (agent + human, agent is
admin) carrying an `agentDm` marker in `ConversationCustomMetadata` (proto field
8) whose `originConversationId` points at the primary group the pair shares. iOS
renders it as a DM page nested under that primary in the conversation pager.

The first shipped implementation made the **iOS client** the creator: an eager
reconciler (`AgentDmReconciler`, see [`agent-dms.md`](../plans/agent-dms.md)
section 6.4.2) walked verified agents once per app session and created a DM with
any agent it could not find a *verified* DM with. This produced DM pile-up on
Dev TestFlight (field report: convos-ios #1274). The defect is architectural,
not a loop bug: **the client both creates DMs and infers their existence from
lossy local MLS state.** Any client is a poor authority here:

- Multiple devices per user each run the loop and race to create the same DM.
- In-memory dedup (`attemptedAgents`) resets on cold launch, so every launch
  re-attempts creation for agents it cannot find a DM with.
- MLS group creation is non-transactional (create group, then add member), so a
  mid-flight failure strands an orphan group.
- "Existence" is derived from live membership count, which drops to 1 the moment
  the agent leaves - indistinguishable from "never created" - so a departed
  agent looks missing and gets a fresh orphan every launch.

convos-ios #1274 mitigated the *visible* symptom (hidden shells + a cleanup
sweep) but left "attempt-per-launch for dead agents, no durable dedup, no
backoff" intact, now happening silently.

## Decision Drivers

- [x] Dissolve the DM-pile-up bug class rather than mitigate its symptom.
- [x] One durable authority for DM existence, not N racing devices inferring it
      from local state.
- [x] Deterministic placement: a synced DM must nest under exactly one primary
      group with zero client inference.
- [x] Do not silently auto-allow a conversation a peer could forge into
      existence (the marker is member-writable appData).
- [x] Reuse the backend DM registry, atomic per-peer reserve, and revocation
      sweep already built for CON-761 rather than adding parallel machinery.
- [x] Keep iOS backward-compatible: an old client simply stops being the creator
      and receives the agent-created DM via sync.

## Decision

**Flip creation ownership to the agent, and reduce iOS to a pure reflector.** The
agent (server-side, acting through its herald-lite XMTP identity) creates and
owns the DM; every user device receives the one DM via welcome/sync and only
*reflects* it. This is the symmetric other half of the design already
documented: [`agent-dms.md`](../plans/agent-dms.md) section 5.2.1 names the
backend atomic per-peer reserve "the cross-device authority," and section 5.5
already has a server-side *revocation* sweep. Agent-owned creation is the
matching *creation* sweep over the same registry. The client eager reconciler
was the interim wrong turn.

Under agent-owned creation the whole bug class dissolves: one writer (no device
race), existence is a durable server registry row (not inferred from local
state, so cold-launch cannot recreate), a departed peer is `revoked` rather than
missing, a dead peer is backed off in the registry, and the agent creates
atomically as group admin so a failed create leaves a server-side pending row,
not a client-visible shell.

### iOS as-built (what the reflector does)

**Deleted** (the client no longer creates DMs; landed in #1284):

- `ConvosCore/.../AgentBuilder/AgentDmReconciler.swift` and its tests.
- `ConvosCore/.../AgentBuilder/AgentDmFlow.swift`.
- `ConvosCore/.../Sessions/SessionManager+AgentDmReconciler.swift` and its
  start/teardown in `SessionManager`.
- The two former create call sites now **open-existing-or-no-op**:
  `ContactDetailView.handleChatWithAgentDm()` opens the DM via
  `findAgentDm(with:)` if it has synced, else returns (it arrives via sync);
  `AgentDmPageView` shows a disabled "setting up" composer until the DM appears,
  then binds it - no creation path.

**Kept / built** (the reflector surface):

1. **Marker reader** - `agentDmOriginConversationId` (a throwing computed `var`
   on `XMTPiOS.Group` in `XMTPGroup+CustomMetadata.swift`) reads
   `metadata.agentDm.originConversationID`, returning `nil` unless the marker is
   present and the origin bytes are non-empty (otherwise hex-encodes them).

2. **`isAgentDm` classification** (`ConversationWriter.extractConversationMetadata`)
   requires all three: the `agentDm` marker present, exactly 2 members, and a
   member that is an **attested/verified agent** (`anyMemberIsVerifiedAgent` -
   reads `DBProfile.agentVerification.isVerified`, which a human peer cannot
   forge). A one-way `applyingAgentDmLatch` keeps a row classified once it was
   ever locally classified, while it stays 2-member with a verified agent
   present.

3. **Consent auto-allow with a shared-origin gate** (`ConversationWriter`).
   An agent-created DM arrives as a welcome with `unknown` consent. It is
   auto-allowed (`.unknown` -> `.allowed`) only when **both** hold: `isAgentDm`
   is true, and `userStillSharesOrigin(originConversationId:selfInboxId:)` -
   i.e. the marker's origin conversation still exists locally, lists the user as
   a current member, and has no recorded departure. Anything short keeps the
   synced `unknown` consent and surfaces as a normal request. The origin gate is
   what stops a verified agent from forging an auto-allowed DM without a shared
   primary (or one whose primary the user has left/deleted). Consent stays a
   client-side reflector decision; there is no server consent write.

4. **Deterministic placement** - `DBAgentDmOrigin` (`agent_dm_origin` table,
   PK `conversationId` with a foreign key to `conversation` `onDelete: .cascade`,
   plus an `originConversationId` column) persists the DM -> primary link so iOS
   nests the DM page under exactly the marker's origin group with zero
   inference. `record(...)` no-ops on a nil/empty origin so a marker written
   without an origin never clears a good link.

5. **Push-notification suppression + tap routing** (#1271). The DM lane is
   tracked separately from the active conversation because a DM's own id never
   appears in the parent-keyed `activeConversationChanged`: `AgentDmPageView`
   posts `activeDmConversationChanged`, `SessionManager` tracks
   `activeDmConversationId`, and `shouldDisplayNotification(for:)` suppresses a
   banner while its DM is on screen. Taps route through
   `ConversationsRepository.agentDmTapRouting(forConversationId:)` (resolves the
   parent + verified-agent inbox from `DBAgentDmOrigin`) to
   `.selectAgentDmPageRequested`, opening the DM page under its parent rather
   than a bare group page.

## Consequences

### Positive

- The DM-pile-up bug class is gone at the root, not mitigated: no device race,
  no cold-launch recreation, no dead-agent hammering, no orphan shells.
- Placement is deterministic and local: iOS resolves the parent group from the
  marker with no membership inference.
- Auto-allow is safe against a forged marker because it is gated on both an
  attested-agent classification and a live shared origin.
- iOS shed a whole subsystem (reconciler + flow + wiring), reducing surface area.

### Negative / trade-offs

- Cross-repo change (herald primitive + worker loop + iOS reduction) rather than
  a single-repo patch. Deploy order is herald-lite -> convos-assistants ->
  convos-ios; each stage is backward-compatible.
- iOS now depends on the agent to create the DM, so there is a brief window
  after the user opens the agent's DM page before the DM has synced. It is
  handled with a disabled "setting up" composer, not a client-side create.
- Before the marker syncs, iOS cannot classify or place the DM. Tolerated - the
  DM simply is not shown yet; it appears once the welcome/marker arrives.

### Neutral

- The one-time `StrandedConversationSweeper` (#1274) retires the client-created
  orphans/duplicates already on Dev; it can be removed once the fleet is clean.

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
  (full cross-repo design + build notes) and
  [`docs/plans/agent-dms.md`](../plans/agent-dms.md) (the reused transport,
  registry, and revocation design).

## References

Shipped across five PRs: convos-assistants #3191 (Herald `create-dm` + worker
ensure-DM loop), convos-cli #116 (`agentDm` field-8 codec, published 0.10.16),
convos-ios #1284 (reflector reduction), convos-assistants #3193 and #3195 (two
follow-up bug fixes). iOS landings: #1284 (`91a3c7fd`) and #1271 (`c8dde3f5`).

iOS files:

- Marker reader: `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`
  (`agentDmOriginConversationId`).
- Classification + consent gate: `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationWriter.swift`
  (`extractConversationMetadata`, `isAgentDm`, `userStillSharesOrigin`,
  `applyingAgentDmLatch`, `createDBConversation`).
- Origin link: `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBAgentDmOrigin.swift`;
  migration in `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift`
  (`registerAgentDmMigrations`); marker write + deferred record in
  `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift`
  (`markAsAgentDm`).
- Push routing: `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`
  (`shouldDisplayNotification`, `activeDmConversationId`),
  `Convos/ConvosAppDelegate.swift`,
  `Convos/Conversations List/ConversationsViewModel.swift`
  (`routeToTappedConversation`),
  `Convos/Contacts/ContactDetailView.swift`,
  `Convos/Conversation Detail/AgentDmPageView.swift`.
- Tests: `AgentDmTapRoutingTests.swift`, `AgentDmRegressionTests.swift`.
