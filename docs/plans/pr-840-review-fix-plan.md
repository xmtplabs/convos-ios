# PR 840 review fix plan

PR: https://github.com/xmtplabs/convos-ios/pull/840

Scope reviewed:

- Claude Code PR comment from May 18, 2026.
- Macroscope inline review comments and approvability comment through May 20, 2026.
- Current local branch `louis/iap-storekit-wiring` at the time this note was written.

This file is intentionally a handoff plan, not an implementation patch.

## Executive summary

The reviewers are aligned on four actionable issues. Three are correctness issues that should be fixed before merge, and one is a small concurrency cleanup. I agree with Claude Code that the PR also needs targeted tests because this is billing-sensitive code.

Recommended order:

1. Fix `MockSubscriptionService.purchase()` so a later `refresh()` cannot revert a purchase.
2. Reset the `hasShownNUXPaywall` flag from onboarding reset paths and add regression tests.
3. Replace StoreKit renewal detection with `Product.SubscriptionInfo.RenewalInfo.willAutoRenew`.
4. Add the `isLoadingProducts` guard in `PaywallViewModel.loadProducts()`.
5. Add focused tests for the above, plus `CreditBalance` edge cases.

The Macroscope `CreditBalance.isLow` comment is already resolved in the current code. Keep the fix and add tests so it stays fixed.

## Review comment breakdown

| Source | File | Severity | Current status | Recommendation |
| --- | --- | --- | --- | --- |
| Macroscope, Claude Code | `ConvosCore/Sources/ConvosCore/Services/Subscription/MockSubscriptionService.swift` | Medium / blocking | Still present | Fix before merge. Do not use only the literal `.builderAmple` one-liner because it loses Pro and Annual details. Preserve the purchased `UserSubscription` across refreshes. |
| Macroscope, Claude Code | `Convos/Conversation Detail/ConversationOnboardingCoordinator.swift` | High / blocking | Still present | Fix before merge. Clear `hasShownNUXPaywall` in reset paths. Consider consolidating the two reset methods. |
| Macroscope, Claude Code | `Convos/Subscription/StoreKitSubscriptionService.swift` | Medium / should fix | Still present | Fix before merge. `revocationDate == nil` is not auto-renewal state. Query StoreKit subscription status renewal info. |
| Macroscope, Claude Code | `Convos/Subscription/PaywallViewModel.swift` | Low / easy | Still present | Fix with a one-line guard and add a small test. |
| Macroscope | `ConvosCore/Sources/ConvosCore/Storage/Models/CreditBalance.swift` | Low | Resolved | No code change needed, but add regression tests. |
| Claude Code | Test coverage | Blocking recommendation | Still present | Add targeted tests around billing state and reset behavior. |

## 1. MockSubscriptionService purchase refresh bug

### Problem

`purchase(productId:)` publishes an active `UserSubscription`, but `refresh(force:)` later re-publishes `currentPreset.subscription()`. If the service started from `.noSubNoTrial`, a successful mock purchase disappears after refresh.

Current code:

```swift
subscriptionSubject.send(updated)
```

Later:

```swift
let snapshot = queue.sync { currentPreset.subscription() }
subscriptionSubject.send(snapshot)
```

### Recommended fix

Macroscope suggested `currentPreset = .builderAmple`. That fixes the narrow no-sub-to-builder-monthly path, but it is too lossy:

- A Pro purchase should not become Builder.
- A Builder Annual purchase should not refresh into Builder Monthly.
- The mock service should preserve the actual `UserSubscription` it just published.

Prefer storing a subscription snapshot independent of the preset. `CreditsStatePreset` can still power debug presets, but `refresh()` should re-publish the current mock subscription snapshot.

Suggested shape:

