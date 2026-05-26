# Upgrade Sheet Redesign: Basic vs Plus

## Context

Courter's design spec reimagines the paywall/upgrade sheet from "pick a tier from side-by-side cards" to a "Basic vs Plus comparison" view. The current implementation shows Builder and Pro as separate TierCards with a Monthly/Annual segmented picker. The new design shows a single scrolling view with a Basic/Plus plan picker, inline feature comparison, and a pricing row with Monthly/Annual price pills.

This is scoped to ONLY the upgrade sheet UI. Power usage views, agent profiles, chat indicators, home status pill, and member preview changes come later.

## Key Design Changes (from Figma)

| Current | New |
|---|---|
| Segmented Monthly/Annual picker at top | Segmented Basic/Plus plan picker at top |
| Two TierCards (Builder + Pro) stacked vertically | Single view toggling content per selected plan |
| Each TierCard has its own CTA button + price | Pricing row with two selectable pills (Monthly/Annual) — Plus only |
| Builder and Pro both purchasable | Only Plus is purchasable; Basic is the free comparison state |

**New layout (top to bottom):**
1. Hero ("Power your agents")
2. Plan picker: Basic / Plus (segmented)
3. Credit headline + lightning bolt icon (red for Plus, dim for Basic)
4. Feature list with checkmark rows (content changes per plan)
5. Pricing pills — Monthly and Annual side-by-side (Plus only)
6. Red "Upgrade" CTA (Plus, non-subscriber) / "Manage subscription" (subscriber)
7. Legal footer (Terms, Privacy, Restore)

## Implementation Steps

### Step 1: Model layer — rename Builder → Plus, remove Pro

Single atomic commit across ConvosCore + app target so the build stays green.

**Files:**
- `ConvosCore/.../Storage/Models/Subscription.swift` — rename `case builder` to `case plus`, remove `case pro`, add backward-compatible `init(from:)` that decodes both `"builder"` and `"pro"` as `.plus`
- `ConvosCore/.../Services/Subscription/SubscriptionProductIDs.swift` — rename constants (`builderMonthly` → `plusMonthly`, `builderAnnual` → `plusAnnual`), remove `proMonthly`, keep the actual string product IDs unchanged (`"app.convos.subs.builder.monthly"` etc.), update `tier(for:)` mapping to return `.plus`, remove `.pro` branches
- `ConvosCore/.../Services/Credits/CreditsStatePreset.swift` — rename `builderAmple` → `plusAmple`, `builderLow` → `plusLow`, `builderDepleted` → `plusDepleted`, remove `proAmple`, update `subscription()` + `balance()` + `displayName` helpers, add backward-compat `init?(rawValue:)` mapping old names
- `ConvosCore/.../Services/Subscription/MockSubscriptionService.swift` — update mock products to `.plus`, remove Pro product, update preset mapping
- `Convos/Subscription/SubscriptionSettingsView.swift` — update preview presets
- `Convos/Subscription/LowBalanceBanner.swift` — `.builderDepleted` → `.plusDepleted` etc.
- `Convos/Config/FeatureFlags.swift` — default preset reference
- `ConvosCore/Tests/.../MockSubscriptionServiceTests.swift` — rename `.builder`/`.pro` → `.plus`
- `ConvosCore/Tests/.../TestStubAPIClientDefaults.swift` — if tier refs exist
- `ConvosTests/PaywallViewModelTests.swift` — `.builder` → `.plus` in test product

### Step 2: SubscriptionCopy rewrite

Rewrite `Convos/Subscription/SubscriptionCopy.swift` for the new content structure:

- Keep `heroTitle` ("Power your agents") and `heroSubtitle`
- Add a `PaywallPlan` enum (`.basic`, `.plus`) — view-layer concept, not a model-layer tier. Basic represents "no subscription" shown for comparison.
- `creditHeadline(for: PaywallPlan)` → "No monthly credits" / "100,000 credits/month"
- `outcomes(for: PaywallPlan)` → smaller-scope examples for Basic, richer for Plus
- Shared features list ("Make unlimited agents")
- Keep `displayName(for: SubscriptionTier)` returning "Plus" (used by SubscriptionSettingsView)
- Keep `legalDisclaimer`

### Step 3: PaywallViewModel changes

Update `Convos/Subscription/PaywallViewModel.swift`:

- Replace `selectedPeriod: SubscriptionPeriod` with `selectedPlan: PaywallPlan` (default `.plus` when entering via upgrade door, `.basic` when browsing)
- Add `selectedProduct: PaywallProduct?` — the product the CTA purchases (defaults to monthly after load)
- Add `plusMonthlyProduct` / `plusAnnualProduct` computed properties
- `isAlreadySubscribed: Bool` computed from `currentSubscription != nil`
- `selectProduct(_:)` method for the pricing pill tap
- Keep `purchase(product:)` and `loadProducts()` as-is
- Remove `product(for:period:)` (no longer needed externally) or keep as private
- Remove `currentTier` (unused, was already flagged)

Update `ConvosTests/PaywallViewModelTests.swift` — rename test product, update assertions.

### Step 4: PaywallView rewrite + delete TierCard

**Delete** `Convos/Subscription/TierCard.swift` — the new design has no card concept.

**Rewrite** `Convos/Subscription/PaywallView.swift` with extracted `@ViewBuilder` sections:

```
NavigationStack > ScrollView > VStack:
  hero                    — kept (same as current)
  planPicker              — segmented Basic/Plus
  creditHeadline          — "100,000 credits/month" or "No monthly credits" + bolt icon
  featureList             — checkmark rows, content switches on plan
  pricingRow              — two selectable pills (Monthly + Annual), Plus only
  ctaSection              — "Upgrade" / "Manage subscription" / empty for Basic
  legal                   — kept (Terms, Privacy, Restore)
  trialSkipButton         — kept (conditional)
```

Each section is a `@ViewBuilder` computed property or extracted private view. Keep bodies under 50 lines per the type-check budget.

The pricing pills are tappable — selected pill gets a red border, unselected gets subtle border. Tapping a pill sets `viewModel.selectedProduct`. The "Upgrade" button purchases `viewModel.selectedProduct`.

### Step 5: Update .storekit file (optional)

Update `Convos.storekit` display names from "Convos Builder" to "Convos Plus" for Xcode previews. Product IDs stay unchanged.

## Backward Compatibility

- **Backend sends `"builder"` as tier**: Custom `init(from:)` on `SubscriptionTier` maps `"builder"` → `.plus`
- **Backend sends `"pro"` as tier**: Same decoder maps `"pro"` → `.plus` (safe fallback until backend removes Pro)
- **ASC product IDs unchanged**: `"app.convos.subs.builder.monthly"` still works; the mapping layer in `SubscriptionProductIDs` handles the rename
- **UserDefaults preset migration**: `CreditsStatePreset` fallback handles old `"builderAmple"` raw values

## Verification

1. **Build**: `xcodebuild build` on Convos (Dev) scheme
2. **Tests**: `swift test --package-path ConvosCore` — all credit/subscription tests green
3. **PaywallViewModelTests**: verify purchase, loading, concurrent-load, alert mapping
4. **Visual**: launch in simulator, navigate to paywall from Settings → Subscription → Subscribe/Change plan
5. **Mock presets**: cycle through CreditsStatePreset options in debug settings and confirm paywall renders each state correctly (no sub, plus subscriber, trial)
6. **Lint**: `/lint` before committing
