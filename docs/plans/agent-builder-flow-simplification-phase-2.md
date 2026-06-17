# Agent Builder Flow Simplification — Phase 2 detail

Phase 2 = **agent-creation progress updates**: the in-progress `preview` (draft
agent identity) and `progressPhrases` (build narration) shown after Make while
the generation runs, plus the two creator-facing cards in the chat (the
preserved creation prompt and the progressive "activating" card).

**Status: implemented behind feature flags**, with a local stub standing in for
backend PR **#309** until it merges + deploys. When #309 lands, flip the stub
flag off and delete the stub — the same UI binds to the real fields unchanged.

Context and later phases live in `agent-builder-flow-simplification.md`; the
text/home-flow groundwork is in `agent-builder-flow-simplification-phase-1.md`.
The full backend contract is checked in at
`docs/plans/agent-generation-api.openapi.yaml`.

> Scope note: the in-chat "New Agent" variant turned out to be a one-branch
> change and shipped with Phase 1's groundwork, so it is not its own phase.

## Backend contract + status lifecycle (PR #309)

The generation status envelope (`GenerationStatus`) gains two
**in-progress-only** fields:

- `preview: { agentName, emoji, description }` — the draft identity.
- `progressPhrases: string[]` — build-narration lines.

The temporal status order (from the executor, not the PR description's variant
list) is **`pending` → `running` → `done`** (or `failed`):

- Row created `pending` (`generations-post.ts` create, `status: "pending"`).
- Executor's first action is the atomic claim `pending → running`
  (`generation-executor.ts` `tryClaim`).
- `#309`'s distill runs **after the claim, before generate**, and writes
  `preview` + `progressPhrases` in **one** update while `running`.
- Terminal `running → done` (`markDone`) carries `templateId`;
  `preview`/`progressPhrases` are dropped on the `200`.

Response shapes:

- `202 pending` → `{ status: "pending" }` (nothing else — first state).
- `202 running` → `{ status: "running", preview: {...}, progressPhrases: [...] }`
  (all preview fields + the full phrase list arrive together).
- `200 done` → `{ status: "done", templateId }`.
- `200 failed` → `{ status: "failed", error }`.

Our client already treats `200...299` as success in `decodeGenerationResponse`,
so #309's "GET returns 202 while running" is non-breaking for us.

## Data layer (implemented)

API model (`ConvosCore/.../API/AgentTemplateGenerationModels.swift`):

