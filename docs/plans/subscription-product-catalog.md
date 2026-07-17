# Multi-platform Subscription Product Catalog

**Status:** Forward-looking plan. v1 ships with hardcoded product IDs on iOS; this plan describes the path to backend-driven catalog + Google Play parity.
**Owner:** TBD (Borja for backend shape, Louis for iOS migration, ??? for Android when it lands).
**Date:** 2026-05-20.

---

## TL;DR — the recommended architecture

**Stores (Apple ASC, Google Play) remain the source of truth for product definitions.** Manual product creation in each store's console, no API-driven creation. This is honest about Apple's limitations (their App Store Connect API can't fully bootstrap subscription products — review screenshots and most metadata still require the web UI).

**Backend stores a product catalog table** that mirrors what's in the stores. The mirror is the **canonical client-facing source**: any iOS or Android app fetches its product list from the backend, never directly from `Product.products(for:)` with a hardcoded list of IDs.

**Stores → backend syncing** happens via two paths:
1. **State changes** (renewal, billing retry, revoke) — push via S2S webhooks (ASSN v2, Google RTDN). This is what PR #215 already implements for Apple.
2. **Product definitions** (new SKU created, price changed) — fetched from the store APIs on a schedule + on-demand "Sync" button in the admin UI.

**Mobile clients call `GET /v2/products?platform=ios|android`** to render the paywall. Each platform sees only its own SKUs. The backend abstracts the cross-platform differences (Apple subscription groups vs Google base plans + offers).

```
                       ┌──────────────────────────┐
                       │   App Store Connect      │
                       │   (Apple product defs)   │
                       └────────────┬─────────────┘
                                    │ manual create
                                    │ + scheduled sync
                                    ▼
┌──────────────────────────────────────────────────────┐
│                   convos-backend                     │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  Product catalog table (the mirror)            │  │
│  │  per (platform, productId): tier, period,      │  │
│  │  displayName, displayPrice, monthlyGrant, rank │  │
│  └────────────────────────────────────────────────┘  │
│                       │                              │
│            ┌──────────┴──────────┐                   │
│            ▼                     ▼                   │
│   GET /v2/products       Admin UI (read first,       │
│   ?platform=ios|android  then editable in v1.5+)     │
└──────────────────────────────────────────────────────┘
                                    ▲
                                    │ manual create + scheduled sync
                                    │
                       ┌────────────┴─────────────┐
                       │   Google Play Console    │
                       │   (Google product defs)  │
                       └──────────────────────────┘
```

## Why this shape

Three rejected alternatives to anchor the reasoning:

**Rejected A — keep hardcoding on each client.**
Forces app updates to change pricing or add a tier. Apple's review cycle alone makes that a 1-3 day round trip for what should be a config change. Untenable at scale.

**Rejected B — backend creates products via store APIs.**
Apple's API isn't capable enough — review screenshots, localizations for some markets, and the actual "Submit for Review" step require the web UI. Google's API is more capable but still has quirks. Net: building a "single admin UI to create everywhere" hits painful integration walls. Always do manual creation, mirror to backend.

**Rejected C — clients fetch directly from the platform stores at runtime.**
This is what we do now on iOS (`Product.products(for: hardcodedIDs)`). It works but:
- Hardcoded ID list means app-update gate to add a SKU
- No cross-platform abstraction — Android would do its own thing
- Backend can't do platform-aware overrides (e.g. hide a SKU for a specific cohort, A/B test a tier)
- Display price comes from device locale, which is fine but offers no override path

**Recommended (this doc):** store-owned definitions + backend mirror + client-fetches-from-backend. Loses ~no flexibility, gains all the things above.

## Phases

### Phase A — today, v1 ship

**Status:** in-flight, PR #840.

- iOS hardcodes 3 product IDs in `SubscriptionProductIDs.swift` (Builder Monthly, Builder Annual, Pro Monthly)
- Backend `Subscription` table populated from ASSN webhook (PR #215)
- No product catalog in backend yet
- No Android

**This is the right state for the launch this week.** Don't block ship on the rest of the plan.

### Phase B — backend catalog + iOS fetches it

**Status:** post-launch, ~1 sprint.

Backend work (convos-backend):

1. Add `Product` table:
   ```ts
   model Product {
     id              String   @id @default(cuid())
     platform        Platform // enum: apple | google
     storeProductId  String   // e.g. "app.convos.subs.builder.monthly"
     tier            Tier     // enum: builder | pro
     period          Period   // enum: monthly | annual
     displayName     String   // "Convos Builder"
     description     String
     displayPrice    String   // "$19.99" — pre-formatted for display
     priceMicros     BigInt   // 19990000 (USD micros) — for math
     currencyCode    String   // "USD"
     monthlyGrant    Int      // 1500 (credits/month for this tier)
     rank            Int      // 1=upgrade target, higher=lower tier
     active          Boolean  // for soft-hiding without deleting
     storeRawJson    Json     // last-known full payload from the store API, for audit
     syncedAt        DateTime
     createdAt       DateTime @default(now())
     updatedAt       DateTime @updatedAt

     @@unique([platform, storeProductId])
   }
   ```

2. Add `GET /v2/products?platform=ios|android` endpoint:
   - Returns `Product[]` sorted by rank descending (upgrade target first)
   - Filters `active = true`
   - Cacheable: `Cache-Control: public, max-age=300` + ETag
   - Auth: same as other `/v2/accounts/me/*` (or open if we want pre-login paywall preview)

3. Seed the table once with the 3 v1 products (manual SQL or a one-shot migration script). Borja's call on whether to use Prisma seed or a one-time script.

iOS work (convos-ios):

1. Replace `SubscriptionProductIDs` constants with a `ProductCatalog` fetched from the new endpoint.
2. Cache the catalog locally (UserDefaults or GRDB) so offline cold-start works.
3. Fall back to a small hardcoded list **only** if the network call AND the cached list both fail — strictly a safety net, not the primary path.
4. `Product.products(for:)` calls now use the dynamically-fetched ID list.

Open question for Borja: **do the products live as a Prisma model with admin editing, or as a hardcoded TypeScript constant?**
Recommendation: Prisma table from day one. The constant approach makes "edit a price" require a backend deploy, defeating the purpose of decoupling from the app version.

### Phase C — Google Play / Android

**Status:** when Android v1 starts (no firm date).

Backend:
- Same `Product` table grows to include `platform = google` rows
- Add Google Play RTDN webhook (parallel to Apple's ASSN) for state changes
- Reuse `GET /v2/products` — Android passes `?platform=android`

Android:
- Same catalog-fetch pattern as iOS
- `BillingClient` (Google's StoreKit equivalent) called with the IDs from backend

Cross-platform modeling:
- **One logical "plan" maps to multiple store products.** "Builder Monthly" is one *plan*; its Apple SKU and Google SKU are two *Products*. Decide whether to flatten this in the backend (1 row per platform-product, no shared parent) or surface as a `Plan` parent + `Product` children. Flatten is simpler for v1.5 — the rare cases where a plan exists on one platform but not the other (e.g., today we have no Pro Annual on Apple due to the $1k cap) handle themselves with a missing row instead of a special-cased null.

### Phase D — admin UI

**Status:** v1.5+, when there's >1 person regularly touching the catalog.

Backend `admin/` app gets a Products tab:

1. **Read-only first.** Table view of all products, filterable by platform/tier/active.
2. **Sync button.** Fetches latest from ASC / Play APIs and updates the table. Diff displayed so the operator sees what changed before commit.
3. **Editable later.** Inline edit `displayName`, `description`, `active`, `rank`. Pushes back to store API where possible (Apple is limited; Google's more flexible). Out-of-band manual sync for fields the API can't write.

Decision deferred: scheduled-sync vs on-demand-only. Probably **both** — a nightly job to catch external edits, plus a button for "I just changed something in ASC, pull it now."

## Cross-platform pricing realities

Worth surfacing for the planning conversation:

1. **Apple's price points are discrete tiers.** You don't set $7.43, you pick "Tier 7" which is locale-dependent. $19.99 USD in the US is also €19.99 in EU, ¥3,000 in JP, etc. Apple does the conversion.
2. **Google's pricing is per-country with no tier system.** More flexible, more setup work.
3. **Backend should store the price in `priceMicros + currencyCode`** for math (revenue reporting, upgrade-path calculations) plus a pre-formatted `displayPrice` string for client display. Don't make clients reformat — different locales handle currency differently and you'll regret it.
4. **Sub price tiers are NOT identical across stores** by default. Don't assume Builder Monthly on Apple == Builder Monthly on Google in revenue terms. The backend table makes this explicit.

## What the iOS migration looks like (Phase B, concrete)

For sizing:

**Files that change:**
- `ConvosCore/Sources/ConvosCore/Services/Subscription/SubscriptionProductIDs.swift` — becomes mostly empty (just the type/enum definitions move elsewhere), OR replaced entirely by a `ProductCatalog` struct + repository
- `ConvosCore/Sources/ConvosCore/Services/Subscription/SubscriptionServiceProtocol.swift` — `availableProducts()` already returns `[PaywallProduct]`, no signature change needed
- `Convos/Subscription/StoreKitSubscriptionService.swift` — `Product.products(for:)` reads IDs from the fetched catalog instead of `SubscriptionProductIDs.all`
- New file: `ConvosCore/Sources/ConvosCore/Services/Subscription/BackendProductCatalogService.swift` — fetches + caches the catalog
- `ConvosAPIClient` gets a `func getProductCatalog() async throws -> [PaywallProduct]`

**Files that don't change:**
- `PaywallView`, `PaywallViewModel`, `TierCard`, `SubscriptionCopy`, all the credits UI — they already operate on `[PaywallProduct]` abstractions

**Net iOS effort:** ~1 day. Most of the change is plumbing; the UI surfaces are already catalog-agnostic.

## Open questions (need answers before Phase B starts)

| # | Question | Owner |
|---|---|---|
| 1 | Should `GET /v2/products` be authenticated, or open (for pre-login paywall preview)? | PM + Borja |
| 2 | Backend product catalog editing in v1.5 — Prisma Studio is enough, or do we need a real admin page? | Borja + ops |
| 3 | Catalog cache TTL on iOS — 24h with foreground refresh? 1h? Push-driven invalidation? | iOS |
| 4 | Cross-platform sync — manual button only, nightly job, or both? | Borja + ops |
| 5 | When Android lands — same monthlyGrant per tier as iOS, or platform-specific (different Apple/Google revenue economics → different grant sizing)? | PM + finance |
| 6 | Should the backend track which tier "upgrades to" which (the rank cross-reference for cross-grade UX), or is that derived from `rank`? | Borja |
| 7 | Hardcoded fallback on iOS — full list or minimum (just one cheap monthly tier so users can subscribe at all)? | iOS + PM |

## What this plan does NOT cover

- **Hermes burn-loop** integration (consume credits per agent turn). Separate concern, handled in `convos-assistants` and `in-app-purchases-and-credits.md` §6.5.
- **Push notifications** for credit state changes. Handled in §6.6 of the IAP PRD.
- **Consumable top-ups** (v1.1 credit packs). Adds a new `Product.type` enum value; otherwise fits the same catalog table.
- **Refund automation.** Apple lets us proactively refund via App Store Server API — could fit in the admin UI later.
- **Promo codes / intro offers.** Apple's first-class concepts, handled per-platform in the stores. Backend records redemptions but doesn't drive the offer logic.

## Recommended order of operations

| Sprint | Work |
|---|---|
| **This week** | Ship Phase A (PR #840). Keep iOS hardcoded. |
| **Next sprint** | Backend Phase B (table + endpoint + seed). iOS Phase B (catalog fetch + cache + fallback). |
| **When Android starts** | Phase C parallel work — Android picks up the same endpoint with `?platform=android`. |
| **v1.5+ when catalog editing matters** | Phase D admin UI. Read-only first, editable later. |

## Decision needed from PM right now

Just one: **is Android coming this year?** If yes, Phase B's `Product` table should bake in `platform` from day one (it does in this plan). If no, we can launch Phase B with just Apple rows and add `platform` later via migration. The migration cost is small either way — recommendation is to add `platform` upfront so the schema doesn't lie about its scope.