```swift
private var currentPreset: CreditsStatePreset
private var currentSubscriptionSnapshot: UserSubscription?

public init(initialPreset: CreditsStatePreset = .builderAmple) {
    self.currentPreset = initialPreset
    let initialSubscription = initialPreset.subscription()
    self.currentSubscriptionSnapshot = initialSubscription
    self.subscriptionSubject = CurrentValueSubject(initialSubscription)
    self.mockProducts = Self.defaultMockProducts()
}

public func purchase(productId: String) async throws {
    guard let product = mockProducts.first(where: { $0.id == productId }) else {
        throw SubscriptionServiceError.productNotFound
    }

    try await Task.sleep(for: .milliseconds(600))

    let now = Date()
    let component: Calendar.Component = product.period == .monthly ? .month : .year
    let nextRenew = Calendar.current.date(byAdding: component, value: 1, to: now) ?? now
    let updated = UserSubscription(
        tier: product.tier,
        period: product.period,
        status: .active,
        productId: product.id,
        currentPeriodEnd: nextRenew,
        willRenew: true,
        isInTrial: false
    )

    queue.sync {
        currentPreset = product.tier == .pro ? .proAmple : .builderAmple
        currentSubscriptionSnapshot = updated
    }
    subscriptionSubject.send(updated)
}

public func refresh(force: Bool) async {
    let snapshot = queue.sync { currentSubscriptionSnapshot }
    subscriptionSubject.send(snapshot)
}

public func setPreset(_ preset: CreditsStatePreset) {
    let subscription = preset.subscription()
    queue.sync {
        currentPreset = preset
        currentSubscriptionSnapshot = subscription
    }
    subscriptionSubject.send(subscription)
}
```

If mock purchase is expected to update all visible credits surfaces, also consider syncing `MockCreditsService.shared` to the matching ample preset inside `purchase()`. If that side effect feels too surprising inside `ConvosCore`, inject a credits service into the paywall flow instead. The current PR already makes the real StoreKit service force-refresh credits after purchase, so mock and real behavior should ideally match.

### Tests to add

Add `ConvosCore/Tests/ConvosCoreTests/MockSubscriptionServiceTests.swift`:

- `testPurchaseThenRefreshKeepsPurchasedSubscription()`
  - Start from `.noSubNoTrial`.
  - Purchase `SubscriptionProductIDs.builderAnnual`.
  - Assert current subscription is Builder Annual.
  - Call `refresh(force: true)`.
  - Assert it is still Builder Annual with the same product id.
- `testProPurchaseThenRefreshKeepsProSubscription()`
  - Start from `.noSubNoTrial`.
  - Purchase `SubscriptionProductIDs.proMonthly`.
  - Refresh.
  - Assert tier is `.pro`.
- `testSetPresetOverridesPurchasedSnapshot()`
  - Purchase a product.
  - Call `setPreset(.noSubNoTrial)`.
  - Refresh.
  - Assert subscription is nil.

## 2. Onboarding reset does not clear NUX paywall flag

### Problem

`resetUserDefaults()` removes `hasShownNUXPaywallKey`, but the instance reset methods do not clear `hasShownNUXPaywall`. After completing the NUX paywall once, a Debug menu onboarding reset will not make the paywall appear again.

Current relevant methods:

```swift
func reset() {
    state = .idle
    profileSettingsViewModel.delete()
    hasSeenAddAsProfile = false
    hasCompletedOnboarding = false
    hasShownProfileEditor = false
}

func reset(conversationId: String? = nil) {
    hasCompletedOnboarding = false
    hasShownProfileEditor = false
    state = .idle
    ...
}
```

### Recommended fix

Add `hasShownNUXPaywall = false` to every reset path whose purpose is to reset onboarding. There are two instance reset methods in this file; fix both or consolidate them so future reset changes cannot drift.

Minimal patch:

```swift
func reset() {
    state = .idle
    profileSettingsViewModel.delete()
    hasSeenAddAsProfile = false
    hasCompletedOnboarding = false
    hasShownProfileEditor = false
    hasShownNUXPaywall = false
}

func reset(conversationId: String? = nil) {
    hasCompletedOnboarding = false
    hasShownProfileEditor = false
    hasShownNUXPaywall = false
    state = .idle

    if let conversationId {
        setHasSetProfile(false, for: conversationId)
    }
}
```

