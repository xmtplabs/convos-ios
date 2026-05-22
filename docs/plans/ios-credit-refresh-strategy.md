# iOS credit & subscription refresh strategy

Companion doc to `in-app-purchases-and-credits.md`. Records the iOS-side trigger map for keeping `CreditBalance` + `UserSubscription` in sync with the backend.

## Backend endpoints driving this

- `GET /v2/accounts/me/credits` → `CreditBalance` (IAP PRD §6.2)
- `GET /v2/accounts/me/subscription` → `UserSubscription` (IAP PRD §6.2)

Both are read at the moments below; writes (verify) only happen via StoreKit purchase + restore. No push notifications today (deferred per PRD §6.6).

## Every moment iOS re-fetches credits/subscription

| Trigger | TTL-debounced (15s)? | Why this exists |
|---|---|---|
| App cold start | no (always fresh) | service `init` calls `refresh(force: true)` once |
| App returns to foreground (`scenePhase → .active`) | yes | catches "user closed app for an hour, Hermes / Apple webhook / manual op changed state in the background" |
| Conversations list appears (`ConversationsView.task`) | yes | HOME credits pill rendered here |
| Conversation appears (`ConversationView.task`) | yes | low-balance banner rendered above the messages list |
| Agent contact sheet opens (`ConversationMemberView.task`) | yes | "out of credits" section + Upgrade CTA |
| Settings → Subscription opens (`SubscriptionSettingsView.task`) | yes | balance + renewal copy |
| Settings → Subscription pull-to-refresh (`.refreshable`) | **no** | explicit user-initiated freshness |
| StoreKit purchase succeeds (after backend `/verify` returns) | **no** for credits | tier change → `monthlyGrant` change → must reflect immediately |
| `Transaction.updates` fires (Apple-side renew, refund, etc.) | **no** for credits | server-side state mutated; force-refresh both services |
| _(future hook when Hermes burn-loop ships)_ XMTP agent message arrives in current conversation | yes | highest-value trigger — agent reply implies a `/v2/credits/consume` just happened backend-side; refresh ticks balance down within ~1s of the reply rendering |

A `// TODO(hermes-burn-loop):` marker lives in `ConversationView.swift`'s `.task` block to make the future XMTP hook obvious.

## Debounce contract

Both `BackendCreditsService.refresh(force:)` and `StoreKitSubscriptionService.refresh(force:)` accept an optional `force` flag (default `false`). With `force=false`, a no-op if the last successful fetch was within `refreshTTL = 15s`. `force=true` always hits the backend. This keeps view-appear + scenePhase triggers safe to spam without API storms.

The protocol exposes a zero-arg `refresh()` convenience that maps to `refresh(force: false)`, so old call sites keep working without ceremony.

## Staleness ceiling

While the app sits open on a credit-displaying view and the user isn't interacting, balance is up to 15s stale. This was reviewed as sufficient — periodic polling and silent push (Phase 2 per PRD §6.6) intentionally not in scope for v1.

## Error handling

`POST /v2/accounts/me/subscription/verify` may return `409` with `code: "subscription_account_mismatch"` (PRD §6.4 strict-ownership invariant). iOS does **not** map this to a typed dead-end — it falls through to the existing generic `APIError.serverError` path. The purchase + restore flows already surface that as a retryable error, and the refresh logic above will reconcile any transient state. This avoids hard-failing the user when the underlying state is recoverable.

## Files touched

| File | Change |
|---|---|
| `ConvosCore/.../CreditsServiceProtocol.swift` | `refresh(force: Bool)` + zero-arg convenience extension |
| `ConvosCore/.../Subscription/SubscriptionServiceProtocol.swift` | same |
| `ConvosCore/.../BackendCreditsService.swift` | `lastFetchedAt` + TTL-debounced `refresh(force:)` |
| `ConvosCore/.../MockCreditsService.swift` | matches new protocol |
| `ConvosCore/.../MockSubscriptionService.swift` | matches new protocol |
| `Convos/Subscription/StoreKitSubscriptionService.swift` | TTL-debounced `refresh(force:)`, plus credits-refresh paired with `refreshFromEntitlements()` on purchase + transaction updates |
| `Convos/ConvosApp.swift` | `scenePhase` observer in WindowGroup body |
| `Convos/Conversations List/ConversationsView.swift` | `.task` refresh |
| `Convos/Conversation Detail/ConversationView.swift` | `.task` refresh + Hermes-loop TODO |
| `Convos/Conversation Detail/ConversationMemberView.swift` | `.task` refresh |
| `Convos/Subscription/SubscriptionSettingsView.swift` | `.task` + `.refreshable` |

## Verification

1. Build + run against `otr-dev` backend.
2. Subscribe via StoreKit sandbox. Confirm balance pill updates immediately after the purchase completes (was previously stale until next cold start).
3. Background the app, fake-burn 100 credits via a direct `curl -H 'X-Agent-API-Key: ...' -X POST .../v2/credits/consume`, foreground the app, confirm pill updates within ~1s of foregrounding.
4. Open Settings → Subscription, pull down to refresh, confirm balance re-fetches.
5. Navigate between conversations list / a conversation / contact sheet several times in <15s — confirm only one network request fires (TTL debounce holds).

End-to-end with a real burn arrives once Hermes is wired to call `/v2/credits/consume` — at that point, add the XMTP-message-received refresh hook in `ConversationView.task` per the TODO marker.
