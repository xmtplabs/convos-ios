# Credits UI — Upgrade Sheet + Power Status + Home Pill

## Context

Courter's design spec reimagines the subscription and credits experience
across three surfaces: a redesigned upgrade sheet (paywall), an
in-conversation "lost power" status with contextual upgrade prompts,
and a membership/power status indicator in the home toolbar. The old
LowBalanceBanner, credits pill, and NUX paywall are replaced.

## Status

| Step | Status |
|---|---|
| Step 1: Model rename (Builder -> Plus, remove Pro) | Done |
| Step 2: SubscriptionCopy rewrite | Done |
| Step 3: PaywallViewModel changes | Done |
| Step 4: PaywallView rewrite + delete TierCard | Done |
| Step 5: Remove old credits UI (pill, banner, NUX paywall) | Next |
| Step 6: In-conversation "lost power" status (Phase 1) | Next |
| Step 7: "You power your agents" info sheet | Next |
| Step 8: Home toolbar membership/power status | Next |

## Completed Work

### Upgrade Sheet Redesign

Single scrolling view with Basic/Plus plan picker. Custom draggable
segmented price picker. Period switch triggers in-app purchase for
subscribers. colorLava (#FC4F37) throughout. TightLineHeightText for
hero. Three Xcode preview states.

### Removals Already Done

- TierCard.swift deleted
- Credits pill (CreditsBadge) hidden from home toolbar
- NUX paywall on conversation entry skipped
- Close button on paywall sheet removed

## Remaining Work

### Step 5: Remove old credits UI completely

Delete:
- `Convos/Subscription/LowBalanceBanner.swift`
- `Convos/Subscription/CreditsBadge.swift`

Remove LowBalanceBanner from:
- `Convos/Conversation Detail/ConversationView.swift` line ~320
  (messagesPageContent VStack)

### Step 6: In-conversation "lost power" status (Phase 1)

**Figma**: 2909-30729, 2909-30882

Inline status in the conversation, positioned where LowBalanceBanner
was (top of messagesPageContent, above messagesView). Centered,
not a real XMTP message.

**Creator view** (credits depleted + conversation has agent they created):
- "⚡ Hoodrat lost power" — footnote, colorTextSecondary, bolt in
  colorLava
- [Upgrade] pill — compact, colorLava background, white text,
  rounded capsule. Tapping opens PaywallView sheet.

**Non-creator view** (Phase 2, needs backend — stub for now):
- "⚡ Hoodrat lost power" — same text
- [Learn more] — subtle text button, opens AgentPowerInfoView sheet

**Display logic:**
- Show when: CreditsServices.shared.currentBalance?.isDepleted AND
  conversation has an agent whose creator matches current user inboxId
- Hide when: balance > 0

**File**: new `Convos/Subscription/AgentLostPowerStatus.swift`

### Step 7: "You power your agents" info sheet

**Figma**: 2909-31202

Self-sizing sheet following AssistantsInfoView pattern. Presented via
`.selfSizingSheet`.

**Layout:**
- "You power your agents" — TightLineHeightText(40, 40)
- "Agents use Power to think and act" — body.bold
- "If they run out of power credits, they switch into read-only
  mode." — body, colorTextSecondary
- "An agent's creator controls its power" — body.bold
- "[CreatorName] can restore power to [AgentName]" — body,
  colorTextSecondary
- [⚡ View your usage] — black full-width rounded button

**File**: new `Convos/Subscription/AgentPowerInfoView.swift`

Presentation: from [Learn more] in the non-creator status (Phase 2).
Built now as standalone component.

### Step 8: Home toolbar membership/power status

**Figma**: 2909-32907, 2909-32922

The Convos toolbar button in the home screen (ConversationsView)
shows a status line below "Convos":

| State | Label | Color |
|---|---|---|
| Free user (no subscription) | "Basic" | colorTextSecondary |
| Plus subscriber | "Plus" | colorTextSecondary |
| Credits depleted | "⚡ No power" | colorLava |

The status reads from CreditsServices + SubscriptionServices:
- `isDepleted` -> "⚡ No power" (takes priority)
- `isSubscribed` -> "Plus"
- else -> "Basic"

**File**: modify `ConvosToolbarButton` in
`Convos/App Settings/AppSettingsView.swift` (or extract to own file)
to accept a status string + color.

## Verification

1. Build: Convos (Dev) scheme
2. Tests: swift test --package-path ConvosCore
3. Visual: conversation with depleted credits + agent -> see
   "lost power" status
4. Visual: home screen shows "Basic" / "Plus" / "⚡ No power"
5. Confirm: LowBalanceBanner and CreditsBadge fully removed
6. Lint before committing
