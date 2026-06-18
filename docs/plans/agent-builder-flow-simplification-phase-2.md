# Agent Builder Flow Simplification — Phase 2 detail

Phase 2 = **agent-creation progress updates**: the in-progress `preview` (draft
agent identity) and `progressPhrases` (build narration) shown after Make while
the generation runs, plus the two creator-facing cards in the chat (the
preserved creation prompt and the progressive "activating" card).

**Status: implemented and using the real API.** Backend PR **#309** is
deployed on Dev, so the temporary stub (and its feature flag) has been
**removed** — the activating card is now driven entirely by the real
`preview`/`progressPhrases` poll responses. The direct builder always shows the
in-progress card during a build (gated only on `directBuildGeneration` existing
and no verified agent having joined yet). The direct-builder flag
(`isDirectAgentBuilderEnabled`) still gates the whole flow.

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

## Stub removed (#309 is live)

The temporary stub, its `FeatureFlags` toggle, the `configureStubProgress`
plumbing, and the canned preview/phrases have all been **deleted** now that #309
is deployed on Dev. The card is driven entirely by the real
`preview`/`progressPhrases` from `applyResponse`. Before the backend writes the
preview (during `pending` and the very start of `running`), the fields are
`nil`/empty and the card shows its generic placeholder; once the real preview
lands at `running`, it fills in.

### Why "single write at running" matters

#309 writes preview + the full phrase list in one shot at `running`, so the
content is **stable for the whole `running` window**. The client relies on that:
the activating card's reveal/cycling animation is driven by a view-owned timer,
and stable content means the message-list cell isn't reloaded by polls (the
repo's `agentActivating` `didSet` guards equal content, so no reprocess), so the
timer isn't reset.

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
- The build-progress stub + its `FeatureFlags` toggle were removed once #309
  deployed; the card now runs on the real poll responses.
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

1. After Make the activating card appears immediately (generic placeholder),
   then — once the real `running` poll returns `preview` — reveals name → emoji
   → description, cycles `progressPhrases`, and hands off to the contact card on
   join.
2. The prompt card ("You made a little agent") shows for the 180s window in both
   home and in-chat flows.
3. Data survives backgrounding / relaunch mid-build (persisted columns).
4. If the backend ever returns no preview (e.g. distill best-effort failure),
   the card stays on its generic version and the build still completes.
5. No regression to terminal handling or to the legacy maker (flag off).

## UI feedback checklist

Running list of UI feedback on the in-progress build screen, checked off as
resolved.

- [x] **Header subtitle copy + behavior.** Initial title `Agent` is fine, but the
  subtitle should read `Making agent...` (not `Joining...`) and stay static for
  the whole build instead of cycling the progress phrases. It flips to the member
  count (`2 members`) once the agent joins. Resolved in
  `ConversationViewModel.conversationInfoSubtitle` (static `Making agent...` while
  `shouldRenderAsPendingAgent`).
- [x] **Activating card chrome + fixed height.** The in-progress card had no
  visible border, so it read like a flat message rather than a card. Give it the
  same border/shadow as the finished contact card, and a fixed height so the
  description has reserved whitespace before it reveals (no layout jump).
  Resolved in `AgentActivatingCardView`: wrapped in `GlassEffectContainer` +
  `.glassEffect(.regular.interactive(), in: .rect(cornerRadius:))` to match
  `AgentContactCardView`. Fixed height uses a **hidden sizer** in a `ZStack`
  (an empty `Text` collapses even with `reservesSpace`, so the sizer holds a
  ~140-char wrappable placeholder at `descriptionLineCount = 4` lines) with the
  real description overlaid on top — the card height never changes when the
  description reveals. `descriptionLineCount` is adjustable.

- [x] **Match the agent color (not orange).** The activating card used a generic
  `Color.orange` accent (avatar circle, progress bar, caption). Switch it to the
  verified-Convos-agent color `.colorLava` (`#fc4f38`) so it matches the avatar
  background + name color of the finished `AgentContactCardView` (via
  `AgentVerification.avatarBackgroundColor`). Resolved in
  `AgentActivatingCardView.Constant.accent` — the single accent token drives all
  three usages.

- [x] **Move "You created an agent" above the prompt.** The creation-prompt card
  showed the prompt with the "You created an agent" / "<name> created an agent"
  caption *below* it; move that caption *above* the prompt card. Resolved by
  reordering the `VStack` in `AgentBuilderSummaryView` (footer text first, card
  second). Note: this view is shared with the legacy maker, so the reorder
  applies to both flows.

- [x] **Reveal order: emoji → name → description.** The staggered reveal was
  name → emoji → description; change to emoji → name → description (description
  last, unchanged). Resolved in `AgentActivatingCardView` by swapping the
  `revealStage` thresholds (`showsEmoji >= 1`, `hasName`/`title >= 2`).

