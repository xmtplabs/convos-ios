# In-App Purchases & Credits

**Status:** PRD draft — pending eng/design review.
**Owner:** TBD.
**Date:** 2026-05-12.
**Single-file scope:** Both the iOS (Convos) and backend (convos-backend, convos-assistants) plans live here so the economic model, schema, and UI stay in one place.

---

## 1. Goals (v1)

A subscribing user can:

1. See their current credits balance on the home screen.
2. See, in a conversation, when an agent is **low on credits** or **out of credits**.
3. Open an agent's contact sheet and see that agent's credit usage chart and their current per-month allowance.
4. From the contact sheet's out-of-credits state, upgrade their subscription.
5. Manage their subscription (current plan, renewal date, switch tier, cancel) from Settings.
6. Subscribe from a Builder/NUX paywall (or skip with a 7-day trial of credits).

Operationally, we can:

7. Mint App Store Connect subscription products and validate purchases server-side.
8. Maintain a per-account credit ledger that's auditable, idempotent, and tunable without rewriting history.
9. Top up OpenRouter's prepaid balance on a runbook (and observe drainage in dashboards).
10. Adjust per-tier grant size, per-model credit rates, and markup at runtime via env vars (and, in v1.1, an admin UI).

## 2. Non-goals (v1)

- **Group credit pooling** (frame "CONVO future"). Deferred.
- **Consumable Top-Up SKUs** ($4.99 / $19.99 / $49.99 credit packs). Deferred to v1.1; see [Release valve](#56-release-valve-policy).
- **Promo codes / offer codes**. Standard StoreKit feature; punt to v1.1.
- **Family Sharing** for subs (leave Apple default = off until policy is set).
- **Web checkout** (Stripe etc.) — App Store is the only payment rail in v1.
- **Refund automation** — operator does it manually via the admin UI + App Store Connect.
- **Account merging / cold-login dedup** (called out as non-goal in PR 194; honor that boundary here too).
- **Agent "pause" feature** — adjacent to credits but explicitly scoped out of payments work (per @borja in the team thread). Tracked separately under infra.

## 3. Decisions already made (this session)

| Decision | Choice | Rationale |
| -------- | ------ | --------- |
| Vendor | **Build ourselves.** | Account model + ledger schema already in `convos-backend` (PR 194 + PR 191). RC's high-value features (paywall A/B, MMP attribution, retention analytics) don't change unit economics for us. 1% of MTR is cheap on day 1 but a fixed tax forever. |
| Products | **Builder + Pro × Monthly + Annual** = 4 SKUs in one subscription group. | Matches the design. Annual is the upsell paywall lever. Single group → Apple handles up/down/cross-grade proration. |
| Release valve | **Slow-mode + upsell** when balance hits 0. | Agent silently routes to a cheap fallback model and contact sheet shows OUT-OF-CREDITS upgrade CTA. Top-up SKUs deferred. |
| Free tier | **7-day trial: 500 credits, slow model after expiry.** | Single `GrantKind { id: 'trial_2026_05', expiresAfterDays: 7 }` row. Easy to A/B (issue new GrantKind monthly). |
| Admin UI | **New `admin/` app in convos-backend.** | Source-of-truth coupling. Operator-only auth. Talks to backend Prisma directly. Decouples from public `convos-assistants/dashboard`. |
| Credit abstraction | **Virtual currency**, per RC pattern. | Implemented in PR 191's ledger module. `CreditLedger` records per-row rates so we can change them monthly without rewriting history. |
| Pricing configuration | **Env vars** (per PR 191). | Borja's preference for v1; tuning UI is a v1.1 concern once we have real usage data. |
| Cost source | **OpenRouter's reported `estimated_cost_usd`.** | Per PR 191. Avoids per-model rate-card complexity. v1 restricts to known-pricing models to avoid `cost_status: "unknown"`. |

## 4. References

- **Auth foundation:** [convos-backend PR 194 "Auth API: SIWE upgrade path on /auth/token + Account/AuthMethod"](https://github.com/xmtplabs/convos-backend/pull/194) — adds `Account`, `AuthMethod`, `AuthNonce` Prisma models and `requireAccount` middleware. **iOS must ship the SIWE upgrade flow before backend flips any route to `requireAccount`** or old device-only JWTs hit 403.
- **Payments foundation:** [convos-backend PR 191 "Payments API foundations"](https://github.com/xmtplabs/convos-backend/pull/191) — ledger module with `grant`, `consume`, `balance`, `check`, `promo` methods. No HTTP bindings yet. Implements `credits_to_deduct = estimated_cost_usd × markup_rate × credits_per_dollar` with env-var configuration (`PAYMENTS_MARKUP_RATE`, `PAYMENTS_CREDITS_PER_USD`, `PAYMENTS_RESERVED_MAX_TURN_CREDITS`, `PAYMENTS_MIN_BALANCE_CREDITS`). See §6.0 for full reference.
- **Account-repoint:** branch `payments-repoint` (PR pending) re-keys `UserCredits` and `CreditLedger` from `inboxId` to `accountId`. Hard prereq for this PRD's Phase 1.
- **Pool budget today:** `convos-assistants/pool/src/services/providers/openrouter.ts` — mints per-instance OpenRouter sub-keys with USD spending limits (`OPENROUTER_KEY_LIMIT`, default $20). Shared prepaid org balance. `GET /dashboard/credits` and `PATCH /dashboard/topup/:keyHash` are the only admin endpoints today.
- **Hermes cost capture:** `convos-assistants/runtime/openclaw/src/convos/src/openrouter-capture.ts` reads `usage.cost` (USD) from the OpenRouter response on every request. Returns `prompt_tokens`, `completion_tokens`, `estimated_cost_usd`, `cost_status: "estimated"|"included"|"unknown"`, `cost_source`. Today emits to PostHog only — v1 changes this to POST `/consume` on convos-backend.
- **Pricing calculator:** Borja's `credit-pricing-calculator.html` (HTML tool, shared in team Slack 2026-04-30) — interactive markup × credits-per-dollar exploration. Path TBD when committed.
- **Virtual currency design pattern:** [RevenueCat — Virtual Currency](https://www.revenuecat.com/docs/offerings/virtual-currency) (entities: Currency / Balance / Transaction; supports grants, deducts, idempotency; **does not** support per-grant expiration, per-grant rates, or stacking — our ledger does, intentionally).
- **AI-app virtual currency monetization:** [RevenueCat blog — How to monetize your AI app with virtual currencies](https://www.revenuecat.com/blog/engineering/how-to-monetize-your-ai-app-with-virtual-currencies/). Treat credits as an opaque, non-transferable, Customer-bound currency; deduct per request type; charge variable cost per operation.
- **App Store Server API:** Apple's [Decoding signed transactions](https://developer.apple.com/documentation/appstoreserverapi) (`Get Transaction Info`, `Get Subscription Statuses`) + [App Store Server Notifications v2](https://developer.apple.com/documentation/appstoreservernotifications) for renewal / billing-retry / grace / revoke events.
- **StoreKit 2:** the modern iOS API (`Product`, `Transaction`, `Product.SubscriptionInfo.Status`). Pull subscription state from `Transaction.currentEntitlements` AsyncSequence, not the legacy receipt blob.

---

## 5. Economic model

This is the load-bearing section of the plan. The numbers below are **launch defaults**; they're admin-tunable from day 1 via env vars (and, in v1.1, an admin UI).

### 5.1 Apple's cut after fees

Worst-case worldwide blend (1st year, 30% Apple, EU/UK VAT pre-deducted by Apple):

| SKU | Gross USD | Apple cut (30% / 15% SBP) | EU VAT impact* | **Net to Convos** |
|---|---|---|---|---|
| Builder Monthly $9.99 | $9.99 | $3.00 / $1.50 | ~$1.50 | **~$5.50 (yr1) / ~$6.80 (yr2 SBP)** |
| Pro Monthly $29.99 | $29.99 | $9.00 / $4.50 | ~$4.50 | **~$17 (yr1) / ~$20 (yr2 SBP)** |
| Builder Annual $79.99 | $79.99 | $24 / $12 | ~$12 | **~$45 (yr1) / ~$54 (yr2 SBP)** |
| Pro Annual $239.99 | $239.99 | $72 / $36 | ~$36 | **~$135 (yr1) / ~$162 (yr2 SBP)** |

*VAT is Apple's burden, not ours — they collect from the user and remit. The "VAT impact" column is the effective price drop our net sees after Apple netted EU/UK customer revenue. Apple's [pricing tiers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/configure-prices) show ~30% lower take for EU SKUs. Apple Small Business Program (SBP): 15% if you earned <$1M from App Store last year — auto-applies after enrollment.

**Planning assumption:** $6 net Builder, $18 net Pro at launch (year-1, worst-case worldwide). Annuals = ~9× monthly net (10% paid-up-front discount).

### 5.2 Virtual currency — the abstraction

We follow the **RevenueCat Virtual Currency pattern**: credits are opaque, non-transferable, account-bound units. A user sees "1,500 credits / month". They don't see USD or tokens.

Internally, two levers turn credits into real economics, both stored **per ledger row** (in PR 191's `CreditLedger` schema):

1. **`creditsPerDollar: BigInt`** — the credit↔USD exchange rate at the time of the grant or burn. Stored on each ledger entry. Changing the env var tomorrow does not rewrite yesterday's entries.
2. **`markupRate: Decimal(8,4)`** — how much we charge users above raw model cost. Stored per ledger entry on a burn. `markupRate = 2.0` means $1 of OpenRouter spend deducts the credit-equivalent of $3 ($1 raw cost + $2 markup).

**Per-model rate card is NOT used** in v1. We deduct against OpenRouter's reported `estimated_cost_usd` directly, applied uniformly via env-var markup. This avoids the maintenance burden of a per-model rate table and matches PR 191's implementation. If we later need per-model differentiation (e.g. premium-model upcharge), we can introduce a multiplier table without changing ledger row shape.

### 5.3 Launch config (env-var driven)

The numbers below match the design figure ("500 remaining / 1500 per month" on the Settings row) and the PR 191 env-var layout.

| Env var | Launch value | Purpose |
|---|---|---|
| `PAYMENTS_CREDITS_PER_USD` | **1000** (1 credit = $0.001 nominal) | Headline-friendly unit (1,500 credits ≈ "$1.50 of AI") |
| `PAYMENTS_MARKUP_RATE` | **2.0** (deduct 3× raw cost in credit-equivalent) | Industry-standard AI-SaaS markup with room to compete |
| `PAYMENTS_RESERVED_MAX_TURN_CREDITS` | **100** | Reserved at turn start so a long answer can't underflow mid-turn |
| `PAYMENTS_MIN_BALANCE_CREDITS` | **0** | If `0`, allow burns until empty then route to slow-mode. If `>0`, gate slow-mode at this floor instead. **Open — see team Q B1.** |
| `PAYMENTS_GRANT_BUILDER_MONTHLY` | **1500** | Credits granted on each Builder renewal |
| `PAYMENTS_GRANT_PRO_MONTHLY` | **5000** | Credits granted on each Pro renewal |
| `PAYMENTS_GRANT_TRIAL` | **500** | Credits granted on NUX trial redemption |
| `PAYMENTS_TRIAL_EXPIRY_DAYS` | **7** | Trial credits expire after this many days |
| `PAYMENTS_SLOW_MODE_MODEL_KEY` | `google/gemini-2.5-flash` | Cheap fallback model when balance is depleted |

**Two reality checks on these numbers:**

- 1,500 credits at `creditsPerDollar=1000` `markupRate=2.0` = $0.50 of real OpenRouter spend. At Claude Sonnet 4.6 pricing, that's ~25-50 typical agent turns/month. **This is intentionally tight** for a $9.99 product. Cursor Pro at $20 gives 500 fast requests (~$0.04 each = $20 face), running them ~50% margin on power users. We're ~91% margin on full-burn users — the cushion to absorb Apple's 30% cut and to subsidize slow-mode.
- The cushion has a cost: **users who burn through in 5 days will be annoyed**. Mitigation = generous slow-mode (option A: free slow-mode forever; option B: slow-mode metered at 0.1× standard cost). Pick option A for launch — it's strictly cheaper to retain than to re-acquire.

### 5.4 Margin model — why this works

```
Net revenue per Builder user (yr1, worst case):  $6.00
Raw OpenRouter spend at full grant burn:         $0.50
Slow-mode bonus spend (estimated):               $0.30
Net contribution:                                $5.20 (~87% gross margin)
```

A user who NEVER burns their credits = ~$6 contribution. A user who burns the full grant + heavy slow-mode = ~$5. This is the design intent: **flat ~$5 contribution regardless of usage**, paid by Apple. Sub price → credits ratio is the lever that flattens it.

For Pro at $18 net, same math gives ~$17 contribution. Pro burns more credits → more raw spend → still 85%+ margin.

This is fundamentally **freemium economics**, not AI-cost-pass-through. It is the right model for a messaging app where most users send a handful of agent messages a week, not the wrong model for power users (whom we throttle into slow-mode).

### 5.5 Grant policy — kinds and cadence

Two `GrantKind`s in v1, plus a third planned via cron:

| GrantKind id | Source | When | Amount | Expiry |
|---|---|---|---|---|
| `subscription_builder_2026_05` | StoreKit purchase | On every Builder renewal (initial + DID_RENEW) | `PAYMENTS_GRANT_BUILDER_MONTHLY` (=1500) | renewal + 35 days (5-day grace) |
| `subscription_pro_2026_05` | StoreKit purchase | On every Pro renewal | `PAYMENTS_GRANT_PRO_MONTHLY` (=5000) | renewal + 35 days |
| `trial_nux_2026_05` | NUX onboarding | On first `POST /v2/credits/me/redeem-trial` per account (one-time) | `PAYMENTS_GRANT_TRIAL` (=500) | now + `PAYMENTS_TRIAL_EXPIRY_DAYS` days |
| `daily_free_2026_05` | Cron job | Daily, to eligible accounts | TBD — see team Q B2 | day-end |

**Reset, not rollover.** On every subscription renewal, grant the full tier allotment as a new `CreditLedger` entry. Old unspent credits expire naturally. Simpler accounting, predictable COGS, no power-user rollover hoarding. Matches industry default (Cursor, Claude Pro).

The daily cron grant is mentioned in Borja's design thread but its parameters (amount, cadence, eligibility) are still open — see team Q B2. Adding the row to `GrantKind` early lets us toggle it on without a schema migration.

### 5.6 Release valve policy

Balance hits 0 (or falls below `PAYMENTS_MIN_BALANCE_CREDITS` if set) → Hermes routes next turn to slow-mode model. Slow-mode requests deduct 0 credits (option A above). Two UI affordances drive upgrades:

1. **In-conversation**: a small low-balance pip on the agent avatar (yellow ≤20%, red at 0). At 0 balance, every message includes a footer hint: *"This agent is using a slower model. Upgrade to keep them sharp →"* (button → paywall).
2. **Contact sheet**: when `balance == 0`, the credits pill shows "Out of credits" with red accent, and a primary **Upgrade plan** button replaces the usage chart's primary CTA. (The "TOP UP" button **does not work in v1** — hidden, since a disabled button below an Upgrade CTA is worse UX than no button at all.)

#### 5.6.1 Owner-pays semantics

Per @borja's design thread: **each owner has N agents, and the owner pays for all messages in the conversation**, regardless of who sends them. The owner's `accountId` (post-`payments-repoint`) is the ledger key for every burn on agents they own.

UI implications:

| Surface | Owner's view | Non-owner's view |
|---|---|---|
| Frame 1 (HOME credits pill) | shown — their balance | shown — their balance, unaffected by other people's agents |
| Frame 2 (agent low-balance pip) | shown — yellow/red signals "you need to top up" | shown — same yellow/red signals "this agent's owner may slow it down" |
| Frame 4 (contact sheet, healthy) | full chart + balance + "Manage" CTA | agent info + small "Operated by {owner}" line, no balance, no upgrade CTA |
| Frame 5 (contact sheet, out of credits) | full chart + "Out of credits" + **Upgrade plan** CTA | "This agent's owner is out of credits — it's currently in slow mode." No upgrade CTA (we can't sell a sub on someone else's behalf). |

Frame 3 ("CONVO future / group balance, multi-user funding") is **out of v1 scope**.

For v1, the iOS app only ships the owner-view paths in detail. The non-owner branch is a 2-3 line conditional in the same views. See team Q A1 to confirm copy + display rules before shipping.

### 5.7 OpenRouter funding — the existential operational risk

This is the part of the system most likely to cause an outage. Today:

- One shared OpenRouter org prepaid balance.
- Pool mints per-instance sub-keys with $20 default cap.
- Sub-key caps are enforced **by OpenRouter**, not by us.
- The org's total balance is **not enforced** — if it hits $0, every sub-key stops, every agent stops, every user sees errors at once.

**v1 OpenRouter funding plan:**

1. **Daily balance check + alert** (Pool already has `getCredits()`; wire to Sentry/Slack at <$200 remaining).
2. **Automatic top-up** via the [OpenRouter REST API](https://openrouter.ai/docs/api-reference/credits) (manual today, but they expose a credits endpoint — confirm before relying on it for funding). Fallback: manual ops top-up procedure documented in a runbook.
3. **Per-account "soft budget" enforced by our backend ledger** — Hermes calls `convos-backend/consume` after each LLM call; the response includes the new balance and a mode flag. Hermes caches it per session and gates next-turn against `PAYMENTS_RESERVED_MAX_TURN_CREDITS`.
4. **Per-sub-key "hard budget" still enforced by OpenRouter** — second line of defense, set to (account_grant × small_buffer) on instance claim.
5. **Daily reconciliation**: a `credits-sweep` job (already exists in `convos-assistants/workers/credits-sweep/`) walks every sub-key's `usage` from OpenRouter, sums spend per account, compares to the convos-backend ledger's deducted total. Discrepancy → Sentry alert.

**Enforcement migration path:**
- **v1**: Hermes-driven (above).
- **Future (Nick's CDO design)**: a Cloudflare Durable Object wraps the agent runtime and gates third-party API access at the infrastructure level — agents inside the container can't bypass it. The ledger model stays unchanged; only the enforcement point moves out of the (untrusted) container. Timing for v1 vs v1.1+ — see team Q C1.

**Per-account vs per-agent budget (migration):**
- Today (convos-assistants): per-instance OpenRouter sub-key, $20 default cap.
- v1 (convos-backend ledger is authoritative): per-owner credit balance, with per-agent usage attribution stored on `CreditLedger.agentInstanceId`.
- The pool's `instanceServices.resourceMeta.limit` is **set from the account's remaining USD budget at claim time** and refreshed periodically. It becomes a fail-safe, not the primary budget.

### 5.8 Why not pass through actual USD cost?

The natural question: why not just grant "X USD of token credits"? Three reasons:

1. **Apple's 30% (or 15%) cut + VAT** means $9.99 ≠ $9.99 to us. Granting $8 of tokens at $6 net = guaranteed losses.
2. **Model cost variability** is severe. Gemini Flash is ~50× cheaper than Claude Opus. A "$8 USD wallet" lets a sophisticated user route everything to expensive models. The virtual currency abstraction lets us multiply expensive-model costs (per env-var multiplier in a future version) without users having to think about it.
3. **Headline-friendliness.** "1,500 credits / month" anchors better than "$1.50 of AI" or "300K Gemini tokens / 50K Claude tokens." The unit is opaque and aspirational.

---

## 6. Backend plan

### 6.0 Reference: PR 191 ledger module

PR 191 ("Payments API foundations") implements the ledger as a typed module in `convos-backend/src/services/payments/` (path approximate — confirm against PR). No HTTP bindings yet; this PRD adds them. The module shape (per @borja's design thread):

**Methods** (confirm signatures against the PR when implementation starts):
- `grant({ owner, amount, grantKind, idempotencyKey, expiresAt? })` → ledger entry + new balance
- `consume({ owner, estimatedCostUsd, agentInstanceId, requestId, costStatus, costSource })` → ledger entry + new balance + `mode: "standard" | "slow_mode" | "blocked"`
- `balance({ owner })` → current balance + active grants
- `check({ owner, reservedCredits })` → `{ allowed: boolean, mode, balance }` (used by Hermes before each turn)
- `promo({ owner, code })` → applies a promo `GrantKind` to the account
- (v1.1) `refund({ owner, ledgerEntryId, reason })` — operator action

**Env vars** (defined by PR 191; treat as authoritative):
- `PAYMENTS_MARKUP_RATE` — multiplier over raw OpenRouter cost
- `PAYMENTS_CREDITS_PER_USD` — credits per $1 nominal
- `PAYMENTS_RESERVED_MAX_TURN_CREDITS` — reservation budget for a single turn
- `PAYMENTS_MIN_BALANCE_CREDITS` — floor to allow new turns (0 = run until empty + slow-mode below; >0 = slow-mode at this floor)

**Pricing formula** (verbatim from PR 191):
```
credits_to_deduct = estimated_cost_usd × markup_rate × credits_per_dollar
```

**Cost source**: Hermes returns `estimated_cost_usd` from OpenRouter's response, with `cost_status: "estimated" | "included" | "unknown"` and `cost_source: <provider>`. For v1, we restrict to known-pricing models so `unknown` doesn't appear. Policy for `unknown` — see team Q C3.

### 6.1 Schema additions

Build on PR 191. Use PR 191's `UserCredits`, `CreditLedger`, `GrantKind` verbatim — do not redefine. The `payments-repoint` branch (PR pending) re-keys `UserCredits` and `CreditLedger` from `inboxId` to `accountId`; that is a hard prereq.

**New tables to add on top of PR 191:**

```prisma
model Subscription {
  id                 String              @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  accountId          String              @db.Uuid
  productId          String              // "app.convos.subs.builder.monthly"
  tier               SubscriptionTier    // Builder | Pro
  period             SubscriptionPeriod  // Monthly | Annual
  status             SubscriptionStatus  // Trial | Active | Grace | BillingRetry | Expired | Revoked
  originalTransactionId String           @unique  // Apple's stable per-subscriber ID
  appAccountToken    String              @unique @db.Uuid  // our generated UUID, sent at purchase
  startedAt          DateTime
  currentPeriodStart DateTime
  currentPeriodEnd   DateTime
  cancelledAt        DateTime?
  gracePeriodEnd     DateTime?
  environment        AppleEnv            // Sandbox | Production
  createdAt          DateTime            @default(now())
  updatedAt          DateTime            @updatedAt
  account            Account             @relation(fields: [accountId], references: [id])
  receipts           AppleReceipt[]

  @@index([accountId])
  @@index([originalTransactionId])
}

model AppleReceipt {
  id                String           @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  subscriptionId    String           @db.Uuid
  transactionId     String           @unique
  notificationType  String           // SUBSCRIBED, DID_RENEW, DID_FAIL_TO_RENEW, GRACE_PERIOD_EXPIRED, REVOKE, REFUND, ...
  notificationSubtype String?
  signedPayload     String           // raw JWS from Apple (audit trail)
  receivedAt        DateTime         @default(now())
  subscription      Subscription     @relation(fields: [subscriptionId], references: [id])

  @@index([subscriptionId])
}

enum SubscriptionTier      { Builder Pro }
enum SubscriptionPeriod    { Monthly Annual }
enum SubscriptionStatus    { Trial Active Grace BillingRetry Expired Revoked }
enum AppleEnv              { Sandbox Production }
```

**Notable absences** (vs an earlier draft of this PRD):

- **No `ModelRateCard` table.** PR 191 deducts against OpenRouter's reported `estimated_cost_usd` uniformly. Per-model differentiation can return in v2 as a simple env-var multiplier without schema changes.
- **No `PolicyConfig` row.** Per Borja, env vars are the v1 config surface. The admin UI for tuning is a v1.1 concern.

**Seed `GrantKind` rows:**
```sql
INSERT INTO grant_kind (id, name, active) VALUES
  ('subscription_builder_2026_05', 'Builder Monthly Grant (2026-05)', true),
  ('subscription_pro_2026_05',     'Pro Monthly Grant (2026-05)',     true),
  ('trial_nux_2026_05',            'NUX 7-Day Trial (2026-05)',       true),
  ('daily_free_2026_05',           'Daily Free Grant (2026-05)',      false);  -- toggled on once amounts decided
```

### 6.2 HTTP API surface

All routes mounted under `/v2` (matches PR 194 pattern). All require `requireAccount` middleware unless noted.

| Method | Path | Body | Returns | Notes |
|---|---|---|---|---|
| `GET` | `/v2/credits/me` | – | `{ balance: number, monthlyGrant: number, monthlyGrantUsed: number, nextRefreshAt: ISO, periodLabel: string }` | Used by HOME pill and Settings row. |
| `GET` | `/v2/credits/me/usage` | `?from=ISO&to=ISO&groupBy=agent\|day` | `{ totalCredits: number, byAgent: [{agentInstanceId, agentName, credits}], byDay: [{date, credits}] }` | Powers contact sheet chart + Settings detail. |
| `GET` | `/v2/credits/me/usage/agent/:agentInstanceId` | `?from=ISO&to=ISO` | `{ credits, samples: [{day, credits}], lastActivity: ISO }` | Powers agent contact sheet. |
| `GET` | `/v2/subscriptions/me` | – | `{ tier, period, status, currentPeriodEnd, productId, willRenew, isInTrial }` | Settings row + paywall current-plan banner. |
| `POST` | `/v2/subscriptions/me/verify` | `{ signedTransactionInfo: string, appAccountToken: UUID }` | `{ subscription, creditsBalance }` | Client posts the JWS from StoreKit after purchase. Server verifies via App Store Server API. Idempotent on `originalTransactionId`. |
| `POST` | `/v2/credits/me/redeem-trial` | – | `{ creditsBalance, grantId }` | Idempotent: returns existing trial grant if already issued for this account. |
| `POST` | `/v2/webhooks/apple/server-notifications` | Apple JWS payload | 200 | **No auth** — verifies Apple's signature against their X.509 cert chain. See [§6.3](#63-app-store-server-notifications-v2-webhook). |
| `GET` | `/v2/products` | – | `{ products: [{id, tier, period, displayName}] }` | Decouples client from hardcoded SKU list (so we can swap StoreKit product IDs without an app update). |
| **Admin** (separate auth — see [§9.12](#912-admin-app)) | | | | |
| `GET` | `/admin/accounts/:id` | – | account detail + subscription + balance + last 50 ledger entries | |
| `POST` | `/admin/accounts/:id/grant` | `{ credits, reason, expiresAt? }` | new ledger entry | |
| `POST` | `/admin/accounts/:id/refund` | `{ credits, reason }` | new ledger entry + slack alert | |
| `GET` | `/admin/policy` | – | current env-var values (read-only mirror in v1) | |
| `GET` | `/admin/grant-kinds` | – | active `GrantKind` rows | |
| `PATCH` | `/admin/grant-kinds/:id` | partial update (active/inactive) | toggle a grant kind on/off | |

### 6.3 App Store Server Notifications v2 webhook

Apple POSTs to `/v2/webhooks/apple/server-notifications` for every renewal, billing retry, grace start/end, refund, revoke. Critical events to handle:

| `notificationType` | Action |
|---|---|
| `SUBSCRIBED` (initial / resubscribe) | Create `Subscription` row, grant tier credits. |
| `DID_RENEW` | Move `currentPeriodEnd`, grant fresh tier credits with new `idempotencyKey=originalTransactionId:periodStart`. |
| `DID_FAIL_TO_RENEW` (subtype: `BILLING_RETRY`) | Set status → `BillingRetry`. Do NOT grant credits. |
| `DID_FAIL_TO_RENEW` (subtype: `GRACE_PERIOD`) | Set status → `Grace`. Continue serving until `gracePeriodEnd`. |
| `GRACE_PERIOD_EXPIRED` | Set status → `Expired`. New burns → slow-mode only. |
| `EXPIRED` | Set status → `Expired`. |
| `REVOKE` (family sharing revocation) | Set status → `Revoked`. Burn all remaining credits via negative ledger entry (so balance reads 0). |
| `REFUND` | Set status → `Revoked`. Negative ledger entry. Slack alert. |
| `DID_CHANGE_RENEWAL_STATUS` (auto-renew toggled) | Update `willRenew` field. No credit change. |
| `DID_CHANGE_RENEWAL_PREF` (cross-grade Builder↔Pro) | Update tier. Pro-rate by re-granting prorated delta. |
| `PRICE_INCREASE` (consent required) | Update flag for Settings banner. |

Verification: Apple signs the entire payload as JWS. The header's `x5c` array contains the cert chain — verify chain root against `AppleRootCA-G3`. Library: `app-store-server-library` (Apple-published TS package).

Idempotency: Apple may resend. Use `(originalTransactionId, transactionId, notificationType)` as the dedup key — store every receipt in `AppleReceipt` table, ignore duplicates.

### 6.4 Linking Apple's transaction to our `accountId`

The Apple receipt is tied to Apple ID, not our `accountId`. The bridge: **`appAccountToken`** (a UUID we generate per-purchase, pass to StoreKit, Apple includes it in the receipt and every renewal notification).

Flow:
1. iOS app generates `appAccountToken = UUID()` before calling `product.purchase(options:)`.
2. iOS sends the token along with the `signedTransactionInfo` to `POST /v2/subscriptions/me/verify`.
3. Backend: verify signature → check `appAccountToken` matches an authenticated `accountId` (we stored it in `Subscription.appAccountToken` at verify time) → bind subscription to account.
4. Every subsequent Apple notification arrives with the same `appAccountToken`. Backend looks it up to find the account.

Edge case: a user signs in to Convos on a 2nd device with a different `accountId` but same Apple ID. Apple's `originalTransactionId` is the same, but our second device generated a new `appAccountToken`. Resolution: when we receive a `verify` call with a new `appAccountToken` but a known `originalTransactionId`, we **trust the latest accountId** (transfer the sub). Log a warning.

### 6.5 Slow-mode routing — Hermes-driven, backend-decided

The agent runtime (Hermes, in `convos-assistants/runtime/openclaw/`) is the consumer of the ledger. Flow per turn:

```
1. User sends message to agent.
2. Hermes handle_message():
   a. POST /v2/credits/check { accountId, agentInstanceId, reservedCredits: PAYMENTS_RESERVED_MAX_TURN_CREDITS }
      → response: { allowed, mode: "standard"|"slow_mode"|"blocked", balance, routeModel }
   b. If mode == "blocked": send "insufficient funds" reply, do not call OpenRouter.
   c. If mode == "slow_mode": call OpenRouter with `routeModel = PAYMENTS_SLOW_MODE_MODEL_KEY`.
   d. If mode == "standard": call OpenRouter with the agent's configured model.
3. After OpenRouter response, in parallel:
   a. Relay reply to convos (XMTP message).
   b. POST /v2/credits/consume { accountId, agentInstanceId, requestId, estimated_cost_usd, cost_status, cost_source, prompt_tokens, completion_tokens, model }
      → response: { balance, mode }
   c. Hermes caches { balance, mode } per session.
4. Next turn re-evaluates from the cached state (and re-checks via /check at safe intervals).
```

**Cache staleness on mid-session top-up** — open question, see team Q C5. Initial approach: refresh on every turn boundary anyway (cheap, the `/check` call is fast), and add a push from backend to Hermes on grant events if needed in v1.1.

**Long-term enforcement** moves into Nick's Cloudflare Durable Object wrapping the runtime; ledger model stays the same.

### 6.6 Push notifications for subscription state

Extend `PushNotificationPayload` (in iOS `ConvosCore/Sources/ConvosCore/Notifications/PushNotificationPayload.swift`) with a new `notificationData.type` value:

- `"credits_low"` — fires at 20% remaining. Body: "Your credits are running low."
- `"credits_depleted"` — fires at 0. Body: "Out of credits — agents are now in slow mode."
- `"sub_renewed"` — fires on `DID_RENEW`. Silent (or quiet). Body: "Your Builder plan renewed. Fresh credits added."
- `"sub_grace_period"` — fires on `BILLING_RETRY` / `GRACE_PERIOD`. Body: "Your payment didn't go through — fix it in Settings."
- `"sub_expired"` — fires on `EXPIRED` / `REVOKED`.

Backend triggers these from the webhook handler (`sub_*`) and from the credits-burn path (`credits_*`).

### 6.7 OpenRouter funding ops

Wire (new) `convos-assistants/workers/openrouter-balance-monitor`:
- Polls `getCredits()` every 5 min.
- Posts Sentry breadcrumb + Slack alert at `totalCredits - totalUsage < $200`.
- Optionally: auto-top-up via OpenRouter's billing API if balance < $100 (research feasibility before relying).

### 6.8 Reconciliation worker

Daily (cron), reconcile per-account ledger spend vs OpenRouter actual cost:
- Walk every active sub-key (via Pool's existing `keys` enumeration).
- For each key's `agentInstanceId`, sum all `CreditLedger` entries with that `agentInstanceId` since last reconciliation.
- Convert credits back to USD via the rates stored in each ledger row.
- Compare to OpenRouter's reported `usage` for that key.
- Discrepancy > 5% → Sentry alert.

This catches: ledger races, OpenRouter response parsing bugs, missed deductions, double-deductions.

---

## 7. iOS UI spec (per frame)

Eight frames correspond to the design figure. The frame-by-frame UI spec uses neutral frame numbers (1-8).

### Frame 1 — HOME (credits indicator)

**File:** `Convos/Conversations List/ConversationsView.swift` (line 113+ — navbar area, where filter icon currently lives).

**Component to add:** `CreditsBadgeView`. SwiftUI view, leading-aligned in the navigation bar (left of "Convos" title, opposite the existing right-side filter button).

```
Capsule background (.thinMaterial, isOnSurface)
  HStack(spacing: 4) {
    Image(systemName: "sparkles") (or custom credits glyph)
    Text("\(balance.formatted(.number.grouping(.automatic)))")
      .font(.subheadline.weight(.medium))
      .monospacedDigit()
  }
  .padding(.horizontal, 10)
  .padding(.vertical, 4)
```

States:
- `balance > 20% of monthlyGrant` → default tint, no decoration.
- `balance ≤ 20%` → amber tint, no animation.
- `balance == 0` → red tint, pulses once on appear.
- Tap → push `CreditsDetailView` (Settings → My Subscription detail).

**ViewModel:** new `CreditsBalanceViewModel` (@Observable). Reads from new `CreditsRepository` (mirrors `MyProfileRepository` pattern; observes DB via GRDB watch). Periodic refresh: every 60s + on app foreground + on push receipt.

### Frame 2 — CONVO v1 (per-agent low-balance indicator)

**Files to modify:**
- `Convos/Conversation Detail/ConversationMemberView.swift` (agent row in the conversation list/header)
- `Convos/Conversation Detail/Messages/MessagesListView/MessagesGroupView.swift` (already has `isOutOfCredits` logic via `profile.isOutOfCredits` — extend to handle low and out states distinctly)

**Component to add:** `AgentCreditPipView` — a tiny pip overlay on the agent avatar (bottom-right corner, similar to a presence dot).

```
ZStack(alignment: .bottomTrailing) {
  AvatarView(agent)
  Circle().fill(pipColor).frame(width: 10, height: 10)
    .overlay(Circle().stroke(.background, lineWidth: 2))
}
```

`pipColor`:
- agent balance ≤ 20% → amber
- agent balance == 0 (slow-mode) → red
- agent balance > 20% → no pip (omit Circle)

When a message bubble's agent is in slow-mode, append a footer to the bubble:
```
HStack(spacing: 4) {
  Image(systemName: "tortoise.fill").imageScale(.small)
  Text("Slow mode • Upgrade")
}
.font(.caption2)
.foregroundStyle(.secondary)
.onTapGesture { presentPaywall = true }
```

Pip is visible to **everyone** in the conversation; the tap-target opens the contact sheet (which itself branches owner vs non-owner per §5.6.1).

### Frame 3 — CONVO future (group balance)

**Out of scope for v1.** Marked here so we don't accidentally design it in.

### Frame 4 — CONTACT sheet (agent profile + usage chart)

**File:** `Convos/Conversation Detail/ConversationMemberView.swift` currently shows agent row but no dedicated agent profile sheet exists yet. This is a new sheet.

**New file:** `Convos/Conversation Detail/AgentContactSheet/AgentContactSheetView.swift`. Presented via `.sheet` from any tap on an agent's avatar in a conversation.

Layout:
```
VStack(spacing: 24) {
  // Header
  VStack(spacing: 8) {
    AvatarView(agent, size: 96)
    Text(agent.displayName).font(.title2.bold())
    Text("ASSISTANT").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
  }

  if viewModel.isViewerOwner {
    // Credits pill — owner only
    Capsule().fill(.tertiary).overlay {
      HStack { Image("sparkles"); Text("\(agent.allowance) credits / mo") }
    }

    // Usage chart (Swift Charts) — owner only
    Chart(usageSamples) { sample in
      BarMark(x: .value("Day", sample.day), y: .value("Credits", sample.credits))
    }
    .frame(height: 160)

    AgentContactActionsView(state: viewModel.state)   // owner CTAs
  } else {
    // Non-owner: agent info only
    Text("Operated by \(agent.ownerDisplayName)")
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }
}
.padding(.horizontal)
.padding(.bottom)
```

**ViewModel:** `AgentContactSheetViewModel`. Loads data from `GET /v2/credits/me/usage/agent/:agentInstanceId` and `GET /v2/credits/me`. Cached for 60s. Skips the credit API calls when `isViewerOwner == false`.

### Frame 5 — CONTACT sheet, out-of-credits state

Same view as frame 4. State swap inside `AgentContactActionsView` (owner-only path):

```
if state.balance == 0 {
  VStack(spacing: 12) {
    Label("Out of credits", systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(.red)
      .font(.headline)

    Text("This agent is using a slower model. Upgrade to keep them sharp.")
      .multilineTextAlignment(.center)
      .font(.subheadline)
      .foregroundStyle(.secondary)

    Button(action: openPaywall) {
      Text("Upgrade plan").frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
  }
} else if state.balance < 0.2 * state.monthlyGrant {
  // Low: amber banner + upgrade CTA, but keep chart
} else {
  // Healthy: no extra CTA
}
```

For **non-owners** in the depleted state, the sheet shows a passive note: *"This agent's owner is out of credits — it's currently in slow mode."* No upgrade CTA (we can't sell a subscription on someone else's behalf).

The "TOP UP" button is hidden in v1 (gating consumable IAP to v1.1).

### Frame 6 — SETTINGS (subscription row)

**File:** `Convos/App Settings/AppSettingsView.swift`. Add a new section between `assistantsSection` (line ~143) and `connectionsSection`:

```swift
private var subscriptionSection: some View {
    Section {
        NavigationLink(destination: SubscriptionDetailView()) {
            HStack {
                Image(systemName: "sparkles")
                VStack(alignment: .leading) {
                    Text("My subscription").font(.body)
                    Text("\(balance) remaining / \(monthlyGrant) per month")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

New view: `Convos/App Settings/Subscription/SubscriptionDetailView.swift`. Shows:
- Current plan (Builder Monthly / Pro Annual / etc.) + renewal date
- Credit balance + monthly grant + remaining-period gauge
- Usage breakdown chart (last 30 days, byAgent)
- Buttons:
  - **Change plan** → opens `PaywallView` with "currentTier" highlighted
  - **Manage on App Store** → opens `https://apps.apple.com/account/subscriptions` via `Environment(\.openURL)`
  - **Restore purchases** → calls `AppStore.sync()` then re-verifies on backend

### Frame 7 — SUBSCRIBE / paywall (Monthly / Annual toggle, Builder / Pro tiles)

**New file:** `Convos/Subscription/PaywallView.swift`.

Layout (using SwiftUI native, NOT a 3rd-party paywall lib):
```
ScrollView {
  VStack(spacing: 32) {
    // Hero
    VStack(spacing: 12) {
      Image(systemName: "sparkles").font(.system(size: 64))
      Text("Power your agents").font(.largeTitle.bold())
      Text("Subscribe to keep your assistants sharp.")
        .multilineTextAlignment(.center).foregroundStyle(.secondary)
    }

    // Monthly / Annual toggle
    Picker("Period", selection: $period) {
      Text("Monthly").tag(SubscriptionPeriod.monthly)
      Text("Annual").tag(SubscriptionPeriod.annual)
    }
    .pickerStyle(.segmented)
    .padding(.horizontal)

    // Tier cards
    VStack(spacing: 16) {
      TierCard(tier: .builder, period: period, isCurrent: viewModel.currentTier == .builder, products: viewModel.products)
      TierCard(tier: .pro, period: period, isCurrent: viewModel.currentTier == .pro, products: viewModel.products)
    }
    .padding(.horizontal)

    // Legal
    HStack(spacing: 24) {
      Link("Terms", destination: termsURL)
      Link("Privacy", destination: privacyURL)
      Button("Restore", action: viewModel.restore)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
.padding(.vertical, 32)
```

`TierCard` (per tier):
```
VStack(alignment: .leading, spacing: 12) {
  HStack {
    Text(tier.displayName).font(.title3.bold())
    Spacer()
    Text(price).font(.title3.weight(.medium))
  }
  Text(perMonthCaption).font(.caption).foregroundStyle(.secondary)
  Divider()
  ForEach(tier.bulletPoints) { bullet in
    HStack(alignment: .top) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      Text(bullet)
    }
  }
  Button(action: purchase) { Text(ctaText).frame(maxWidth: .infinity) }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(viewModel.purchasing)
}
.padding(16)
.background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
.overlay(
  RoundedRectangle(cornerRadius: 16)
    .stroke(isCurrent ? .accentColor : .clear, lineWidth: 2)
)
```

**ViewModel:** `PaywallViewModel`.
- Loads products via `Product.products(for: ProductIDs.all)` (StoreKit 2).
- Maps StoreKit products by ID to tiers.
- On tap of CTA:
  - generate `appAccountToken = UUID()`
  - call `product.purchase(options: [.appAccountToken(appAccountToken)])`
  - on success → unwrap signed `Transaction`, send to `POST /v2/subscriptions/me/verify`
  - on backend success → dismiss paywall, refresh balance + sub state
  - on `userCancelled` → silently dismiss CTA-loading state
  - on `pending` → show "Awaiting approval" banner

### Frame 8 — NUX (paywall step in onboarding, with Skip)

**File:** `Convos/Conversation Detail/Conversation Detail Drawer/ConversationOnboardingView.swift`. Add a new state to the existing state machine:

```swift
enum OnboardingState {
  case idle, started, settingUpProfile, presentingProfileSettings
  case setupProfile, savedProfileSuccess
  case requestNotifications, notificationsEnabled, notificationsDenied
  case presentingPaywall              // NEW: shown after savedProfileSuccess
  case trialClaimed                   // NEW
}
```

After `.savedProfileSuccess`, transition to `.presentingPaywall`. Show `PaywallView` modified slightly:
- Hero copy reads "Welcome — choose your plan or start with a 7-day trial."
- A "Skip for now" button under the legal row → calls `POST /v2/credits/me/redeem-trial`, sets state to `.trialClaimed`, shows brief "You've got 500 trial credits — they expire in 7 days" confirmation, then proceeds to `.requestNotifications`.

If the user buys instead, post-verify proceed directly to `.requestNotifications`.

### Frame summary — file map

| Frame | New / Modified files |
|---|---|
| 1 HOME pill | `Convos/Conversations List/ConversationsView.swift` (modify, line ~113) + `Convos/Subscription/CreditsBadgeView.swift` (new) |
| 2 CONVO indicators | `Convos/Conversation Detail/ConversationMemberView.swift` (modify) + `Convos/Conversation Detail/Messages/MessagesListView/MessagesGroupView.swift` (modify) + `Convos/Subscription/AgentCreditPipView.swift` (new) |
| 4-5 CONTACT sheet | `Convos/Conversation Detail/AgentContactSheet/AgentContactSheetView.swift` (new) + `AgentContactSheetViewModel.swift` (new) |
| 6 SETTINGS row | `Convos/App Settings/AppSettingsView.swift` (modify, after line ~143) + `Convos/App Settings/Subscription/SubscriptionDetailView.swift` (new) |
| 7 PAYWALL | `Convos/Subscription/PaywallView.swift` (new) + `PaywallViewModel.swift` (new) + `Convos/Subscription/TierCard.swift` (new) |
| 8 NUX | `Convos/Conversation Detail/Conversation Detail Drawer/ConversationOnboardingView.swift` (modify, extend state machine) |

### iOS architecture additions

Following the established Repository / Writer pattern (e.g. `MyProfileRepository` / `MyProfileWriter`):

| New module | Purpose | File |
|---|---|---|
| `CreditsRepository` | Observe credit balance from local cache + remote refresh | `ConvosCore/Sources/ConvosCore/Storage/Repositories/CreditsRepository.swift` |
| `CreditsService` | Call HTTP API; orchestrate refresh on push receipt | `ConvosCore/Sources/ConvosCore/Services/Credits/CreditsService.swift` |
| `SubscriptionRepository` | Observe current subscription state | `ConvosCore/Sources/ConvosCore/Storage/Repositories/SubscriptionRepository.swift` |
| `SubscriptionService` | StoreKit 2 orchestration + verify call to backend | `ConvosCore/Sources/ConvosCore/Services/Subscription/SubscriptionService.swift` |
| `Product IDs` | Hardcoded SKU map (lives in main app target, not Core, since App Store Connect is iOS-only) | `Convos/Subscription/ProductIDs.swift` |
| `CreditBalance`, `Subscription` models | Cross-platform value types | `ConvosCore/Sources/ConvosCore/Storage/Models/CreditBalance.swift`, `Subscription.swift` |
| GRDB tables | Local cache of balance + sub state | `ConvosCore/Sources/ConvosCore/Database/Migrations/v{N}_credits.swift` |

`SubscriptionService` listens to `Transaction.updates` AsyncSequence at app launch (for renewals / external updates) and re-verifies any new transaction with the backend.

`SubscriptionService` and `CreditsService` are both ConvosCore (cross-platform). `Product.products(for:)` and `Transaction.updates` are StoreKit 2 — available on macOS 12+, iOS 15+ → doesn't break the macOS test compilation rule from `CLAUDE.md`.

---

## 8. Bypass / testability strategy

Recommended **three-prong** approach (do all three — they cover different layers):

### 8.1 StoreKit Configuration file (dev/sim only)

**Add:** `Convos/Resources/Convos.storekit` (xcassets-style local config).

Defines 4 subscription products + sandbox prices. Lets us:
- Run the full purchase UI in Simulator without any App Store Connect setup.
- Force renewal cycles in seconds (Xcode → Debug → StoreKit → Manage Transactions).
- Simulate billing-retry, grace period, revoke without hitting Apple sandbox.
- Test intro offers / free trials before App Store Connect approves them.

Toggle: build config `DEBUG` and `LOCAL` schemes use the .storekit file; `RELEASE` uses live App Store Connect.

### 8.2 Local mock CreditsService + bypass flag

**Add:** `MockCreditsService` and `MockSubscriptionService` in `ConvosCore/Tests/ConvosCoreTests/Mocks/`, **and** exposed to the main app behind a launch flag:

```swift
@main struct ConvosApp: App {
  init() {
    if ProcessInfo.processInfo.arguments.contains("--use-mock-credits") {
      AppDIContainer.shared.creditsService = MockCreditsService.preset(.builder_50pct)
    }
  }
}
```

Presets the user/designer can play with:
- `.builder_ample` — Builder plan, 1,400 credits remaining
- `.builder_low` — Builder, 180 credits (≤20%)
- `.builder_depleted` — Builder, 0 credits, slow-mode
- `.pro_ample` — Pro, 4,500 credits
- `.trial_active` — trial, 350 credits, expires in 4 days
- `.trial_expired` — no sub, 0 credits, slow-mode
- `.billing_retry` — Pro sub in BillingRetry
- `.grace_period` — Builder in Grace, 2 days remaining
- `.no_sub_no_trial` — never subscribed, no trial available

This lets designers/QA dogfood every UI state without backend or App Store sandbox.

### 8.3 Hidden dev menu state picker

**Modify:** existing Debug toggle path (per recent commit `6b18a6a4 "Hide debug injector button behind a Debug toggle"`).

Add an entry to the existing debug menu: `Credits state → [preset list]`. Tapping a preset swaps the live mock service preset in-app, no relaunch needed. Useful during design review.

### 8.4 Bypass the `requireAccount` middleware until SIWE flow ships

Backend-side decoupling: ship `/v2/credits/*` and `/v2/subscriptions/*` routes **without** mounting `requireAccount` until iOS has shipped the SIWE upgrade. Use a feature flag (`PAYMENTS_REQUIRE_ACCOUNT=false` env var) that toggles the middleware. PR 194's body explicitly flags this coordination — honor it.

For dev work, also support a `?devAccountId=` query param when `NODE_ENV !== production` so iOS QA builds can hit the credits routes with a mock account.

---

## 9. Apple flow requirements

### 9.1 Roles, access, and prerequisites

| Item | Requirement | Notes |
|---|---|---|
| Apple Developer Program enrollment | Active organization account | Convos org account on `developer.apple.com`. Account Holder identity must be known (one specific person). |
| Account Holder | One person | The only role that can sign legal agreements and assign Admin roles. Needs phone + Apple ID 2FA. |
| Admin role | At least 2 people | Required to enroll devices, manage App IDs, manage certificates. Two-person rule prevents single-point failure. |
| App Manager role | The iOS engineer(s) | Can edit app metadata, manage IAPs, manage TestFlight. Cannot edit agreements or banking. |
| Finance role | One ops/finance person | Required for App Store Connect → Agreements/Tax/Banking. |
| **Paid Apps Agreement** | **Must be signed before any IAP can be created** | Account Holder signs in App Store Connect → Agreements, Tax, and Banking. |
| Banking info | Required | One bank account per legal entity. Apple holds first payment after activation per their payout schedule. |
| Tax forms | W-8BEN (non-US) or W-9 (US) + per-region tax forms (EU VAT registered in Ireland, UK VAT, AU GST, etc.) | Each form gates payouts from that region. |
| Apple Account Holder Apple ID | Cannot be the same as any sandbox tester Apple ID | Apple enforces this; sandbox testers must use a fresh email never used as a real Apple ID. |

**Blocker:** Subscriptions cannot be created until Paid Apps Agreement is fully signed *and* banking/tax show ✅ in App Store Connect. Apple verification is asynchronous; do not block iOS dev work on it but do not promise a launch date that assumes same-day activation either.

### 9.2 Apple Developer Portal — App IDs & capabilities

We currently have **12 bundle IDs** spread across 3 targets × 4 environments:

| Target | Local | Dev (TestFlight) | PR Preview | Production |
|---|---|---|---|---|
| Main app | `org.convos.ios-local` | `org.convos.ios-preview` | `org.convos.ios-preview.pr` | `org.convos.ios` |
| App Clip | `org.convos.ios-local.Clip` | `org.convos.ios-preview.Clip` | `org.convos.ios-preview.pr.Clip` | `org.convos.ios.Clip` |
| NSE | `org.convos.ios-local.ConvosNSE` | `org.convos.ios-preview.ConvosNSE` | `org.convos.ios-preview.pr.ConvosNSE` | `org.convos.ios.ConvosNSE` |

For each of the 12 App IDs in **Certificates, Identifiers & Profiles → Identifiers**, verify or set the following capability flags. The main-app row gains **In-App Purchase**; App Clip and NSE rows do not.

**Main app App IDs (4 of them):**

| Capability | Status today | After this work | Notes |
|---|---|---|---|
| App Groups | ✅ enabled (`group.<bundle>`) | unchanged | Used to share credit balance cache between main app + NSE. |
| Associated Domains | ✅ enabled | unchanged | Universal links. |
| App Attest | ✅ enabled | unchanged | Firebase AppCheck attestation. |
| HealthKit | ✅ enabled | unchanged | Existing capability. |
| Push Notifications | ✅ enabled | unchanged | Existing capability. |
| Keychain Sharing | ✅ enabled | unchanged | Cross-target identity store. |
| **In-App Purchase** | ❌ not enabled | ✅ enable | **Required for StoreKit 2 subscriptions on all 4 main-app App IDs.** |
| Sign in with Apple | ❌ not enabled | **decision pending** | See §9.10 — Apple Guideline 4.8 may force this. |

**App Clip App IDs (4):** no capability changes. App Clips cannot present subscription paywalls or sell auto-renewables — they share entitlements with the parent app via the existing `parent-application-identifiers` link.

**NSE App IDs (4):** no capability changes. NSE doesn't initiate purchases; it only consumes push.

**After enabling In-App Purchase on the 4 main-app App IDs:**
- All 4 main-app provisioning profiles need to be **regenerated** (development + ad-hoc + App Store). Stale profiles will fail to recognize StoreKit transactions.
- Xcode → Settings → Accounts → Download Manual Profiles. CI builds need to pull new profiles via Fastlane/match or whatever wires our current setup.

**No `.entitlements` file change required** — In-App Purchase is enabled in the App ID's capabilities and reflected in the provisioning profile; there is no entitlement key to add to `Convos.entitlements`. (Common confusion: `com.apple.developer.in-app-payments` is **Apple Pay PassKit**, *not* StoreKit IAP.)

### 9.3 Apple Developer Portal — Keys

We need one new private key in **Certificates, Identifiers & Profiles → Keys**. It downloads as a `.p8` file **exactly once** — there is no re-download. Store immediately in 1Password (or whatever the team standard is) and inject into convos-backend via secrets manager.

| Key | Apple's name in portal | Why we need it | Used by |
|---|---|---|---|
| App Store Server API key | "App Store Connect API Key" with the role **App Manager** (or higher) | Sign JWTs to call `api.appstoreconnect.apple.com` for `Get Transaction Info`, `Get Subscription Statuses`, `Get Notification History`, `Get Refund History`. Required to verify in-app purchases server-side and reconcile state. | `convos-backend/src/services/subscriptions/apple-server-api.ts` |
| In-App Purchase Subscription API Key | "In-App Purchase Subscription API Key" (App Store Connect → Users & Access → Integrations → In-App Purchase) | Sign promotional offers (used in v1.1 for retention campaigns) and *server-driven* subscription changes. **Not required for v1** if we don't ship promo offers. | (v1.1) |

For v1 we only need the first key. Note the **Key ID** (10-char string) and the **Issuer ID** (UUID from the Keys page header). Both are needed alongside the `.p8`.

Add to `convos-backend/.env.example`:
```
APPLE_BUNDLE_ID=org.convos.ios
APPLE_BUNDLE_ID_DEV=org.convos.ios-preview
APPLE_KEY_ID=<10 chars>
APPLE_ISSUER_ID=<uuid>
APPLE_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----   # base64 or escaped newlines
APPLE_ENV=production         # or `sandbox` for non-prod backends
```

**Cert refresh:** No new certificates needed (StoreKit 2 doesn't use the legacy `Get Receipt` flow). Existing APNs Auth Key (`.p8`) for push is unrelated and stays.

### 9.4 App Store Connect — Agreements, Tax, Banking (one-time)

Before any subscription product can be saved, these three sections in **App Store Connect → Agreements, Tax, and Banking** must show ✅:

| Section | What to do |
|---|---|
| **Paid Apps Agreement** | Account Holder reviews and accepts the latest version. |
| **Banking** | Add organization bank account (one per Apple-supported region). USD account preferred. SWIFT/IBAN as needed. |
| **Tax forms** | W-9 (US) or W-8BEN-E (non-US) at minimum. Per-region forms for major markets (EU/UK/CA/AU/JP) accelerate payouts. |

**Confirm** before moving on: top of App Store Connect dashboard should show "Paid Applications Agreement: Active". If status is "Effective" or "Pending", subs creation is still blocked.

### 9.5 App Store Connect — App records & Subscription products

#### 9.5.1 App records

| App record | Bundle ID | Why | SKU |
|---|---|---|---|
| **Convos** | `org.convos.ios` | Production. Required. | `convos-prod` |
| **Convos (Dev)** | `org.convos.ios-preview` | Sandbox/TestFlight realism for full Apple flow incl. ASSN v2 webhooks. Recommended (see team Q D1). | `convos-dev` |

PR Preview (`org.convos.ios-preview.pr`) and Local (`org.convos.ios-local`) do **not** get App Store Connect records. They use a local `.storekit` Configuration file (already in §8.1) for product definitions.

For each app record, fill these fields up-front (some are pre-fillable from the Production record by Apple, but the Dev record needs them set explicitly):

- **Primary language** (English)
- **Bundle ID** (select from dropdown — must already exist in Developer Portal)
- **SKU** (internal identifier, see table above)
- **Primary category** (Social Networking) + secondary (Productivity)
- **Default app icon** (1024×1024 PNG, no alpha)
- **Privacy Policy URL** (`https://convos.org/privacy`)
- **Support URL** (`https://convos.org/support`)
- **Marketing URL** (optional)
- **Age rating questionnaire** — answer for: in-app purchases (yes), simulated gambling (no), user-generated content (yes — with moderation), unrestricted web access (no for v1 — confirm with PM), social networking (yes). Expect 4+ rating.
- **App Privacy** nutrition label (see §9.8)

#### 9.5.2 Subscription Group

In each app record (Production + Dev), under **Monetization → Subscriptions**, create **one** Subscription Group:

- **Reference Name:** `Convos Plans`
- **Display Name (English):** `Convos`
- **Localizations:** add languages we support in App Store metadata. At minimum English-US. Each localization needs a group display name.

Why one group: Apple uses subscription group membership to enforce upgrade/downgrade/cross-grade proration and to ensure a user cannot have two overlapping subscriptions. Builder and Pro are tiers within the same group; the user can swap between them at any time.

#### 9.5.3 Subscription products — 4 SKUs

Add the following 4 auto-renewable subscriptions to the **Convos Plans** group, in this rank order (tier ranking matters: Apple uses it to decide whether a switch is an "upgrade" — immediate proration — vs a "downgrade" — deferred to next period):

| Rank | Tier | Reference Name | Product ID | Duration | Price (USD) | Family Sharing |
|---|---|---|---|---|---|---|
| 1 (highest) | Pro | Pro Annual | `app.convos.subs.pro.annual` | 1 year | $239.99 | OFF (v1) |
| 2 | Pro | Pro Monthly | `app.convos.subs.pro.monthly` | 1 month | $29.99 | OFF |
| 3 | Builder | Builder Annual | `app.convos.subs.builder.annual` | 1 year | $79.99 | OFF |
| 4 (lowest) | Builder | Builder Monthly | `app.convos.subs.builder.monthly` | 1 month | $9.99 | OFF |

For each subscription, fill:

- **Subscription Display Name** (English-US): "Convos Builder" / "Convos Pro"
- **Description** (English-US, ~70 words): mention monthly credit grant, agent usage, slow-mode fallback policy. Plain English only — Apple rejects marketing speak like "best" / "amazing" / "limited time".
- **Promotional Image** (1024×1024 PNG, no alpha, no transparency) — one per subscription
- **Review Screenshot** (640×920 minimum, JPG or PNG) — shows the paywall + subscribed state in the iOS UI. App Store Reviewers cannot test without it.
- **Review Notes**: brief paragraph explaining how to access the paywall (e.g. "Settings → My Subscription → Upgrade plan").
- **Pricing**: select the USD anchor price; Apple auto-converts for other storefronts. Optionally pin specific prices per country.
- **Family Sharing**: OFF for v1 (per existing PRD).

For each app record (Production + Dev), repeat this for all 4 products. Same product IDs across both records — Apple scopes products by bundle ID, so there is no collision.

#### 9.5.4 Free trials & intro offers

For v1, our trial is **server-issued credits** (the 500-credit, 7-day grant via `POST /v2/credits/me/redeem-trial`), **not** an Apple-issued free trial. This sidesteps the Apple-Subscription-Offer mechanics (which would force trial-length disclosure at every paywall, complicate cross-grade rules, and require setting up Promotional Offer Signature signing).

If we later want a free-trial Apple-issued (App Store Review prefers this for "introductory" wording), we add it as an **Introductory Offer** per region per subscription. Defer to v1.1.

### 9.6 App Store Server Notifications v2 — wiring

In each app record (Production + Dev) → **App Information → App Store Server Notifications**:

| Setting | Production app record | Dev app record |
|---|---|---|
| **Version** | Version 2 (NOT v1) | Version 2 |
| **Production Server URL** | `https://api.convos.app/v2/webhooks/apple/server-notifications` | `https://api.dev.convos.app/v2/webhooks/apple/server-notifications` |
| **Sandbox Server URL** | `https://api.dev.convos.app/v2/webhooks/apple/server-notifications` (same as Dev's production URL — Apple sends sandbox events here for the Production app record) | same as Dev's production URL |

Reasoning on URL pairing: Apple sends notifications to two URLs per app record — one for production receipts, one for sandbox receipts (TestFlight + Sandbox Tester accounts). For our Production app record, sandbox events from TestFlight test installs of the prod build are routed to the dev backend URL — keeping the production backend's webhook table free of sandbox noise.

**Test the wiring once webhook URLs are configured:**
- Use App Store Connect → App Information → "Send Test Notification" button (sends `TEST` notification type).
- Backend must respond `200 OK` within ~10 seconds.
- Apple retries failed deliveries for 3 days with exponential backoff — but those retries trash the audit log. Make sure the endpoint is healthy from day 1.

### 9.7 Sandbox testers, StoreKit Configuration files, and the environment matrix

#### 9.7.1 Sandbox Apple IDs

Create 6-10 **Sandbox Tester** accounts in App Store Connect → **Users and Access → Sandbox Testers**. Apple-imposed rules:

- The email must be **a fresh email never used as a real Apple ID anywhere on any device**.
- We use `+tag` aliases on our team domain: `sandbox-us@convos.org`, `sandbox-eu-fr@convos.org`, `sandbox-jp@convos.org`, etc.
- Birthday must be 18+ (or Apple flags as kids' account).
- Country/region matters — set per tester for storefront testing (different prices, different VAT, different intro-offer availability).
- Test devices must be signed out of any real Apple ID before signing in with a sandbox tester (Settings → App Store → tap email → Sign Out).
- Sandbox accounts auto-renew **once per period at accelerated speeds**: monthly → 5 minutes, yearly → 1 hour, then expire after **6 renewal cycles** then "expire" the sub. Plan testing accordingly.

| Sandbox tester role | Country | Purpose |
|---|---|---|
| US sandbox tester | US | Default flow, US tax, standard pricing |
| EU sandbox tester (DE) | DE | EU VAT realism, EUR pricing |
| UK sandbox tester | UK | GBP pricing |
| JP sandbox tester | JP | JPY pricing, intro-offer eligibility (Japan rules differ) |
| Family Sharing organizer (US) | US | (v1.1 prep) |
| Family Sharing member | US | (v1.1 prep) |
| Refund tester | US | Used exclusively to trigger refunds via App Store Connect → Transactions |
| Lapse tester | US | Used to test grace period + billing retry |

#### 9.7.2 StoreKit Configuration files

In the iOS repo, create:
- `Convos/Resources/Convos.storekit` — defines the 4 SKUs locally with the same product IDs as App Store Connect. Lets Local/PR builds run the full paywall + purchase flow without any backend-Apple-account binding.
- Configure each Xcode scheme:
  - **Convos (Local).xcscheme**: Run → Options → StoreKit Configuration = `Convos.storekit`
  - **Convos (PR Preview).xcscheme**: same
  - **Convos (Dev).xcscheme**: StoreKit Configuration = **None** (uses TestFlight sandbox)
  - **Convos (Prod).xcscheme**: StoreKit Configuration = **None** (uses production App Store)

Local + PR also need `PAYMENTS_REQUIRE_ACCOUNT=false` on backend so they don't require SIWE auth.

#### 9.7.3 Per-environment matrix

| Env | Bundle ID | StoreKit source | Backend webhook URL | Tester Apple ID |
|---|---|---|---|---|
| Local | `org.convos.ios-local` | `.storekit` file | `http://localhost:PORT/v2/webhooks/apple/server-notifications` (will not receive real Apple events) | none |
| Dev (TestFlight) | `org.convos.ios-preview` | Sandbox (App Store Connect Dev record) | `https://api.dev.convos.app/...` | Sandbox tester required |
| PR Preview | `org.convos.ios-preview.pr` | `.storekit` file | `https://api.dev.convos.app/...` | none |
| Production | `org.convos.ios` | Production (App Store Connect Prod record) | `https://api.convos.app/...` (prod) + `https://api.dev.convos.app/...` (sandbox for prod-build sandbox testing) | Real Apple ID or Sandbox tester |

### 9.8 App Privacy nutrition label changes

In App Store Connect → App Information → **App Privacy**, the existing label needs updates. The categories to declare (sources: existing SDKs + new IAP):

| Data type | Linked to user? | Used for tracking? | Purpose | Source |
|---|---|---|---|---|
| Purchases → Purchase History | **Yes** (new) | No | App Functionality | StoreKit + our backend ledger |
| Identifiers → User ID | Yes (existing) | No | App Functionality, Analytics | Our `accountId` |
| Identifiers → Device ID | Yes (existing) | No | App Functionality | Firebase AppCheck device attestation |
| Contact Info → Email Address | Yes (existing) | No | App Functionality | Sign-in (if added) |
| Diagnostics → Crash Data | No (anonymous in prod) | No | App Functionality | Sentry |
| Diagnostics → Performance Data | No (anonymous in prod) | No | Analytics | Sentry |
| Diagnostics → Other Diagnostic Data | Yes (DEV ONLY — disable for prod) | No | Analytics | Sentry `sendDefaultPii=true` in Dev |
| Usage Data → Product Interaction | Yes | No | Analytics | PostHog (if/when added) |
| User Content → Other User Content | Yes | No | App Functionality | Messages stored on XMTP network |

**Action items:**
- Disable Sentry `sendDefaultPii` in the Production scheme if it isn't already (existing inventory said Dev only — confirm).
- Audit Firebase Analytics / Crashlytics — if Analytics is enabled, "Usage Data" gets linked.
- The new "Purchases → Purchase History" entry is the explicit IAP disclosure Apple requires.

### 9.9 Submission checklist (App Store Review)

When ready for submission, in App Store Connect → App Store tab:

- [ ] App Privacy nutrition label updated (§9.8)
- [ ] All 4 subscription products are "Ready to Submit" (not "Missing Metadata", not "Developer Action Needed")
- [ ] Subscription Group has localized display name for every language in the submission
- [ ] Each subscription has a **Review Screenshot** showing the paywall (and ideally the subscribed state)
- [ ] **Review Notes** field includes: a sandbox tester credential + step-by-step paywall access path (e.g. "Settings → My Subscription → Upgrade"). Without this, reviewers reject.
- [ ] App build has been uploaded via Xcode/Transporter, processed, and selected for the version
- [ ] Subscription terms screen in the paywall includes: plan name, price, billing period, renewal language, cancellation instructions, Privacy Policy + Terms of Use links (per Apple's [Schedule 2](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions))
- [ ] **Restore Purchases** button is visible and functional in the paywall (Apple test this explicitly)
- [ ] If using SIWE without Sign in with Apple: **prepare 4.8 response** (see §9.10)
- [ ] Privacy Policy URL serves a real page (Apple visits it)
- [ ] All in-app subscription strings (price, period) come from `Product` SwiftUI properties, not hardcoded — Apple tests across locales

### 9.10 Known review-risk decisions

| Risk | Mitigation |
|---|---|
| **Guideline 4.8 — Sign in with Apple parity.** Apple requires that if an app uses a "third-party login service" (SIWE counts), it must also offer Sign in with Apple as an equivalent option, *unless* the app uses its own account system. PR 194 establishes the SIWE-bound `Account` model, which means SIWE is *the* account system — not a 3rd-party login. This argues SIWE is exempt from 4.8. | If review pushes back: file a clarification with App Review Board citing Apple's own guideline carve-out ("4.8(b) primary account system"). Fallback: enable Sign in with Apple capability on the App ID (already a no-op until we wire it). |
| **Guideline 3.1.5(b) — Cryptocurrency wallet operations.** SIWE signs a message but transfers no tokens, mints no NFTs, runs no on-chain transactions. We're well inside the carve-out for "wallets" that "facilitate cryptocurrency" without trading. | Review Notes should explicitly state: "SIWE is used only for authentication; no cryptocurrency is transferred, traded, mined, or held by this app." Don't mention "wallet" — say "Ethereum signature authentication". |
| **Guideline 3.1.1 — In-App Purchase only.** Our credits are consumed inside Convos. We do not provide them outside the app. We must not link to external purchase pages (no "Subscribe on our website" CTAs) from the paywall. The contact-sheet "TOP UP" button is hidden in v1, so no risk here. | n/a; just don't add web-checkout CTAs. |
| **Guideline 3.1.2 — Subscription terms.** Paywall must disclose: plan name, length, price, renewal language, cancellation, Privacy + Terms links. | Bake this into `PaywallView` from day 1; don't add it as a polish task. |
| **Guideline 5.1.1 — Data minimization.** App Privacy label must match what we actually collect. | §9.8 above. |
| **Subscription Group display name localization.** If you ship in 5 languages, you need 5 group display names + 5 sets of subscription descriptions. | Limit v1 launch to English-US to minimize this surface area; add localizations in v1.1. |

### 9.11 Ongoing operations (post-launch)

The following are ongoing operator responsibilities, not one-time setup. Document them in `RELEASE.md` or the admin app:

| Operation | Where | Frequency |
|---|---|---|
| Sandbox tester rotation | App Store Connect → Sandbox Testers | Every 6 renewal cycles per tester or when a tester gets locked |
| App Store Server Notifications v2 health check | Sentry / our `/admin/funding` dashboard | Daily — confirm we got at least one `DID_RENEW` event in the last 24h |
| Subscription product price changes | App Store Connect → Pricing | Manual, requires user consent re-prompt (`PRICE_INCREASE_CONSENT_REQUEST` notification) |
| App Store Server API key rotation | Apple Developer Portal → Keys | Annual minimum (Apple recommends every 90 days for higher security) |
| Refund handling | App Store Connect → Transactions OR `/admin/accounts/[id]/refund` | Operator on request |
| Family Sharing toggle (per product) | App Store Connect → Subscriptions | When v1.1 ships |
| Promotional Offers signing key | Generate new In-App Purchase Subscription API Key | When v1.1 ships promo offers |
| App Privacy label drift audit | App Store Connect → App Privacy | Every release that adds an SDK or new data collection |

### 9.12 Admin app

**New repo location:** `convos-backend/admin/` (sibling to `src/`, talks to Prisma directly).

Stack: Next.js 15 + React 19 + Tailwind (matches `convos-assistants/dashboard/`).

Pages:
- `/admin/accounts` — search by accountId / email / wallet → account detail
- `/admin/accounts/[id]` — balance, last 50 ledger entries, manual grant/refund, view subscription, view receipts
- `/admin/grant-kinds` — toggle `GrantKind` rows (active/inactive); v1 read-only mirror of env-var policy
- `/admin/funding` — OpenRouter org balance + recent spend + manual top-up trigger
- `/admin/reconciliation` — daily reconciliation report (discrepancies between ledger and OpenRouter)
- `/admin/audit-log` — every admin action

Auth: simple email allowlist (operator emails) + Google OAuth. Behind a Cloudflare Access policy or a dead-simple `ADMIN_EMAILS` env var.

A pricing-tuning UI (markup / credits-per-dollar interactive editor) is **v1.1** — env vars suffice for v1 per @borja's preference. See team Q E1.

---

## 10. Rollout & sequencing

Phases are sequenced by dependency, not by calendar time. Several can run in parallel where noted.

### Phase 0 — Pre-work
- [ ] Land PR 194 (auth + account). **Required before iOS SIWE flow.**
- [ ] Land PR 191 (payments foundations ledger module).
- [ ] Land `payments-repoint` (re-key ledger from `inboxId` to `accountId`).
- [ ] Add new Prisma models from [§6.1](#61-schema-additions) (Subscription, AppleReceipt).
- [ ] Seed `GrantKind` rows.
- [ ] Set up App Store Connect subscription group + 4 products in sandbox.
- [ ] Bootstrap admin Next.js app skeleton with auth-gated landing page only.

### Phase 1 — Backend foundation
- [ ] Implement `/v2/credits/me*` endpoints (read-side; thin wrapper over PR 191's `balance` method).
- [ ] Implement `/v2/credits/check` and `/v2/credits/consume` (thin wrappers over PR 191's `check` and `consume`).
- [ ] Implement `/v2/subscriptions/me/verify` + `/v2/webhooks/apple/server-notifications` with full notification-type handling.
- [ ] Implement `/v2/credits/me/redeem-trial` (idempotent).
- [ ] Tests: 1st purchase → ledger grant; renewal → new grant + idempotency; billing-retry → status change without grant; refund → negative entry + status update.

### Phase 2 — iOS scaffolding (parallel with Phase 1)
- [ ] StoreKit configuration file.
- [ ] `SubscriptionService`, `CreditsService` + repositories + GRDB migration.
- [ ] Mock services + dev menu state picker.
- [ ] `PaywallView` + `TierCard` + StoreKit 2 purchase flow (without backend verify yet — local-only).

### Phase 3 — iOS wiring
- [ ] Wire `SubscriptionService.verify` → backend.
- [ ] Wire `CreditsService.refresh` + push handlers.
- [ ] HOME credit pill.
- [ ] Settings subscription row + `SubscriptionDetailView`.
- [ ] Restore purchases.

### Phase 4 — iOS agent surfaces
- [ ] Agent contact sheet (new view, with owner/non-owner branch).
- [ ] Per-agent credit pip on avatars.
- [ ] Slow-mode footer hint in message bubbles.
- [ ] Onboarding paywall step + 7-day trial flow.

### Phase 5 — Admin (parallel)
- [ ] Account detail + grant/refund.
- [ ] Funding dashboard.
- [ ] Reconciliation report.

### Phase 6 — Hermes integration
- [ ] Replace today's PostHog-only cost emission with `POST /v2/credits/consume`.
- [ ] Wire `/v2/credits/check` into `handle_message()` before each LLM call.
- [ ] Implement per-session balance cache + `PAYMENTS_RESERVED_MAX_TURN_CREDITS` reservation.
- [ ] Slow-mode routing decision based on `mode` flag.

### Phase 7 — Hardening
- [ ] Reconciliation worker.
- [ ] OpenRouter balance monitor.
- [ ] Push notifications for credits_low / credits_depleted / sub_* events.
- [ ] Apple sandbox end-to-end test (subscribe, renew, cancel, refund, cross-grade).
- [ ] App Store Review prep (screencast, metadata, terms screen).

### Phase 8 — Submit + soft launch
- [ ] TestFlight to internal testers with Sandbox tester accounts.
- [ ] Submit for review.
- [ ] Launch with `PAYMENTS_REQUIRE_ACCOUNT=true` only after stable.

---

## 11. Risks & open questions

| Risk / question | Mitigation / status |
|---|---|
| **Top-up consumable IAP demand at launch.** Power users may want it on day 1 (the design shows the button). | Hide the button entirely in v1 (don't disable). Ship v1.1 with consumables if a meaningful % of users hit 0 credits in the first 10 days. |
| **OpenRouter org-balance exhaustion** = total app outage. | Phase 7 balance monitor + Slack alert + runbook for emergency top-up. Long-term: per-tier sub-key buckets to prevent one tier's burn taking down everyone. |
| **Apple Review flags credit grants as undisclosed.** | Match Apple's "consumable" disclosure language in App Privacy + paywall terms. Pre-clear with Apple via DTS if needed. |
| **Cross-grade proration logic** is fiddly. | Lean on Apple's `DID_CHANGE_RENEWAL_PREF` notification — they tell us when the user changes plans, we just grant the delta. Don't compute proration client-side. |
| **`appAccountToken` lost** (user uninstalls + reinstalls + signs into same Apple ID). | The new install generates a new `appAccountToken`. We bind to the latest. As long as the user authenticates with the same `accountId` (via SIWE), the binding works. Without an `accountId` we can't recover — they must sign in. |
| **Sandbox renewal acceleration** sometimes flaky. | Use StoreKit Config file for primary dev; reserve Sandbox for pre-release validation only. |
| **Migration of `UserCredits` from `inboxId` to `accountId`** in `payments-repoint` not yet on a PR. | Coordinate with backend team. **Phase 0 blocker.** |
| **macOS test compilation rule** (per CLAUDE.md). | StoreKit 2 is iOS/macOS compatible. `ProductIDs` and `PaywallView` are main-app only (iOS-only) so the constraint is only on `Credits*Service` and models in ConvosCore — those use only Foundation. |
| **Free-tier abuse** (user creates many accounts to farm trial credits). | Trial grant is per `accountId`; SIWE binding means a wallet can only generate one accountId. Multi-wallet farming is possible but bounded. Add a per-IP cap in v1.1 if abuse appears. |
| **Slow-mode quality cliff.** Gemini Flash is much weaker than Sonnet for tool-using agents. | Validate in Phase 2 with real prompts before locking in slow-mode model. Alternative: same Sonnet model but rate-limited. Configurable per `PAYMENTS_SLOW_MODE_MODEL_KEY`. |
| **CDO (Cloudflare Durable Object) enforcement architecture timing.** Nick's design eventually gates OpenRouter at infra level. If it lands in v1, iOS bypasses Hermes-side coordination; if v1.1+, we ship Hermes-based first and migrate later. Ledger model unchanged. | See team Q C1 for timing. v1 plan assumes Hermes-based enforcement; migration is purely server-side. |
| **Hermes per-session cache staleness.** If a user tops up (or renews) mid-session, the cached balance is stale until next turn. | See team Q C5. v1 fallback: re-check via `/v2/credits/check` at every turn boundary anyway. v1.1: push refresh from backend on grant events. |

---

## 12. Open product questions for the team (non-blocking)

These don't block iOS implementation start — mock services, StoreKit Configuration files, and a `?devAccountId=` backend bypass let iOS/design dogfood every state. They DO need answers before public launch.

### Group A — Owner / ownership semantics *(driven by @borja's "owner pays" model)*

| # | Question | Owner |
|---|---|---|
| A1 | When a user is in a conversation with an agent they **don't** own, what credit-related UI do they see? (a) no credit UI at all; (b) "Operated by {owner}" line, no balance; (c) owner's balance + status, no upgrade CTA. | PM + design |
| A2 | One owner has N agents — is the balance per-owner (one pool shared) or per-(owner, agent)? Frame 4 shows per-agent usage **chart**, which is attribution, not necessarily separate pools. | Borja + PM |
| A3 | If an owner pauses an agent (out of payments scope, but adjacent): does the agent's accrued credits "refund" anywhere, or just deactivate? | Borja + infra |
| A4 | Future shared/team agents (frame 3, deferred): multi-owner pool, or per-user co-funding from individual pools? | PM |

### Group B — Pricing & grants *(Saul's pricing skills go here)*

| # | Question | Owner |
|---|---|---|
| B1 | Confirm launch values: `PAYMENTS_MARKUP_RATE` (proposed 2.0), `PAYMENTS_CREDITS_PER_USD` (proposed 1000), `PAYMENTS_RESERVED_MAX_TURN_CREDITS` (proposed 100?), `PAYMENTS_MIN_BALANCE_CREDITS` (proposed 0 = run until empty, OR use as slow-mode floor?). Use Borja's `credit-pricing-calculator.html`. | Saul + Borja |
| B2 | Daily cron free-tier grant — amount + cadence + eligibility. Options: (a) every account, N credits/day forever; (b) only "active in last 7d"; (c) only "no active sub"; (d) something else. | PM + Borja |
| B3 | Subscription grant cadence — Builder $9.99 charges: (i) lump 1500 credits valid until next renewal (current PRD); (ii) prorated 50/day for 30 days; (iii) hybrid? Affects churn refund logic. | Borja + PM |
| B4 | Cross-grade Builder→Pro mid-cycle — prorate immediately, or wait until next renewal? Apple supports either; PRD defaults to "prorate immediately". | PM |
| B5 | Slow-mode cost — 0 credits (recommended for retention) or some discounted rate? | Borja + Saul |
| B6 | "Earn on usage" credit source mentioned by @borja — referral, engagement reward, both, neither? When does it ship? | PM |
| B7 | Should the contact-sheet chart show usage by model (Sonnet vs Flash vs Opus) in addition to by-day? Currently §7 shows daily-only. | Design + PM |

### Group C — Architecture / enforcement *(Nick + Borja's threads)*

| # | Question | Owner |
|---|---|---|
| C1 | Is the Cloudflare Durable Object architecture (Nick) part of v1, or v1.1+? If v1, iOS skips Hermes-side coordination; if v1.1, we ship Hermes-based enforcement first and migrate the enforcement point later. Ledger model stays either way. | Nick + Borja |
| C2 | When `payments-repoint` lands (`UserCredits.inboxId → accountId`), are existing ledger rows migrated, mapped via a lookup table, or wiped (sandbox-only)? | Borja |
| C3 | `cost_status: "unknown"` policy — fail closed (no bill, log) or estimate by model class? Currently we force known-pricing models; confirm we hold that line. | Borja + infra |
| C4 | Pricing calculator (`credit-pricing-calculator.html`) — make it part of the admin app, or live as a separate ops-only tool? | Saul + ops |
| C5 | Hermes session-level balance cache staleness — if user tops up mid-session, does Hermes need a push refresh, polling, or "next turn" recheck only? | Borja + Nick |

### Group D — Apple / IAP-specific

| # | Question | Owner |
|---|---|---|
| D1 | Parallel Dev App Store Connect record (§9.5.1) — yes or no? Trade-off: 2× IAP maintenance vs realistic TestFlight sandbox testing. | iOS + ops |
| D2 | Sign in with Apple parity (Guideline 4.8) — pre-implement as risk mitigation, or wait for App Review pushback? See §9.10. | iOS + PM |
| D3 | Family Sharing — confirm OFF for v1 across all 4 SKUs (PRD assumption). | PM |
| D4 | Annual discount % — Cursor (~20%), Claude Pro (none), or PRD's ~33% baseline? | Saul + PM |
| D5 | Per-region pricing — let Apple auto-convert from USD, or pin local prices for EU/UK/JP? Auto-convert is simpler. | Saul + PM |

### Group E — Admin tooling & ops

| # | Question | Owner |
|---|---|---|
| E1 | Tuning UI for `PAYMENTS_MARKUP_RATE` / `PAYMENTS_CREDITS_PER_USD` — env-var only for v1 (Borja agrees), then build UI in v1.1 once we have >100 active subs? | ops + Borja |
| E2 | Admin app scope — narrow (manual grant/refund + account lookup + ledger view) or broad (Apple refunds, policy editor)? | ops |
| E3 | Reconciliation report cadence — daily or weekly? | ops |

---

## 13. Out of scope (so we don't drift)

- Web/Stripe checkout
- Family Sharing
- Promo codes / offer codes
- Refund automation (operator does it manually)
- Group credit pooling
- Per-agent budget overrides (agent owner allocates from own pool)
- Multi-account / account merging
- B2B / team plans
- Third-party agent marketplaces with revenue share

---

## Appendix A — File-by-file diff summary

### iOS — new files
```
Convos/Subscription/CreditsBadgeView.swift
Convos/Subscription/AgentCreditPipView.swift
Convos/Subscription/PaywallView.swift
Convos/Subscription/PaywallViewModel.swift
Convos/Subscription/TierCard.swift
Convos/Subscription/ProductIDs.swift
Convos/Conversation Detail/AgentContactSheet/AgentContactSheetView.swift
Convos/Conversation Detail/AgentContactSheet/AgentContactSheetViewModel.swift
Convos/App Settings/Subscription/SubscriptionDetailView.swift
Convos/Resources/Convos.storekit
ConvosCore/Sources/ConvosCore/Services/Credits/CreditsService.swift
ConvosCore/Sources/ConvosCore/Services/Subscription/SubscriptionService.swift
ConvosCore/Sources/ConvosCore/Storage/Repositories/CreditsRepository.swift
ConvosCore/Sources/ConvosCore/Storage/Repositories/SubscriptionRepository.swift
ConvosCore/Sources/ConvosCore/Storage/Models/CreditBalance.swift
ConvosCore/Sources/ConvosCore/Storage/Models/Subscription.swift
ConvosCore/Sources/ConvosCore/Database/Migrations/v{N}_credits.swift
ConvosCore/Tests/ConvosCoreTests/Credits/CreditsServiceTests.swift
ConvosCore/Tests/ConvosCoreTests/Credits/SubscriptionServiceTests.swift
ConvosCore/Tests/ConvosCoreTests/Mocks/MockCreditsService.swift
ConvosCore/Tests/ConvosCoreTests/Mocks/MockSubscriptionService.swift
```

### iOS — modified files
```
Convos/Conversations List/ConversationsView.swift          (add credits pill in navbar)
Convos/Conversation Detail/ConversationMemberView.swift   (add agent pip)
Convos/Conversation Detail/Messages/MessagesListView/MessagesGroupView.swift (slow-mode footer)
Convos/App Settings/AppSettingsView.swift                  (add subscription section)
Convos/Conversation Detail/Conversation Detail Drawer/ConversationOnboardingView.swift (paywall step)
ConvosCore/Sources/ConvosCore/Notifications/PushNotificationPayload.swift (new push types)
ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift   (new endpoints)
```

### Backend — new files (convos-backend)
```
prisma/migrations/<ts>_payments_repoint_to_account/migration.sql   (PR: payments-repoint)
prisma/migrations/<ts>_subscriptions_and_receipts/migration.sql
src/services/subscriptions/apple-server-api.ts
src/services/subscriptions/jws-verifier.ts
src/routes/v2/credits.ts             (HTTP wrappers for PR 191's grant/consume/balance/check)
src/routes/v2/subscriptions.ts
src/routes/v2/products.ts
src/routes/webhooks/apple.ts
src/routes/admin/accounts.ts
src/routes/admin/grant-kinds.ts
src/routes/admin/funding.ts
src/middleware/admin-auth.ts
tests/credits/*
tests/subscriptions/*
admin/*  (new Next.js app)
```

### Backend — modified files
```
src/middleware/auth.ts             (no change — already has requireAccount from PR 194)
prisma/schema.prisma               (add Subscription, AppleReceipt; UserCredits/CreditLedger come from PR 191)
src/index.ts                       (mount /v2/credits, /v2/subscriptions, /v2/webhooks/apple, /admin)
.env.example                       (APPLE_*, ADMIN_EMAILS, PAYMENTS_REQUIRE_ACCOUNT, plus the PAYMENTS_GRANT_* and PAYMENTS_TRIAL_* vars defined here)
```

### convos-assistants — modified files
```
runtime/openclaw/src/convos/src/handle_message.ts/.py     (POST /v2/credits/check before LLM call; cache session balance)
runtime/openclaw/src/convos/src/openrouter.ts             (read mode/routeModel from /check, route accordingly)
runtime/openclaw/src/convos/src/openrouter-capture.ts     (POST /v2/credits/consume after each LLM call, idempotent on requestId)
workers/credits-sweep/src/index.ts                        (cross-reference ledger vs OpenRouter, emit reconciliation events)
workers/openrouter-balance-monitor/src/index.ts           (new — daily balance check + Slack alert)
```

---

## Appendix B — Concrete launch numbers (recap)

Single source-of-truth table for the launch defaults. Editable via env vars (no DB row in v1).

```bash
# convos-backend env vars — launch defaults
PAYMENTS_CREDITS_PER_USD=1000             # 1 credit = $0.001 nominal
PAYMENTS_MARKUP_RATE=2.0                  # 1 USD raw cost → 3 USD-equivalent credits deducted
PAYMENTS_RESERVED_MAX_TURN_CREDITS=100    # reserved per-turn to avoid mid-turn underflow
PAYMENTS_MIN_BALANCE_CREDITS=0            # 0 = run until empty + slow-mode; >0 = slow-mode floor

PAYMENTS_GRANT_BUILDER_MONTHLY=1500       # credits granted per Builder renewal
PAYMENTS_GRANT_PRO_MONTHLY=5000           # credits granted per Pro renewal
PAYMENTS_GRANT_TRIAL=500                  # credits granted on NUX trial
PAYMENTS_TRIAL_EXPIRY_DAYS=7              # trial credits expire after this many days

PAYMENTS_SLOW_MODE_MODEL_KEY=google/gemini-2.5-flash

# Apple integration
APPLE_BUNDLE_ID=org.convos.ios
APPLE_BUNDLE_ID_DEV=org.convos.ios-preview
APPLE_KEY_ID=<10 chars>
APPLE_ISSUER_ID=<uuid>
APPLE_PRIVATE_KEY=<.p8 contents>
APPLE_ENV=production                      # or `sandbox` for non-prod backends

# Backend gating
PAYMENTS_REQUIRE_ACCOUNT=false            # flip to true after iOS SIWE flow ships
ADMIN_EMAILS=ops@convos.org,founder@convos.org
```

```yaml
# Margins implied (yr1, worst-case worldwide blend, 30% Apple, EU VAT)
# Builder net: $6.00 / mo
#   Full grant burn @ 3× markup → $0.50 raw OpenRouter spend → 91% gross margin
#   Slow-mode bonus: ~$0.30 estimated → 86% gross margin floor
# Pro net: $18.00 / mo
#   Full grant burn @ 3× markup → $1.67 raw OpenRouter spend → 91% gross margin
#   Slow-mode bonus: ~$0.50 estimated → 88% gross margin floor

# These remain margin-positive at:
#   PAYMENTS_CREDITS_PER_USD=1000, PAYMENTS_MARKUP_RATE≥1.5,
#   PAYMENTS_GRANT_BUILDER_MONTHLY≤2000, PAYMENTS_GRANT_PRO_MONTHLY≤7000

# Margin-killer combinations to avoid:
#   PAYMENTS_MARKUP_RATE<1.0 (we eat raw cost — only OK for paid promo periods)
#   PAYMENTS_GRANT_BUILDER_MONTHLY>3000 at markup=2 (Builder net contribution < $4)
```
