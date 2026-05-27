# Credits UI — Upgrade Sheet + In-Conversation Power Status

## Context

Courter's design spec reimagines the subscription and credits experience
across two surfaces: a redesigned upgrade sheet (paywall), and an
in-conversation "lost power" status with contextual upgrade prompts.
The old LowBalanceBanner, credits pill, and NUX paywall are replaced
by these new patterns.

## Status

| Step | Status |
|---|---|
| Step 1: Model rename (Builder -> Plus, remove Pro) | Done |
| Step 2: SubscriptionCopy rewrite | Done |
| Step 3: PaywallViewModel changes | Done |
| Step 4: PaywallView rewrite + delete TierCard | Done |
| Step 5: Remove old credits UI (pill, banner, NUX paywall) | In progress |
| Step 6: In-conversation "lost power" status (Phase 1) | Next |
| Step 7: "You power your agents" info sheet | Next |

## Completed Work

### Upgrade Sheet Redesign

Single scrolling view with Basic/Plus plan picker replacing the old
side-by-side TierCards with Monthly/Annual segmented picker.

Layout:
- "Membership" label + "Power your agents" hero (TightLineHeightText)
- Segmented Basic / Plus picker
- Feature rows: "Make unlimited agents" (custom A-star icon on black
  circle) + "Usage maximum" / "Unlimited usage" (bolt icon, conditional)
- Example uses section (plan-specific outcomes)
- Custom draggable segmented price picker (Monthly / Annual) with
  white sliding thumb on colorFillSubtle background
- CTAs: "Stay Basic" / "Upgrade" / "Switch to Yearly" / "Manage
  subscription" depending on state
- "Auto-renews monthly . Cancel anytime" / "You subscribe to Plus
  Monthly" status lines
- Terms & Privacy + Restore footer

Colors: colorLava (#FC4F37) throughout (not colorRed).
Typography: body.medium for feature headlines, footnote for sub-text.

### Removals (Done or In Progress)

- TierCard.swift: deleted
- Credits pill (CreditsBadge in home toolbar): hidden
- NUX paywall on conversation entry: skipped
- Close button on paywall sheet: removed

## Remaining Work

### Step 5: Remove old credits UI completely

**Delete or gut these files:**
- `Convos/Subscription/LowBalanceBanner.swift` — remove entirely.
  The in-conversation "lost power" status replaces it.
- `Convos/Subscription/CreditsBadge.swift` — remove entirely.
  Already hidden from the toolbar; the file is now dead code.

**Remove LowBalanceBanner usage from:**
- `Convos/Conversation Detail/ConversationView.swift` — find where
  LowBalanceBanner is rendered and remove the view + its state
- Any other surfaces that show LowBalanceBanner

### Step 6: In-conversation "lost power" status (Phase 1 — creator only)

**Figma**: node 2909-30729

An inline status element in the conversation message list that appears
when the current user's credits are depleted AND the conversation has
an agent they created. NOT a real XMTP message — a local-only UI
element driven by credit state, like the typing indicator or unread
divider.

**Display logic:**
- Show when: `CreditBalance.isDepleted == true` AND the conversation
  contains an agent whose creator matches the current user's inboxId
- Hide when: credits are replenished (balance > 0) or user navigates
  away

**Layout (centered in message list area):**
- "⚡ [AgentName] lost power" (footnote, colorTextSecondary, bolt
  icon in colorLava)
- [Upgrade] button (colorLava pill, compact — NOT full width)
- Tapping Upgrade opens the PaywallView sheet

**Placement:** rendered as a trailing element after the last message
in the messages list, before the compose bar. Could be an item in
the messages list data source with a special type, or an overlay
pinned above the compose bar.

**What we know locally:**
- Current user's credit balance via `CreditsServices.shared`
- Which members are agents via the conversation's member list
- The agent's creator inboxId (already stored on the agent profile)

**Phase 2 (needs backend — not this PR):**
- Non-creators see "⚡ Hoodrat lost power" + [Learn more]
- Backend pushes agent power state to group members
- "Quarter restored Hoodrat's power" status when credits refill

### Step 7: "You power your agents" info sheet

**Figma**: node 2909-31050

A self-sizing info sheet following the same pattern as
`AssistantsInfoView.swift`. Presented via `.selfSizingSheet`.

**Layout (top to bottom):**
- "You power your agents" — TightLineHeightText(fontSize: 40,
  lineHeight: 40)
- "Agents use Power to think and act" — body.bold
- "If they run out of power credits, they switch into read-only
  mode." — body, colorTextSecondary
- "An agent's creator controls its power" — body.bold
- "[CreatorName] can restore power to [AgentName]" — body,
  colorTextSecondary
- [⚡ View your usage] button — black, full width, rounded

**File:** `Convos/Subscription/AgentPowerInfoView.swift` (new)

**Presentation:** from the [Learn more] button on the non-creator
"lost power" status (Phase 2), and potentially from the agent
profile's power section.

Note: Phase 1 only needs the creator's [Upgrade] path. The info
sheet can be built now as a standalone component for Phase 2
readiness, or deferred entirely.

## Verification

1. Build: Convos (Dev) scheme
2. Tests: `swift test --package-path ConvosCore`
3. Visual: Settings -> Subscription -> Subscribe (all 3 preview states)
4. Visual: Enter a conversation with a mock-depleted agent creator
   preset — see the "lost power" inline status
5. Mock presets: cycle through debug presets, confirm paywall +
   conversation status render correctly
6. Confirm: LowBalanceBanner and CreditsBadge are fully removed,
   no dead references
7. Lint before committing