- [x] **Caption rotation rules.** Instead of cycling every API phrase, alternate:
  start with an API progress phrase, then every other message is the reassurance
  line ("Agent will join soon", or "<name> will join soon" once the name is
  revealed); and once the progress bar plateaus near the end, stop alternating
  and hold "<name> will join soon". Resolved in `AgentActivatingCardView.caption`
  (even ticks = API phrase, odd ticks = `joinSoonText`; pinned to `joinSoonText`
  when `progressFraction >= generatingMax`). Note: "near the end" uses the
  progress-bar plateau as a proxy because `estimatedDurationMs` isn't wired into
  the client yet — wiring it would make this precise.

- [x] **Header stays generic during the build (no preview in header).** The header
  used to flip to the preview name + emoji the instant the response arrived, out
  of sync with the card's progressive reveal. Decision: keep the header constant
  — title "Agent", add-agent glyph, subtitle "Making agent..." — for the whole
  build, and only adopt the real name/emoji when the agent joins. The
  progressive reveal lives solely on the `.agentActivating` card. Resolved by
  removing the direct-builder preview branch in
  `ConversationViewModel.pendingAgentPresentation` so it falls through to the
  generic no-identity pending case. Default title is "New Agent" (matches the
  conversation list) via `untitledConversationPlaceholder`. (Considered a header
  reveal synced to the
  card, but the card's reveal is a view-local timer with deliberately stable
  content, so syncing would need a parallel reveal clock + header gating;
  not worth it for this.)

- [x] **"Agent joined" row: keep it showing (suppression removed).** Originally
  the builder flow hid the "X joined" row (which also caused a brief flash since
  the gate only fired after agent attestation). Decision reversed: we want the
  join row to always show. Removed the `isInAgentBuilderFlow` suppression filter
  in `MessagesListProcessor` entirely, so the row renders in every flow. The
  flash is moot (the row no longer appears-then-vanishes; it just stays), and the
  ordering fix below keeps it correctly positioned below the creation card.
  (`isInAgentBuilderFlow` is now an unused param, left in place to avoid churning
  the public `process` signature + callers/tests.)

- [x] **"Agent joined" row sorted above the creation card.** After leave/rejoin
  the "<agent> joined - Invited by You" row appeared above the "You created an
  agent" card and the messages. A timestamp diagnostic confirmed the join's
  `sentAt` is actually correct (after Make) -- so this was a positioning bug, not
  a bad timestamp: `insertSummaryCard` placed the card relative to `.messages`
  groups only and ignored `.update` rows, so a post-Make membership update that
  preceded the next message group floated above the card. Fix: `insertSummaryCard`
  now also honors `.update` row dates (looked up from the raw messages, since the
  `.update` item doesn't carry its date), so post-Make joins sort below the card.
  Verified it preserves the "summary stays above the contact card" invariant for
  the pre-Make-join case.

- [x] **Caption color by type.** The "<name> will join soon" reassurance line
  keeps the lava accent (`.colorLava`); the dynamic API progress phrases now use
  the grayish secondary color. Resolved in `AgentActivatingCardView` via
  `captionColor` (grayish for `captionIsProgressPhrase`, lava otherwise). Used
  `.colorTextSecondary` for the grayish tone (matches the card's description
  text) -- swap to a specific accent token if that's what "first accent color"
  meant.

- [x] **Send the prompt as a message (legacy parity).** The direct flow only
  sent the prompt to the generation API; now it also sends it into the
  conversation as a real message, like the legacy flow. Confirmed the legacy
  send path exists and is reusable: `OutgoingMessageWriter.sendBuilderBundle`
  cleanly ships text-only when the attachment bundle is empty (manifest =
  `[textMessageId]`, gated on the agent joining). Wired in
  `AgentBuilderViewModel.startDirectGenerationIfReady`: pre-allocate a prompt
  client message id (nil for an attachment-only build), put it in the summary's
  `bundledMessageIds` so the creation-prompt card represents the sent message
  (and persists past the 180s window / across relaunch via
  `reconstructBuilderCards`), then call `innerVM.sendBuilderBundle(text:…,
  awaitsAgentJoin: true)` after the staged attachments are cleared (so it ships
  prompt-only; attachments still go via the generation API). Note: the agent now
  receives the prompt both via the API build and as a chat message on join --
  expected for legacy parity.

## Still out of scope (later phases)

- `inputs.attachments[]` + presigned upload (PR #310) — Phase 5 (media); the
  prompt card + `AgentBuilderSummary` already support attachments for when it
  lands.
- `connections[]` + `GET /connections/services` (PR #311) — Phase 5.
- Networking the prompt card to other members; the precise existing-chat join
  signal; relaxing the prompt-card 180s lifetime.