Follow-up cleanup to consider: the no-argument `reset()` and `reset(conversationId:)` overlap. If both are kept, document the difference in method names or behavior. If they are intended to mean the same thing, keep one method with an optional argument and include the profile deletion / `hasSeenAddAsProfile` behavior there.

### Tests to update/add

In `ConvosTests/ConversationOnboardingCoordinatorTests.swift`:

- Add `UserDefaults.standard.removeObject(forKey: "hasShownNUXPaywall")` to `cleanUpUserDefaults()`.
- Extend `testReset_ClearsAllState()` to set and assert clearing of `hasShownNUXPaywall`.
- Extend `testReset_WithConversationId_ClearsConversationFlag()` or add a sibling test to assert the conversation-specific reset also clears `hasShownNUXPaywall`, if that method remains an onboarding reset.
- Add a NUX flow test if feasible:
  - Precondition profile has already been shown or select profile.
  - Trigger transition after profile setup in non-production config.
  - Assert `.presentingPaywall` appears once.
  - Call `userDidCompleteNUXPaywall()`.
  - Assert the flag is set and the next flow skips the paywall.

## 3. StoreKit renewal detection is incorrect

### Problem

`StoreKitSubscriptionService.userSubscription(from:)` currently derives renewal status from `transaction.revocationDate == nil`:

```swift
let willRenew: Bool = transaction.revocationDate == nil
```

`revocationDate` only means Apple refunded or revoked the transaction, such as Family Sharing revocation. It does not tell whether the user turned off auto-renewal. A cancelled-but-still-active subscription will have no revocation date, so the settings UI can incorrectly show `Renews <date>` instead of `Expires <date>`.

### Recommended fix

Use StoreKit's subscription status APIs and read `Product.SubscriptionInfo.RenewalInfo.willAutoRenew`.

This likely means making `userSubscription(from:)` async because StoreKit status lookup is async:

```swift
private func refreshFromEntitlements() async {
    var latest: UserSubscription?
    for await result in Transaction.currentEntitlements {
        guard let transaction = try? verifiedTransaction(result) else { continue }
        guard let sub = await userSubscription(from: transaction) else { continue }
        latest = sub
    }
    subscriptionSubject.send(latest)
}

private func userSubscription(from transaction: Transaction) async -> UserSubscription? {
    guard let tier = SubscriptionProductIDs.tier(for: transaction.productID),
          let period = SubscriptionProductIDs.period(for: transaction.productID) else {
        return nil
    }

    let storeKitSnapshot = await storeKitSubscriptionSnapshot(for: transaction)
    let isInTrial = transaction.offer?.type == .introductory

    return UserSubscription(
        tier: tier,
        period: period,
        status: storeKitSnapshot.status,
        productId: transaction.productID,
        currentPeriodEnd: transaction.expirationDate ?? Date(),
        willRenew: storeKitSnapshot.willRenew,
        isInTrial: isInTrial
    )
}
```

Suggested helper shape:

```swift
private struct StoreKitSubscriptionSnapshot {
    let status: ConvosCore.SubscriptionStatus
    let willRenew: Bool
}

private func storeKitSubscriptionSnapshot(for transaction: Transaction) async -> StoreKitSubscriptionSnapshot {
    let fallback = StoreKitSubscriptionSnapshot(
        status: subscriptionStatus(from: transaction),
        willRenew: transaction.revocationDate == nil
    )

    do {
        let products = try await Product.products(for: [transaction.productID])
        guard let subscription = products.first?.subscription else {
            return fallback
        }

        let statuses = try await subscription.status
        guard let status = statuses.first(where: { status in
            guard let statusTransaction = try? verifiedTransaction(status.transaction) else { return false }
            return statusTransaction.originalID == transaction.originalID
        }) else {
            return fallback
        }

        let renewalInfo = try verifiedTransaction(status.renewalInfo)
        return StoreKitSubscriptionSnapshot(
            status: subscriptionStatus(from: status.state, transaction: transaction),
            willRenew: renewalInfo.willAutoRenew
        )
    } catch {
        Log.error("Failed reading StoreKit renewal info for \(transaction.productID): \(error)")
        return fallback
    }
}
```