- New `ConvosAPI.AgentPreview { agentName?, emoji?, description? }`.
- `AgentTemplateGenerationResponse` += `preview: AgentPreview?`,
  `progressPhrases: [String]?` — both optional, decode to `nil`/empty when
  absent (safe before #309).

Domain model (`AgentTemplateGeneration` in `AgentTemplateRepository.swift`):

- += `preview: ConvosAPI.AgentPreview?`, `progressPhrases: [String]`.
- `applyResponse(_:to:)` writes real `preview`/`progressPhrases` from the
  response onto the row; `generationPublisher` maps them into the snapshot, so
  `ConversationViewModel.directBuildGeneration` exposes them with no new
  subscription.

Persistence (`DBAgentTemplateGeneration` + migration
`addAgentTemplateGenerationPreview`, additive/nullable — no erase):

- `previewAgentName`, `previewEmoji`, `previewDescription` (text, nullable).
- `progressPhrases` (text, nullable — JSON-encoded `[String]`).

Persisting (not in-memory) so an in-progress card survives backgrounding /
relaunch, consistent with Phase 1.

## The stub (removable, gated — delete with #309)

`FeatureFlags.isStubbedAgentGenerationProgressEnabled` (dev-only, hard-off in
production; Debug toggle "Stub agent build progress (pre-#309)"). The app sets
it on the repository via `configureStubProgress(_:)` before `startGeneration`.

In `AgentTemplateRepository.applyResponse`, when stubbing is on, the backend
sent no preview, and the row is **`running`**, it synthesizes the whole set
**once** (mirrors #309's single distill write so the card paces identically to
prod — see "single write" below):

- `previewAgentName = "Agent Name"`, `previewEmoji = "🤖"`.
- `previewDescription = "A custom agent built from your idea."` — a fixed
  generic line, intentionally **not** derived from the prompt (echoing the
  prompt looked like a wrong-field reuse in the demo).
- `progressPhrases = stubPhrases` (full canned list at once).

All stub code is tagged `DEBUG(direct-builder #309 stub)`. Removal when #309
ships: flip the flag off, confirm real `preview`/`progressPhrases` flow, then
delete the stub helpers + the flag.

### Why "single write at running" matters

#309 writes preview + the full phrase list in one shot at `running`, so the
content is **stable for the whole `running` window**. The client relies on that:
the activating card's reveal/cycling animation is driven by a view-owned timer,
and stable content means the message-list cell isn't reloaded by polls (the
repo's `agentActivating` `didSet` guards equal content, so no reprocess), so the
timer isn't reset. The stub matches this so behavior is identical with the stub
on or with real #309.

## UI 1 — preserve the creation prompt (implemented)

The "You made a little agent" + prompt card at the top of the chat. Reuses the
existing `MessagesListItemType.agentBuilderSummary(AgentBuilderCardContent)`
rendering — Phase 1 had skipped it.

- On direct Make, `AgentBuilderViewModel.persistCreationPromptCard` writes an
  `AgentBuilderSummary` (prompt only for now; empty `attachments`,
  `connectionIdentifiers`, and `bundledMessageIds` — no XMTP messages to hide)
  and sets it on the inner VM synchronously. The existing
  `makePendingCardContent` path renders it. Works for the in-chat variant via
  the summary's `existingConversation` flag.
- **Lifetime:** rendered on the local-summary path, which is time-boxed to
  `pendingCardDisplayWindow = 180s` and otherwise relies on `rowsLanded` to
  persist. The direct flow has no build messages (`rowsLanded` always false), so
  the card currently shows for **180s** and then disappears. Accepted as the
  first step; relaxing it to persist for the build's lifetime (render from the
  persisted summary without the time-box) is a follow-up.
- **Creator-only:** with no networked build message, the card reconstructs only
  on the creator's client. Other members just see the agent join. (Auto-publish
  / networking the prompt for other members is the open product question in the
  main plan doc.)
- No conflict with Phase 1's pending gate: the `shouldRenderAsPendingAgentBuilder`
  direct bypass runs first, so the summary only feeds the prompt card.

## UI 2 — the progressive "activating" card (implemented)

A dedicated inline message-list card driven by `directBuildGeneration`, sitting
below the prompt card. Built as a **new** `MessagesListItemType.agentActivating`
case (not an extension of the contact card) so the progress bar + caption design
is independent.

Pieces:

- New render model `AgentActivatingCardContent` (ConvosCore) with a coarse
  `phase` (`preparing`/`generating`/`finishing`) derived from the generation
  status, plus `agentName`/`emoji`/`description`/`progressPhrases`.
- New `MessagesListItemType.agentActivating` case (+ every exhaustive switch:
  `id`/`origin`/`alignment`/`cellReuseIdentifier`/`allCellReuseIdentifiers`, the
  cell setup in `MessagesListItemTypeCell`, the SwiftUI `MessagesListView` path,
  and `DefaultMessagesLayoutDelegate` height).
- `MessagesListProcessor.process` takes `agentActivating` and appends the card
  beneath the prompt summary **only while `verifiedAgent == nil`** — so it's
  dropped automatically on join (the contact card takes over).
- `MessagesListRepository.agentActivating` carries it into the processor;
  `ConversationViewModel.syncDirectActivatingCard()` derives the content from
  the generation on each poll (drops it on `failed`).
- New `AgentActivatingCardView` (Convos app): orange emoji avatar + name +
  description + progress bar + caption beneath the card.

### Client phase sequence (paced client-side)

Because preview + phrases arrive together at `running`, the card stages the
reveal on a ~2.5s timer to fill the ~30s build:

1. **`pending` → preparing:** generic placeholder (sparkles glyph, "Activating
   agent", "Agent will join soon"), progress ~12%.
2. **`running` → generating:** placeholder holds for ~2.5s, then **name →
   emoji → description** reveal ~2.5s apart; the caption cycles through
   `progressPhrases` every ~2.5s; progress creeps ~30% → ~85%.
3. **`done`/`invited` → finishing:** full identity, progress ~95%, caption
   "<name> will be great in groupchats."
4. **agent joins (verified member):** processor swaps this card for the real
   agent contact card.

The reveal/pace tunables (`tickSeconds`, progress fractions) live in one
`Constant` enum in `AgentActivatingCardView`. The name reveal is intentionally
delayed one tick so the placeholder shows before the real name.

### Header treatment + home-vs-existing

- The card (body) shows for **both** new and existing chats — its gating is the
  generation existing + no verified agent (not the single-member heuristic).
- The **header** preview identity (title = preview name, subtitle = latest
  progress phrase) is driven by `pendingAgentPresentation` and only applies to
  the **home flow** (so an existing conversation keeps its real name). That
  header branch sets `showsContactCard: false` so it doesn't spawn a second
  contact card alongside the activating card.
- Existing-chat caveat: the body card clears on the agent **verifying** (the
  `verifiedAgent` gate). A precise "this agent vs pre-existing members" join
  signal (new-member-since-baseline) is still deferred — fine here because the
  processor's `verifiedAgent == nil` gate handles the clear.

## Related fix — authenticated template fetch (draft 404)

Builder-flow templates land as `draft` (owner-only). `getAgentTemplate` was an
**unauthenticated** GET, so the backend couldn't match the owner and returned
404 for the user's own drafts (seen as `AgentTemplateCacheCoordinator` fetch
failures). Fixed by switching `getAgentTemplate` to `authenticatedRequest`;
no-op for published templates (visible either way). Behavior-preserving; the
auto-publish-into-a-group question is tracked in the main plan doc.

## Resolved decisions

- Persist `preview`/`progressPhrases` (not in-memory) — survives relaunch.
- Stub gated by a dedicated `FeatureFlags` toggle (explicit, single removal).
- Preview is **emoji, not avatar** — emoji is the pending visual; the real photo
  arrives post-join from the template.
- Activating card = a **new `MessagesListItemType` case**, not an extension of
  the contact card.
- Card ordering: prompt card above, activating card below.
- Reveal/cycle paced **client-side** (server writes everything at once).

## Open items / feedback for PR #309

- **`progressPhrases` pacing:** confirm they're meant as a client-paced set
  (we cycle them) vs server-revealed. We assume client-paced.
- **No avatar in `preview`** (emoji only) — confirm intended; otherwise the
  pending card can't show a photo until join.
- **preview ↔ final-template consistency:** the `done` template's
  `agentName`/`emoji` should equal the `preview` so the card→contact-card
  hand-off doesn't flicker.
- **202-for-GET** is a contract change — ensure it's documented for the other
  consumers (skill/website/twitter-bot).

## Acceptance checks

1. Stub on: after Make the activating card appears, reveals name → emoji →
   description over `running`, cycles phrases, and hands off to the contact card
   on join.
2. The prompt card ("You made a little agent") shows for the 180s window in both
   home and in-chat flows.
3. Data survives backgrounding / relaunch mid-build (persisted columns).
4. Stub off + #309 not deployed: builds still complete; the card shows a generic
   (no-identity) version and degrades cleanly.
5. #309 deployed (stub off): the same fields populate from the real response
   with no client change beyond the flag.
6. No regression to terminal handling or to the legacy maker (flag off).

## Still out of scope (later phases)

- `inputs.attachments[]` + presigned upload (PR #310) — Phase 5 (media); the
  prompt card + `AgentBuilderSummary` already support attachments for when it
  lands.
- `connections[]` + `GET /connections/services` (PR #311) — Phase 5.
- Networking the prompt card to other members; the precise existing-chat join
  signal; relaxing the prompt-card 180s lifetime.
