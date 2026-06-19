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
  prompt-only; attachments still go via the generation API).
- [x] **Don't deliver the chat prompt to the agent (avoid double reply).** With
  `awaitsAgentJoin: true` (legacy default) the prompt publish was held until the
  agent joined, so the agent received it post-join and replied -- on top of its
  build/welcome message, giving two agent messages. Since the direct-flow agent
  already built from this prompt via the generation API, it must not receive it
  again. Changed the direct flow's `sendBuilderBundle` to `awaitsAgentJoin:
  false`: the prompt publishes pre-join (an epoch the joining agent can't read),
  so it shows + persists for the user and the card anchors to it, but the agent
  doesn't double-reply. Also removes the `UnsentBuilderBriefReplayer` re-fire
  window (no hold).

- [x] **Copy the prompt from the creation card.** The prompt renders inside the
  "You created an agent" card (it's bundled, not a real message bubble), so
  long-press did nothing. Rather than turn it into a message bubble, added a
  long-press `.contextMenu` on the card (`AgentBuilderSummaryView`) with a Copy
  action that copies `content.prompt` (shown only when the prompt is non-empty).
  No reactions -- a card can't hold them -- just Copy.

- [x] **Activating card resurrects after the agent is removed.** Create -> agent
  joins (card disappears) -> remove the agent -> the loading card came back and
  never left. Cause: the card is gated on "no verified agent present", but the
  generation row persists as `.invited`; removing the agent re-opens that gate
  on the still-present row (and `directBuildAgentJoined` is membership-based, so
  it resets too). Fix: when the built agent has joined + verified
  (`syncVerifiedAgentToRepo` sees a verified Convos agent while a direct
  generation exists), the repository's new `clearGeneration(conversationId:)`
  deletes the persisted row. The generation publisher then emits nil, the
  activating card clears, and it can't resurrect on removal or relaunch (durable,
  no row to re-show).

- [x] **Activating card stuck forever when the agent never joins.** The repo
  bounds submit/poll (they mark the generation `failed`, clearing the card), but
  once the join is issued (`done`/`invited`) nothing verified the agent actually
  appeared -- if provisioning/attestation stalled, the card lingered forever
  (especially bad in an existing group). Added a one-shot join-timeout backstop
  in `ConversationViewModel` (`directBuildJoinTimeout = 180s`, armed when the
  generation reaches `done`/`invited`): if no verified agent has joined by the
  deadline it clears the activating card and the persisted row
  (`clearGeneration`). Cancelled when the agent joins or the build fails;
  self-heals across relaunch (a stuck `.invited` re-arms a fresh timeout).

- [x] **Network attachments to other members (existing groups only).** Legacy
  showed the prompt + attachments to every member; the direct flow only uploads
  attachments to the generation API (creator-only chips). For the in-chat
  variant (`targetsExistingConversation`) where there's an audience, also send
  the photos/voice as the legacy encrypted bundle via `innerVM.sendBuilderBundle`
  (prompt + bundle, `awaitsAgentJoin: false` so the agent -- already built from
  the API copy -- doesn't receive them). Skipped for the home flow: a new
  conversation has no other members during the build and later-invited members
  can't decrypt pre-join messages, so it would be a wasted second upload. The
  bundle's `bundleMessageId` joins the summary's `bundledMessageIds` so the card
  represents it; `sendBuilderBundle` clears the staged attachments + resets the
  voice recorder itself (chips hidden via `isAwaitingBuilderBundleSend`), so the
  home-flow `cleanupPendingMediaAttachments` path is the else-branch only.

- [ ] **Known pre-existing limitation: recipient builder-card image chips are
  blank on iOS.** When attachments are networked to an existing group, other iOS
  members reconstruct the card but the photo chip renders blank. Root cause is
  pre-existing (legacy maker has the same gap): the chip loads only from
  `ImageCache` by `key` (`imageAsync` is cache-only, no remote download/decrypt),
  the bundle message is hidden so normal attachment rendering never fetches it,
  and `HydratedAttachment` carries no `RemoteAttachment` params (url/secret/salt/
  nonce). The send is correct (old Android build renders the image). Deferred --
  fixing it means threading the decryption params into `HydratedAttachment` + a
  remote-decrypt loader in the chip (or registering the hidden bundle attachment
  with `ImageCache`); a separate bug/PR, not direct-builder scope.

- [x] **Recipient attribution line + card widths.** (1) For other members, the
  "&lt;name&gt; created an agent" line now appends " • They'll join soon" (they have
  no activating card, so this gives them the join context). Resolved in
  `AgentBuilderSummaryView.footerText` (non-creator case only). (2) The prompt
  card and the activating card stretched edge-to-edge; constrain both to the
  message-bubble width to match the contact card / text bubbles -- wrapped each
  in `HStack { card; Spacer().frame(minWidth: 50).layoutPriority(-1) }
  .bubbleRowWidthCap(alignment: .leading).padding(.leading, step4x)`, with the
  footer/caption kept centered (full width).
- [x] **"What needs done?" prompt-card header + composer hint.** (1) The prompt
  card (creator and recipient) now leads with a gray "What needs done?" label in
  the prompt-text style, a gap, then the prompt text -- added to
  `AgentBuilderSummaryView.cardContent` as a `Text(Constant.promptHeader)`
  (`.colorTextSecondary`) above the prompt `Text`, wrapped in a nested
  `VStack(spacing: step4x)` for the empty-line gap; only shown when the prompt is
  non-empty. (2) The maker composer's idle placeholder changed from "Make a new
  agent" to "What needs done?" (text only, no style change) in
  `AgentDraftComposer.textFieldPlaceholder`.
- [x] **Prompt-card attribution: creator avatar + middle dot + "made" copy.**
  (1) The footer now renders the creator's avatar in front of the text, matching
  the "Agent is present · Invited by <name>" row -- swapped the plain `Text` for
  `TextTitleContentView(title:profile:)` (16pt `MessageAvatarView` + caption).
  (2) Copy: self reads "You made an agent · They'll join soon" (was "You created
  an agent", no avatar/hint); others read "<name> created an agent · They'll join
  soon". (3) Bullet `•` changed to the middle dot `·`. The avatar profile is a
  new `AgentBuilderCardContent.creatorProfile`, resolved in `MessagesListProcessor`
  from the build-message sender (`makeCardContent`) or, for the creator's own
  pending card, from the build-message / current-user sender in `rawMessages`
  threaded into `makePendingCardContent`.

- [x] **Prompt card uses the reply-reference box style (no liquid glass).** The
  card dropped the liquid-glass fill + matched-geometry morph in favor of the
  same bordered box as `ReplyReferenceView.replyTextPreview`: a 1pt
  `.colorBorderSubtle` `RoundedRectangle` (radius 20), no fill, no glass.
  Removed `AgentBuilderSummaryView.transitionNamespace`, the `card` glass
  branch (`glassEffectID` / `glassEffectTransition`), and the
  `GlassEffectContainer`; the Make call site in `MessagesListItemTypeCell` no
  longer passes a namespace. Per the chosen option, the morph-in animation is
  dropped (the card appears with the standard cell transition). Follow-up (not
  done): the now-orphaned `agentBuilderTransitionNamespace` plumbing
  (AgentBuilderView -> ... -> CellFactory) and `AgentBuilderCardContent.transitionEligible`
  are write-only dead code that a later cleanup can remove.

- [x] **Prompt + activating cards align with message bubbles (avatar gutter).**
  Both cards were inset only by `step4x`, so they sat one avatar-gutter to the
  left of incoming message bubbles (which reserve room for the sender avatar).
  Bumped each card's leading inset to `smallAvatar + step2x + step4x` (the
  `avatarWidth + step4x` pattern `MessagesGroupView` already uses to align
  non-bubble content), so the cards line up with the message column and share the
  same width treatment. Added as `Constant.leadingInset` in both
  `AgentBuilderSummaryView` and `AgentActivatingCardView`.
- [x] **Fix card over-indentation (cell already pads horizontally).** The first
  alignment pass double-counted `step4x`: the `MessagesListItemTypeCell` already
  wraps both cards in `.padding(.horizontal, step4x)`, so adding `step4x` inside
  the card pushed them one row-padding past the message column. Reduced
  `leadingInset` to just the avatar gutter (`smallAvatar + step2x`); the cell
  supplies the `step4x`, so the total now matches the message bubbles' leading.
- [x] **Activating card: one more description line.** Bumped
  `descriptionLineCount` 4 -> 5 (and the hidden sizer placeholder) so the full
  generated description fits without truncation.
- [x] **No keyboard on landing in the conversation from the maker.** On Make, the
  home flow handed focus to the chat input (`moveFocus(to: .message)`) to keep
  the keyboard up; since nothing can be sent until the agent builds + joins, this
  now drops focus (`moveFocus(to: nil)`) so the conversation opens with the
  keyboard down. The existing-conversation flow dismisses the maker sheet back to
  the original `ConversationView`, which was restoring `.message` focus on
  dismiss; added `onDismiss: { focusCoordinator.moveFocus(to: nil) }` to that
  sheet so the keyboard stays down there too.

## Still out of scope (later phases)

- `inputs.attachments[]` + presigned upload (PR #310) — Phase 5 (media); the
  prompt card + `AgentBuilderSummary` already support attachments for when it
  lands.
- `connections[]` + `GET /connections/services` (PR #311) — Phase 5.
- Networking the prompt card to other members; the precise existing-chat join
  signal; relaxing the prompt-card 180s lifetime.