Add a state mapper while touching this code:

```swift
private func subscriptionStatus(
    from renewalState: Product.SubscriptionInfo.RenewalState,
    transaction: Transaction
) -> ConvosCore.SubscriptionStatus {
    switch renewalState {
    case .subscribed:
        return transaction.offer?.type == .introductory ? .trial : .active
    case .inGracePeriod:
        return .grace
    case .inBillingRetryPeriod:
        return .billingRetry
    case .expired:
        return .expired
    case .revoked:
        return .revoked
    @unknown default:
        return subscriptionStatus(from: transaction)
    }
}
```

The exact StoreKit property signatures should be verified in Xcode; the key point is that `willRenew` must come from verified renewal info, not `revocationDate`.

### Test strategy

StoreKit's concrete types are hard to unit test directly. Avoid making this untestable by extracting one pure mapper:

```swift
struct RenewalStatusSnapshot: Equatable {
    let renewalState: Product.SubscriptionInfo.RenewalState
    let willAutoRenew: Bool
}
```

or, if StoreKit types are awkward in tests, use an internal app-defined enum:

```swift
enum StoreKitRenewalStateSnapshot {
    case subscribed
    case inGracePeriod
    case inBillingRetryPeriod
    case expired
    case revoked
}
```

Then unit test the mapping from renewal state plus `willAutoRenew` to `UserSubscription.status` and `willRenew`. Manually QA the real StoreKit cancelled-auto-renew path with the `.storekit` configuration or sandbox.

Manual QA cases:

- Active auto-renewing subscription displays `Renews <date>`.
- Active subscription with auto-renew cancelled displays `Expires <date>`.
- Billing retry maps to `Payment retrying - update in App Store`.
- Grace period maps to `Grace period until <date>`.
- Revoked / expired do not display as renewing.

## 4. PaywallViewModel duplicate product load

### Problem

`PaywallViewModel` is `@MainActor`, but actors are re-entrant at `await` suspension points. The first `loadProducts()` call sets `isLoadingProducts = true` and then suspends while awaiting `subscriptionService.availableProducts()`. A second call can enter while `products` is still empty, because the guard only checks `products.isEmpty`.

Current code:

```swift
func loadProducts() async {
    guard products.isEmpty else { return }
    isLoadingProducts = true
    defer { isLoadingProducts = false }
    ...
}
```

### Recommended fix

Apply Macroscope's one-line suggestion:

```swift
func loadProducts() async {
    guard products.isEmpty, !isLoadingProducts else { return }
    isLoadingProducts = true
    defer { isLoadingProducts = false }
    ...
}
```

### Test to add

Add a `PaywallViewModelTests` test target case with a fake `SubscriptionServiceProtocol` whose `availableProducts()` increments a thread-safe call count and sleeps briefly.

Test shape:

```swift
async let first: Void = viewModel.loadProducts()
async let second: Void = viewModel.loadProducts()
_ = await (first, second)
XCTAssertEqual(service.availableProductsCallCount, 1)
```

Also add small tests for purchase error presentation if time allows:

- `.purchasePending` shows title `Awaiting approval`.
- `.purchaseUnverified` shows title `Couldn't verify purchase`.
- `.purchaseCancelled` does not show an alert.
- Success calls `onPurchaseSucceeded` once.

## 5. CreditBalance.isLow is already fixed

Macroscope's earlier low-severity comment said `isLow` treated `monthlyGrant == 0` as low. Current code is already corrected:

```swift
public var fractionRemaining: Double? {
    guard monthlyGrant > 0 else { return nil }
    return Double(balance) / Double(monthlyGrant)
}

public var isLow: Bool {
    guard let fractionRemaining else { return false }
    return balance > 0 && fractionRemaining <= 0.2
}
```

No implementation change is needed. Add regression tests in `ConvosCore`:

- `balance: 500, monthlyGrant: 0` -> `fractionRemaining == nil`, `isLow == false`, `isDepleted == false`.
- `balance: 0, monthlyGrant: 1500` -> `isLow == false`, `isDepleted == true`.
- `balance: 300, monthlyGrant: 1500` -> `isLow == true` if 20 percent exactly should count as low.
- `balance: 301, monthlyGrant: 1500` -> `isLow == false`.
- Negative balance -> `isDepleted == true`.

## 6. Test coverage plan for Claude Code's review

Claude Code called out zero tests for the new subscription and credits code. I would not block on fully mocking StoreKit transactions, but the PR should add focused tests around the logic we own.

### ConvosCore tests

Add these files under `ConvosCore/Tests/ConvosCoreTests/`:

- `CreditBalanceTests.swift`
- `MockSubscriptionServiceTests.swift`
- `CreditsStatePresetTests.swift` if useful for preset invariants

Useful assertions:

- Presets with subscriptions have matching nonzero monthly grants, except states intentionally depleted.
- `.noSubNoTrial` has nil subscription and zero grant.
- `.trialActive` has trial status, `isInTrial == true`, and `willRenew == false`.
- Mock purchase and refresh behavior as described above.

### App target tests

Add or update under `ConvosTests/`:

- `ConversationOnboardingCoordinatorTests.swift`
  - Reset clears `hasShownNUXPaywall`.
  - NUX paywall is one-shot.
  - Existing transition tests may need explicit setup for the new paywall step. If a test is about notifications rather than paywall, set `hasShownNUXPaywall` to true in that test's arrange phase.
- `PaywallViewModelTests.swift`
  - Duplicate load guard.
  - Purchase error alert mapping.
  - Success callback.

### StoreKitSubscriptionService tests

Recommended approach:

- Extract status mapping into a small internal helper that accepts app-defined snapshots instead of real StoreKit transactions.
- Unit test that helper.
- Keep end-to-end StoreKit purchase / renewal / cancellation behavior as manual QA or UI automation, because Apple's StoreKit transaction objects are not simple to construct.

### BackendCreditsService tests

If adding tests for `BackendCreditsService`, a fake `ConvosAPIClientProtocol` can validate:

- `refresh(force: true)` calls `getCreditBalance()` and publishes the result.
- `refresh(force: false)` within the TTL does not call the API again after a successful fetch.
- After an API error, `currentBalance` remains the previous value.

If the constructor's automatic refresh makes tests flaky, consider adding an internal initializer parameter like `startInitialRefresh: Bool = true` or injecting a clock/date provider. That is a testability improvement, not required for the current review comments.

## 7. Small code style note while touching StoreKitSubscriptionService

`StoreKitSubscriptionService` currently declares `private enum Constant` in the middle of the type. The project convention says `private enum Constant` should live at the bottom of the scope. If this file is edited, move `Constant` below the helper methods to avoid a lint failure.

## Suggested final checklist for the implementing agent

- [ ] Fix `MockSubscriptionService` snapshot persistence and add refresh regression tests.
- [ ] Clear `hasShownNUXPaywall` in onboarding reset paths and update onboarding tests.
- [ ] Replace `revocationDate == nil` renewal detection with verified StoreKit renewal info.
- [ ] Add the `!isLoadingProducts` guard in `PaywallViewModel.loadProducts()` and test it.
- [ ] Add `CreditBalance` edge-case tests.
- [ ] Run formatting and lint.
- [ ] Run the relevant unit tests, then the full suite required by the repo workflow.
