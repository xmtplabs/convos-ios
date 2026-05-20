# In-App Purchases & Credits

**Status:** PRD draft — revised 2026-05-14 per team feedback (see Revision history). Pending eng/design re-review.
**Owner:** TBD.
**Date:** 2026-05-12 (initial draft), 2026-05-14 (Shane-direction revision).
**Single-file scope:** Both the iOS (Convos) and backend (convos-backend, convos-assistants) plans live here so the economic model, schema, and UI stay in one place.

---

## Revision history

A round of team feedback (Slack thread in #convos-proj-credits) on the initial draft and the first paywall implementation reset several product-direction calls. Specifically:

- **"Credits" is meaningless** to users on its own — Suno's "600 songs" is concrete and aspirational; opaque token counts aren't. Our tasks are variable so we can't promise exact counts, but plan copy and surfaces need to lean toward outcomes.
- **Kill the model-tier distinction.** "Standard model on every reply" vs "Standard + premium model access" is the wrong product axis. Better models → better experience → more credits used → more retention. Any plan can use any model.
- **Slow-mode is an internal behavior, not a user-facing feature.** No bullets, no footers, no copy explaining it. Hide complexity; do the work behind the scenes.
- **Outcome over inputs.** Apple's "1,000 songs in your pocket" precedent. Benchmark plans by enticing operations ("plan 5 vacations", "book 20 concerts") not by token counts.
- **Builder incentives are the most important early lever.** Don't repeat the Meetup mistake of charging the people who drive growth. Subsidize builders heavily — give them more credits for publishing agents, inviting users, and getting their agents used.
- **Per-agent/role pricing is a future possibility** (Kai body tutor at $399/mo precedent; "agents as contacts" makes this structurally available). Not v1.
- **Tagline candidate:** "Unlimited agents. Pay for usage."

What this changes in the PRD:

| Area | Status |
| ---- | ------ |
| Section 3 decisions table | Updated — model-tier framing struck; slow-mode reclassified as internal |
| Section 5.6 Release valve | Updated — slow-mode is internal-only; no user-facing copy mentions it |
| New §5.9 Framing principle | Added — outcomes-over-tokens thesis as the load-bearing copy/UX rule |
| Frame 5 Contact out-of-credits | Updated — matches what shipped (no "slower model" copy) |
| Frame 6 Settings | Updated — matches what shipped |
| Frame 7 Paywall | Updated — no model-tier bullets, "agents" not "assistants", outcome-anchored bullets |
| Section 12 open questions | Added Group F — builder incentives |

What this does **not** change:

- Builder + Pro × Monthly + Annual = 4 SKUs in one subscription group (the plan **structure** is still right; it's the **value props** that shifted).
- Virtual-currency abstraction (`CreditLedger`, env-var-tunable rates, OpenRouter cost capture).
- Backend schema, Apple flow, App Store Server Notifications wiring.
- Phased rollout (Phases 0–8).

The economic model, ledger schema, and StoreKit wiring are all still load-bearing. The shift is in **how we talk to users** and **who we incentivize**.

### Round 2 — as-shipped reality (2026-05-19)

A second round of design mediation with @borja during backend PR #215 produced four load-bearing flips. The PRD body below has been edited in place to match; this entry captures the deltas for traceability.

1. **Slow-mode is gone, not "internal-only".** Backend `consume()` hard-fails at 0 (`InsufficientBalanceError`). There is no fallback model, no `slow_mode` mode flag, no `PAYMENTS_SLOW_MODE_MODEL_KEY`. iOS shows the out-of-credits paywall when the balance is 0. §5.6 and §6.5 rewritten accordingly.

2. **Subscription credits are derived, not granted.** `monthlyGrant` lives in per-tier env config (`PAYMENTS_GRANT_BUILDER_MONTHLY`, `PAYMENTS_GRANT_PRO_MONTHLY`). `monthlyGrantUsed` = Σ |consume deltas| since `Subscription.currentPeriodStart`. The `grant()` primitive is **never** called on verify or renewal. The ledger stays canonical for additive credits only (NUX trial, top-ups, manual, promo, daily refills) — Hermes reads `UserCredits.balance`, iOS reads the derived view, and the two converge at 0 because there's no slow-mode floor. §5.5 / §6.0 rewritten.

3. **Cross-device transfer inverted to strict ownership.** First `/verify` binds `originalTransactionId → accountId`. Subsequent verifies from a different account → `409 subscription_account_mismatch`. The original buyer owns the sub for life; transfer is a support op. The `appAccountToken` is extracted from the verified JWS, not trusted from the request body — drops a session-stealing vector. §6.4 rewritten.

4. **User routes live under `/v2/accounts/me/*`, not `/v2/subscriptions/*` or `/v2/credits/me/*`.** Per @borja's audience-namespace cut: credits and subscriptions are **properties** of an account, not top-level resources. Agent-facing `/v2/credits/{check,consume,grant}` stay where they are. §6.2 rewritten.

Plus smaller deltas absorbed inline: `payments-repoint` landed inside PR #191 (no longer a prereq); `willRenew` + `isInTrial` columns added to `Subscription`; `idempotencyKey` + `notificationUUID` columns added to `AppleReceipt`; pricing prose corrected (`markupRate=2.0` is a 2× multiplier, not "+$2 markup"); real launch prices folded into §5 and §9.5.3.

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
| Products | **Builder + Pro × Monthly + Annual** = 4 SKUs in one subscription group. | Matches the design. Annual is the upsell paywall lever. Single group → Apple handles up/down/cross-grade proration. Both tiers can use any model — see §5.9. |
| Plan differentiation | **Credit allotment + outcome benchmarks only — no model gating.** | (Revised — see Revision history.) "Standard model on every reply" vs "Premium model access" is the wrong axis. Better models → better experience → more retention. Pro tier still gets more credits, annual still discounts; we just don't restrict which model a user can route to. |
| Release valve | **None.** Out of credits → consume hard-fails → iOS paywall. | (Revised in Round 2 — see Revision history.) No slow-mode, no fallback model. The agent stops responding; iOS recovers via paywall. Top-up SKUs deferred. See §5.6. |
| Free tier | **NUX trial: server-issued additive grant; deferred from PR #215.** | Will flow through `grant({ kind: "trial_nux" })` when it lands — additive credits, not subscription-derived. iOS-side 7-day trial UX is separate from Apple's Introductory Offer mechanism (§9.5.4). |
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

Real launch prices (set in App Store Connect — see §9.5.3). Worst-case worldwide blend (1st year, 30% Apple, EU/UK VAT pre-deducted by Apple):

| SKU | Gross USD | Apple cut (30% / 15% SBP) | EU VAT impact* | **Net to Convos** |
|---|---|---|---|---|
| Builder Monthly $19.99 | $19.99 | $6.00 / $3.00 | ~$3.00 | **~$11 (yr1) / ~$14 (yr2 SBP)** |
| Pro Monthly $199.99 | $199.99 | $60.00 / $30.00 | ~$30.00 | **~$110 (yr1) / ~$140 (yr2 SBP)** |
| Builder Annual $214.89 | $214.89 | $64.47 / $32.23 | ~$32 | **~$118 (yr1) / ~$150 (yr2 SBP)** |
| Pro Annual $1919.90 | $1919.90 | $575.97 / $287.99 | ~$288 | **~$1,056 (yr1) / ~$1,344 (yr2 SBP)** |

*VAT is Apple's burden, not ours — they collect from the user and remit. The "VAT impact" column is the effective price drop our net sees after Apple netted EU/UK customer revenue. Apple's [pricing tiers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/configure-prices) show ~30% lower take for EU SKUs. Apple Small Business Program (SBP): 15% if you earned <$1M from App Store last year — auto-applies after enrollment.

**Annual discounts** (off the 12× monthly anchor):
- Builder Annual: $214.89 vs 12 × $19.99 = $239.88 → **~10.4% off** (about 11 months for the price of 12)
- Pro Annual: $1919.90 vs 12 × $199.99 = $2399.88 → **20.0% off** (about 9.6 months for the price of 12)

**Planning assumption (yr1 worst-case net):** ~$11 Builder Monthly, ~$110 Pro Monthly, ~$118 Builder Annual, ~$1,056 Pro Annual. The Pro tier is a heavyweight enterprise/builder price point — see §5.4 for the margin implications.

### 5.2 Virtual currency — the abstraction

We follow the **RevenueCat Virtual Currency pattern**: credits are opaque, non-transferable, account-bound units. A user sees "1,500 credits / month". They don't see USD or tokens.

Internally, two levers turn credits into real economics, both stored **per ledger row** (in PR 191's `CreditLedger` schema):

1. **`creditsPerDollar: BigInt`** — the credit↔USD exchange rate at the time of the grant or burn. Stored on each ledger entry. Changing the env var tomorrow does not rewrite yesterday's entries.
2. **`markupRate: Decimal(8,4)`** — multiplicative markup over raw model cost. Stored per ledger entry on a burn. **`markupRate = 2.0` means a 2× multiplier**: $1 of OpenRouter spend deducts the credit-equivalent of $2 (1× cost + 1× margin = 50% gross margin in profit-margin terms). This matches the formula `credits_to_deduct = estimated_cost_usd × markup_rate × credits_per_dollar` (§6.0). It is **not** "+$2 added markup" — increase the value if you want a wider cushion.

**Per-model rate card is NOT used** in v1. We deduct against OpenRouter's reported `estimated_cost_usd` directly, applied uniformly via env-var markup. This avoids the maintenance burden of a per-model rate table and matches PR 191's implementation. If we later need per-model differentiation (e.g. premium-model upcharge), we can introduce a multiplier table without changing ledger row shape.

### 5.3 Launch config (env-var driven)

PR #191's payment-side knobs are joined by per-tier grant amounts owned by the subscriptions side. Final values are an ops/product decision; the table below shows what's wired in the codebase today.

| Env var | Launch value | Owner | Purpose |
|---|---|---|---|
| `PAYMENTS_MARKUP_RATE` | **2.0** (2× multiplier — 50% gross margin) | PR 191 | Multiplicative markup over OpenRouter raw cost — see §5.2 |
| `PAYMENTS_CREDITS_PER_USD` | **1000** (1 credit = $0.001 nominal) | PR 191 | Headline-friendly unit (2,500 credits ≈ "$2.50 of AI") |
| `PAYMENTS_RESERVED_MAX_TURN_CREDITS` | **1** | PR 191 | Minimum balance to start a turn (Hermes `/check` gate) |
| `PAYMENTS_MIN_BALANCE_CREDITS` | **0** | PR 191 | Hard floor; `consume()` throws `InsufficientBalanceError` below this. There is no slow-mode below 0. |
| `PAYMENTS_GRANT_BUILDER_MONTHLY` | **2500** (placeholder — final TBD by product) | PR 215 | Per-tier credit allotment for `monthlyGrant` in iOS `CreditBalance`. Annual = 12× this. |
| `PAYMENTS_GRANT_PRO_MONTHLY` | **10000** (placeholder — final TBD by product) | PR 215 | Same, Pro tier. |

**Sanity check at the placeholder numbers.** A Builder user has 2,500 credits/period = $2.50 of OpenRouter spend at `markupRate=2.0` and `creditsPerDollar=1000` (2500 credits ÷ 2.0 ÷ 1000). At Claude Sonnet 4.6 pricing, that's roughly 60–120 typical agent turns/month. The Pro tier (10,000 credits = $10 of spend at the same rates) covers ~250–500 turns. Both numbers are placeholders and product will retune before launch.

**Note on grant amount provenance.** Subscription credit allotments are **derived** from `PAYMENTS_GRANT_<TIER>_MONTHLY` at read time — they are NOT written to the credit ledger via `grant()`. See §5.5 for the policy and §6.0 for the implementation contract.

### 5.4 Margin model — why this works

At the placeholder grants (2,500 Builder / 10,000 Pro) and `markupRate=2.0`:

```
Builder Monthly:
  Net revenue (yr1, worst case):           $11.00
  Raw OpenRouter spend at full grant burn: $2.50
  Net contribution:                        $8.50 (~77% gross margin)

Pro Monthly:
  Net revenue (yr1, worst case):           $110.00
  Raw OpenRouter spend at full grant burn: $10.00
  Net contribution:                        $100.00 (~91% gross margin)
```

A user who NEVER burns their credits = full net revenue as contribution. A full-burn user keeps a comfortable margin because the markup is built into the credit→USD conversion, not bolted on after the fact. There is no slow-mode subsidy to model — `consume()` hard-fails at 0, so worst-case spend per period is capped at `(monthlyGrant ÷ markupRate ÷ creditsPerDollar)` USD by construction.

This is fundamentally **freemium economics**, not AI-cost-pass-through. It is the right model for a messaging app where most users send a handful of agent messages a week. Pro is a heavyweight tier intended for builders and power users; the credits ratio is the lever we use to retune margin once we have real usage data.

### 5.5 Grant policy — kinds and cadence

**Subscription credits are derived, not granted.** This is the load-bearing call from the as-shipped revision (see Revision history round 2). The `grant()` primitive in `src/payments/` is reserved for **additive credits**: one-off injections that stick around (top-ups, NUX trial, manual ops, promo, daily refills). Subscription monthly allotments DO NOT flow through `grant()`. They are computed at read time from the active `Subscription` row + per-tier env config.

**Why**: writing a `grant()` ledger entry on every subscription renewal AND a matching `adjust(-leftover)` to enforce "use it or lose it" creates two ledger writes per renewal plus a race-condition surface. Reading derived state from a single Subscription row + a ledger sum since `currentPeriodStart` is simpler, has a single source of truth, and converges naturally at 0 since there is no slow-mode floor (§5.6).

The `GrantKind` rows shipped in PR #191's migration:

| GrantKind id | Source | When | Amount | Notes |
|---|---|---|---|---|
| `signup_bonus` | Server-issued | Once per account on first agent creation | TBD (deferred — not yet wired) | One-time additive grant. Lives in the ledger; rolls over. |
| `daily_refill` | Cron job | Daily, to eligible accounts | TBD — see team Q B2 | Future cron-driven additive top-up. Idempotency key shape `account:<accountId>:date:YYYY-MM-DD`. |
| `manual` | Admin action | Operator-initiated | Per-grant | Refunds, comps, promo escalations. |

**Not in v1**: `subscription_*`, `trial_nux_*` (NUX trial is deferred per the brief). When the NUX trial ships in a follow-up, it will use a new `GrantKind` row like `trial_nux` or `signup_trial` and flow through `grant()` — additive, not subscription-derived.

**iOS-visible behavior** (no functional change vs the earlier draft): `monthlyGrant` = tier env config, `monthlyGrantUsed` = Σ |consume deltas| since `Subscription.currentPeriodStart`. Period rollover happens at `DID_RENEW` because the webhook updates `currentPeriodStart`, naturally resetting `monthlyGrantUsed` to 0 on the next read. No ledger write needed.

### 5.6 Out-of-credits policy

Balance hits 0 → `consume()` throws `InsufficientBalanceError`. There is **no slow-mode**, **no fallback model**, **no zero-cost burn path**. The agent simply does not respond to the next turn. iOS is the only surface that recovers — by showing the paywall.

This is a deliberate simplification from earlier drafts of the PRD. Slow-mode added complexity (per-call routing decisions, $0 ledger entries for observability, eligibility gates, the operational risk of running an unmetered fallback model) for a benefit (lower churn at the 0-balance moment) that was speculative. We removed it during the as-shipped round; if real usage data shows a retention cliff at 0, we can revisit with a concrete proposal.

**Two UI affordances handle the upsell:**

1. **In-conversation low-balance banner** (account-level, since credits are account-level — not per-agent): when balance is low or 0, a banner pinned above the messages list reads *"⚠ 180 credits left"* or *"⛔ You're out of credits"*, with a single Upgrade CTA.
2. **Contact sheet out-of-credits section** (agent contact only): when `balance == 0`, an "Out of credits — your agents are paused until you upgrade or top up" section appears at the top of the agent detail, with an Upgrade CTA. (The "Top up" button is **hidden in v1** — gating consumable IAP to v1.1.)

Both surfaces talk about the **balance**, not any operational mode. There is no operational mode to talk about.

#### 5.6.1 Owner-pays semantics

Per @borja's design thread: **each owner has N agents, and the owner pays for all messages in the conversation**, regardless of who sends them. The owner's `accountId` (post-`payments-repoint`) is the ledger key for every burn on agents they own.

UI implications:

| Surface | Owner's view | Non-owner's view |
|---|---|---|
| Frame 1 (HOME credits pill) | shown — their balance | shown — their balance, unaffected by other people's agents |
| Frame 2 (convo low-balance banner) | shown — account-level banner above the messages list | shown only if the non-owner's own balance is low (banner reads their own state) |
| Frame 4 (contact sheet, healthy) | full chart + balance + "Manage" CTA | agent info + small "Operated by {owner}" line, no balance, no upgrade CTA |
| Frame 5 (contact sheet, out of credits) | full chart + "Out of credits" + **Upgrade** CTA | "This agent's owner is out of credits." No upgrade CTA (we can't sell a sub on someone else's behalf). |

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

### 5.9 Framing principle — outcomes over tokens

This section captures the load-bearing copy/UX rule for every user-facing credits surface. It's downstream of the team feedback in the Revision history.

**The thesis.** Apple sold the iPod as *"1,000 songs in your pocket"*, not as *"5 GB of storage"*. The category shifted before competitors noticed. Convos's plans should anchor on **outcomes** ("Plan ~5 trips", "Run a daily agent for a month", "Power a team of agents") rather than **inputs** ("X credits", "Y tokens", "Z messages"). Token counts mean nothing to most users; outcomes are concrete and aspirational.

**The friction.** Our tasks are unboundedly variable. We cannot honestly promise "X songs" — a sophisticated user will route an expensive model at a long-context task and burn credits 50× faster than a casual user planning a weekend trip. The fix is **benchmarked guidance**, not exact counts:

- Plan bullets describe *what a typical user can plausibly do* with the allotment, not a guarantee.
- Numbers are soft ("~5 trips", not "5 trips") to set expectations.
- We supplement with a runway estimate on the contact sheet (*"Based on your average prompt, you'll run out in X prompts"* — Borja's `/payments/stats`-style endpoint) once it lands, so users with atypical usage see a real signal, not a marketing one.

**Rules of thumb for every credits surface.**

1. **Never expose tokens.** Tokens are an implementation detail. If a future surface needs a granular count, it's "credits", not "tokens".
2. **No slow-mode language exists, period.** There's no fallback model to euphemize. When balance is 0, the agent doesn't respond and iOS shows the paywall — that's the entire mechanism. See §5.6.
3. **Outcome examples beat raw counts on the paywall and NUX.** Outcome examples should never appear in operational/account UI (Settings → Subscription, runway estimate). Those need real numbers; outcomes belong in marketing/onboarding surfaces.
4. **Don't train users to avoid expensive operations.** The per-agent usage breakdown is a transparency feature, not a budgeting feature. We want users pushing the edges (so we learn to make those operations cheaper); we do NOT want them learning to avoid browsing because today it costs more.
5. **Spacing & visual rhythm.** The paywall ships at 24pt between sections and 12pt between cards; bullets render in one flat VStack with 8pt spacing. The Subscribe button keeps a stable height across idle/in-flight states (Text label always present, spinner in `.overlay`). These are not arbitrary — they're the difference between a paywall that reads cleanly and one that feels noisy.

**The longer-horizon shift (out of v1 scope, captured here for traceability).** A team thread floated **per-agent / per-role pricing** as the eventual end state — anchored on the observation that a $399/mo body-tutor app is a viable business when the customer perceives the agent as labor producing outcomes, not as a tool consuming tokens. "Agents as contacts" makes this structurally available: each role could carry its own price tag. v1 keeps the simple Builder / Pro tier model; per-role pricing is something to revisit once we have real outcome data.

---

## 6. Backend plan

### 6.0 Reference: PR #191 payments module (merged)

PR #191 ("Payments API foundations") is merged into `otr-dev`. The module lives at `convos-backend/src/payments/` (no nested `services/` dir). It is **HTTP-bound for agents only** today (`POST /v2/credits/{check,consume,grant}` with `X-Agent-API-Key`); user-facing reads/writes live under `/v2/accounts/me/*` per §6.2. The `payments-repoint` work (re-keying `UserCredits`/`CreditLedger` from `inboxId` to `accountId`) landed inside PR #191 itself — no longer a separate prereq.

**Service-layer methods** (`src/payments/index.ts`, accountId-keyed):
- `grant({ accountId, credits, kind, idempotencyKey, note?, requestId? })` → ledger entry + new balance
- `consume({ accountId, usdCostMicros, idempotencyKey, requestId, model? })` → ledger entry + new balance. **Throws `InsufficientBalanceError`** if balance would drop below `PAYMENTS_MIN_BALANCE_CREDITS`. No `mode` return value — there is no slow-mode (§5.6).
- `adjust({ accountId, delta, idempotencyKey, note })` → signed adjustment (operator refunds / corrections)
- `getBalance(accountId)` → current `UserCredits.balance` as `bigint`
- `isAllowed(accountId)` → advisory boolean (`balance >= PAYMENTS_RESERVED_MAX_TURN_CREDITS`); not an authorization gate
- `getHistory(accountId, limit?, cursor?)` → keyset-paginated ledger entries

**Env vars** owned by PR #191 — see §5.3 for values:
- `PAYMENTS_MARKUP_RATE`, `PAYMENTS_CREDITS_PER_USD`, `PAYMENTS_RESERVED_MAX_TURN_CREDITS`, `PAYMENTS_MIN_BALANCE_CREDITS`

**Pricing formula** (verbatim from `src/payments/credits/pricing.ts`):
```
credits_to_deduct = ceil(usd_cost_micros × markup_rate × credits_per_dollar / scale)
```
where `scale = 10000 × 1_000_000` (markup is stored in basis points, USD cost in micros). `markup_rate = 2.0` is a 2× multiplier — see §5.2.

**Cost source**: Hermes returns `estimatedCostUsd` from OpenRouter's response. For v1, we restrict to known-pricing models so `unknown` doesn't appear. Policy for `unknown` — see team Q C3.

**Subscription credits do not touch this module.** They're derived at read time from the `Subscription` row + per-tier env config — see §5.5 and §6.2's `GET /v2/accounts/me/credits`. `grant()` is reserved for additive credits (NUX trial, top-ups, manual ops, promo, daily refills).

### 6.1 Schema additions

Built on PR #191's payments tables (`UserCredits`, `CreditLedger`, `GrantKind`) which were re-keyed to `accountId` inside PR #191 itself. Subscription/AppleReceipt tables shipped in PR #215 (`20260515093120_add_subscriptions_and_apple_receipts`).

**As-shipped Subscription + AppleReceipt models** (lowercase enum values match Prisma's `@@unique` / iOS Codable raw-value convention):

```prisma
model Subscription {
  id                    String             @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  accountId             String             @db.Uuid
  productId             String             // e.g. "app.convos.subs.builder.monthly"
  tier                  SubscriptionTier   // builder | pro
  period                SubscriptionPeriod // monthly | annual
  status                SubscriptionStatus // trial | active | grace | billingRetry | expired | revoked
  originalTransactionId String             @unique   // Apple's stable per-sub identifier
  appAccountToken       String             @unique @db.Uuid  // extracted from the verified JWS, bound on first /verify
  startedAt             DateTime
  currentPeriodStart    DateTime
  currentPeriodEnd      DateTime
  willRenew             Boolean            @default(true)   // mirrors Apple autoRenewStatus; updated by DID_CHANGE_RENEWAL_STATUS
  isInTrial             Boolean            @default(false)  // derived from JWS offerType=INTRODUCTORY_OFFER
  cancelledAt           DateTime?
  gracePeriodEnd        DateTime?
  environment           AppleEnv           // sandbox | production
  createdAt             DateTime           @default(now())
  updatedAt             DateTime           @updatedAt

  account  Account        @relation(fields: [accountId], references: [id], onDelete: Restrict, onUpdate: Cascade)
  receipts AppleReceipt[]

  @@index([accountId])
  @@index([status, currentPeriodEnd])
}

model AppleReceipt {
  id                  String   @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  subscriptionId      String   @db.Uuid
  idempotencyKey      String   @unique   // (transactionId, notificationType[:subtype]) tuple flattened — see §6.3
  notificationUUID    String?  @unique   // Apple's notificationUUID when present; null for /verify-originated receipts
  transactionId       String              // per-transaction ID; NOT unique (a refund + a renewal may share an originalTransactionId)
  notificationType    String              // SUBSCRIBED, DID_RENEW, DID_FAIL_TO_RENEW, REVOKE, REFUND, ... or "VERIFY"
  notificationSubtype String?
  signedPayload       String   @db.Text   // raw JWS from Apple for audit
  receivedAt          DateTime @default(now())

  subscription Subscription @relation(fields: [subscriptionId], references: [id], onDelete: Restrict, onUpdate: Cascade)

  @@index([transactionId])
  @@index([subscriptionId, receivedAt])
}

enum SubscriptionTier   { builder pro }
enum SubscriptionPeriod { monthly annual }
enum SubscriptionStatus { trial active grace billingRetry expired revoked }
enum AppleEnv           { sandbox production }
```

**Notable absences** (vs an earlier draft of this PRD):

- **No `ModelRateCard` table.** PR #191 deducts against OpenRouter's reported `estimated_cost_usd` uniformly. Per-model differentiation can return in v2 as a simple env-var multiplier without schema changes.
- **No `PolicyConfig` row.** Per Borja, env vars are the v1 config surface. The admin UI for tuning is a v1.1 concern.
- **No `subscription_*` GrantKind rows.** Subscription credits are derived (§5.5); they never write to the ledger.

**`GrantKind` seeds** (from PR #191's migration, unchanged by PR #215):

```sql
INSERT INTO "GrantKind" ("id", "name", ...) VALUES
  ('signup_bonus', 'Signup bonus',  ...),
  ('daily_refill', 'Daily refill',  ...),
  ('manual',       'Manual grant',  ...);
```

NUX trial, promo, and any subscription-related grant kinds are deferred. They'll be added as additional rows when the corresponding flows ship — no schema migration needed beyond an `INSERT ... ON CONFLICT DO NOTHING`.

### 6.2 HTTP API surface

Routing follows the **audience-namespace cut** agreed during PR #215: user-facing reads/writes live under `/v2/accounts/me/*` (credits and subscriptions are properties of an account); agent-facing endpoints stay under `/v2/credits/*` with `X-Agent-API-Key`. The webhook is Apple-bound and lives under `/v2/webhooks/apple/*`. The same handler is mounted at both `/ssn` (iOS brief naming) and `/server-notifications` (PRD / App Store Connect naming) for compatibility.

**User-facing** (JWT + `requireAccount`):

| Method | Path | Body | Returns | Notes |
|---|---|---|---|---|
| `GET` | `/v2/accounts/me/credits` | – | `{ balance, monthlyGrant, monthlyGrantUsed, nextRefreshAt, periodLabel }` | Feeds iOS `CreditBalance`. **Derived** at read time from Subscription row + per-tier env config + Σ consume deltas since `currentPeriodStart`. With no subscription: all credit fields = 0, `nextRefreshAt` = start of next calendar month. |
| `GET` | `/v2/accounts/me/subscription` | – | `{ tier, period, status, productId, currentPeriodEnd, willRenew, isInTrial }` or `204 No Content` | Feeds iOS `UserSubscription`. 204 when caller has no sub. |
| `POST` | `/v2/accounts/me/subscription/verify` | `{ jwsRepresentation: string }` | `{ subscription }` | iOS posts the StoreKit JWS only. `appAccountToken` is extracted from the verified payload, not trusted from the body (§6.4). Idempotent on `transactionId`. Returns `409 subscription_account_mismatch` if a different account already owns this `originalTransactionId`. |

**Agent-facing** (PR #191, `X-Agent-API-Key`):

| Method | Path | Body | Returns | Notes |
|---|---|---|---|---|
| `POST` | `/v2/credits/check` | `{ accountId }` | `{ allowed, balance }` | Advisory gate. Returns `allowed=true` iff `balance >= PAYMENTS_RESERVED_MAX_TURN_CREDITS`. |
| `POST` | `/v2/credits/consume` | `{ accountId, usdCostMicros, idempotencyKey, requestId, model? }` | `{ spent, balance, replayed }` | Atomic ledger write. `402 insufficient_balance` when below floor. Idempotent on `(accountId, idempotencyKey)`. |
| `POST` | `/v2/credits/grant` | `{ accountId, credits, grantKindId, idempotencyKey, note? }` | `{ granted, balance, replayed }` | Additive credits only (see §5.5). Today's allowed kinds: `signup_bonus`, `manual`. `daily_refill` is reserved for the future cron path and intentionally not API-callable. |

**Apple-bound** (JWS signature is the auth):

| Method | Path | Body | Returns | Notes |
|---|---|---|---|---|
| `POST` | `/v2/webhooks/apple/ssn` | `{ signedPayload }` | `200` | Same handler as below. iOS brief naming. |
| `POST` | `/v2/webhooks/apple/server-notifications` | `{ signedPayload }` | `200` | Same handler. App Store Connect / PRD naming. See [§6.3](#63-app-store-server-notifications-v2-webhook). |

**Deferred (post-Phase-1)**: per the iOS brief, these are not in the IAP+credits scope and will land in follow-up PRs. Paths shown reflect the agreed namespace.

| Method | Path | Status |
|---|---|---|
| `GET` | `/v2/accounts/me/credits/usage` | Powers contact sheet chart + Settings detail. |
| `GET` | `/v2/accounts/me/credits/usage/agent/:agentInstanceId` | Powers agent contact sheet. |
| `POST` | `/v2/accounts/me/credits/redeem-trial` | NUX 7-day trial grant (additive, uses `grant()`). |
| `GET` | `/v2/products` | Decouples iOS from hardcoded SKU list. |
| **Admin** (separate auth — see §9.12) | | |
| `GET` | `/admin/accounts/:id` | account detail + subscription + balance + last 50 ledger entries |
| `POST` | `/admin/accounts/:id/grant` | new ledger entry |
| `POST` | `/admin/accounts/:id/refund` | new ledger entry + slack alert |
| `GET` | `/admin/policy` | read-only env-var mirror in v1 |
| `GET` | `/admin/grant-kinds` | active `GrantKind` rows |
| `PATCH` | `/admin/grant-kinds/:id` | toggle active/inactive |

### 6.3 App Store Server Notifications v2 webhook

Apple POSTs to `/v2/webhooks/apple/ssn` or `/v2/webhooks/apple/server-notifications` (same handler, both paths registered) for every renewal, billing retry, grace start/end, refund, revoke. Subscription state changes; the credit ledger is **never** written from this handler — subscription credits are derived (§5.5).

| `notificationType` | Action |
|---|---|
| `SUBSCRIBED` (initial / resubscribe) | Update or create `Subscription` row. Status → `active` (or `trial` if `offerType=INTRODUCTORY_OFFER`). No ledger write. |
| `DID_RENEW` | Move `currentPeriodStart` + `currentPeriodEnd`. Status → `active`. `monthlyGrantUsed` naturally resets to 0 on the next read of `/v2/accounts/me/credits` because consumes are filtered by `createdAt >= currentPeriodStart`. No ledger write. |
| `DID_FAIL_TO_RENEW` (subtype: `BILLING_RETRY`) | Set status → `billingRetry`. |
| `DID_FAIL_TO_RENEW` (subtype: `GRACE_PERIOD`) | Set status → `grace`, set `gracePeriodEnd`. Continue serving (period window still active). |
| `GRACE_PERIOD_EXPIRED` / `EXPIRED` | Set status → `expired`, `willRenew=false`. iOS shows the paywall when balance hits 0. |
| `REVOKE` (family sharing revocation) | Set status → `revoked`, `cancelledAt=now`, `willRenew=false`. **No ledger entry** — the derived `monthlyGrant` goes to 0 naturally once status is non-active. |
| `REFUND` | Same as `REVOKE` for the subscription row. Slack alert. **No negative ledger entry** — refunds at the credit-ledger level (top-ups, etc.) are an operator action via `/admin/accounts/:id/refund`, not a webhook side effect. |
| `DID_CHANGE_RENEWAL_STATUS` (auto-renew toggled) | Update `willRenew` based on subtype (`AUTO_RENEW_ENABLED` / `AUTO_RENEW_DISABLED`). No credit change. |
| `DID_CHANGE_RENEWAL_PREF` (cross-grade Builder↔Pro) | Update `tier` + `period` + `productId`. No re-grant or proration write — `monthlyGrant` simply reads the new tier on the next API call. |
| `PRICE_INCREASE` / `PRICE_CHANGE` | No-op ack. (Settings banner is a follow-up; today no state mutates.) |
| `TEST`, `OFFER_REDEEMED`, `RENEWAL_EXTENDED`, `RENEWAL_EXTENSION`, `REFUND_DECLINED`, `REFUND_REVERSED`, `CONSUMPTION_REQUEST`, `METADATA_UPDATE`, `MIGRATION`, `EXTERNAL_PURCHASE_TOKEN`, `ONE_TIME_CHARGE`, `RESCIND_CONSENT` | No-op ack. Receipt still written for audit. |

**Verification**: Apple signs the entire payload as JWS. The header's `x5c` array contains the cert chain — verified against Apple Root CA G2 + G3 (shipped at `src/subscriptions/certs/`). Library: `@apple/app-store-server-library` (Apple-published TS package).

**Idempotency** (as shipped — tighter than the original spec): `AppleReceipt` enforces `@unique` on **both** `idempotencyKey` and `notificationUUID`. The handler computes `idempotencyKey` as the dedup tuple flattened to a string and inserts the row inside a transaction; a `P2002` violation is the replay signal and the handler short-circuits without re-applying state.

**Response semantics**: `200` on every ack (including replay, unknown_subscription, and TEST). `400` only when the JWS itself fails to verify or the body is malformed. `500` for unexpected runtime errors — Apple retries those over a 3-day window with exponential backoff.

**Unknown SKU resilience**: a `productId` that doesn't match `app.convos.subs.<builder|pro>.<monthly|annual>` is logged and the notification still acks `200`. We accept the receipt for audit but skip the Subscription update (a 500 would loop Apple's retries for 3 days; better to fix forward).

### 6.4 Linking Apple's transaction to our `accountId` (strict ownership)

The Apple receipt is tied to Apple ID, not our `accountId`. The bridge: **`appAccountToken`** (a UUID iOS generates per-purchase, passes to StoreKit, Apple persists, and echoes back in every receipt and notification). It is **extracted from the verified JWS payload** — never trusted from the request body.

**As-shipped flow** (changed from the earlier "trust the latest accountId, transfer" draft per @borja's security review on PR #215):

1. iOS app generates `appAccountToken = UUID()` before calling `product.purchase(options: .appAccountToken(uuid))`.
2. iOS posts `POST /v2/accounts/me/subscription/verify` with body `{ jwsRepresentation }` (no `appAccountToken` field — server reads it from the JWS).
3. Backend: JWS verify → extract `appAccountToken` from the decoded transaction → look up Subscription by `originalTransactionId`:
   - **Not found** → create Subscription row. Bind `accountId = caller`, `appAccountToken = JWS value`. First purchase claims the sub.
   - **Found, same `accountId`** → update mutable fields (status, period, etc.). Normal renewal / re-verify path.
   - **Found, different `accountId`** → **`409 subscription_account_mismatch`**. The original buyer owns the subscription for life. No silent transfer.

**Why strict and not "transfer to latest":** trusting the caller-supplied appAccountToken (or silently reassigning on a JWS replay) opened a session-stealing vector — a leaked JWS could be replayed under any caller's account. Strict ownership eliminates that class of attack. Cross-account transfer (a user signs into Convos with a different account on a device with the same Apple ID) becomes a support operation, not an automatic code path. This was explicitly chosen over the convenience flow during the PR #215 review.

**What stays automatic:** subsequent verifies from the **same** account on the **same** Apple ID work transparently — JWS contains the original appAccountToken, server matches it, updates the row. The `appAccountToken` UNIQUE constraint on `Subscription` formalizes the 1:1 binding.

### 6.5 Hermes-side gating (as shipped)

The agent runtime (Hermes, in `convos-assistants/runtime/openclaw/`) is the consumer of the ledger. There is **no slow-mode** — `consume()` hard-fails at the `PAYMENTS_MIN_BALANCE_CREDITS` floor.

Flow per turn:

```
1. User sends message to agent.
2. Hermes handle_message():
   a. POST /v2/credits/check { accountId }
      → 200 { allowed: boolean, balance: string }
   b. If allowed == false: send "insufficient funds" reply, do not call OpenRouter.
   c. If allowed == true: call OpenRouter with the agent's configured model.
3. After OpenRouter response, in parallel:
   a. Relay reply to convos (XMTP message).
   b. POST /v2/credits/consume { accountId, usdCostMicros, idempotencyKey, requestId, model? }
      → 200 { spent, balance, replayed } on success
      → 402 { code: "insufficient_balance", ... } if the deduction would breach the floor
   c. On 402: surface "out of credits" + paywall hint to iOS. Do not retry.
4. Next turn re-evaluates via /check.
```

**Long-term enforcement** moves into Nick's Cloudflare Durable Object wrapping the runtime; ledger model stays the same.

### 6.6 Push notifications for subscription state (deferred — Phase 2)

**Not shipped in PR #215.** Captured here as the planned surface; wiring will land after the IAP flow is dogfooded.

Planned: extend `PushNotificationPayload` (in iOS `ConvosCore/Sources/ConvosCore/Notifications/PushNotificationPayload.swift`) with a new `notificationData.type` value:

- `"credits_low"` — fires at 20% remaining. Body: *"Your credits are running low."*
- `"credits_depleted"` — fires at 0. Body: *"Out of credits — upgrade to keep your agents running."* (No "slow mode" copy — there is no slow mode; see §5.6 and the framing rule in §5.9.)
- `"sub_renewed"` — fires on `DID_RENEW`. Silent (or quiet). Body: *"Your Builder plan renewed. Fresh credits added."*
- `"sub_grace_period"` — fires on `BILLING_RETRY` / `GRACE_PERIOD`. Body: *"Your payment didn't go through — fix it in Settings."*
- `"sub_expired"` — fires on `EXPIRED` / `REVOKED`.

Backend will trigger these from the webhook handler (`sub_*`) and from the credits-burn path (`credits_*`).

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

### Frame 2 — Conversation low-balance banner (account-level)

Shipped in `Convos/Subscription/LowBalanceBanner.swift`, wired into `Convos/Conversation Detail/ConversationView.swift` via a `VStack(spacing: 0) { LowBalanceBanner(); messagesView }` wrapper inside the `messagesPage` closure of `ConversationPager`. Pinned at the top of the messages page; pushes messages down rather than overlapping them.

**Key product call (clarified post-initial-draft):** credits are **account-level, not per-agent**. A low balance affects every agent at once. So the banner reads the account balance once, not per-agent — and "out of credits" applies globally, never to a single agent in isolation.

**States** (from `CreditBalance`):

- `isLow` (balance > 0 and ≤ 20% of grant): amber-tinted banner reading e.g. *"⚠ 180 credits left"*, with an **Upgrade** CTA on the right.
- `isDepleted` (balance ≤ 0): red-tinted banner reading *"⛔ You're out of credits"*, same Upgrade CTA.
- Otherwise: banner returns `EmptyView()` and adds zero height to the layout.

**What is intentionally not in the banner:**

- **No "Top up" button.** The sketch shows it; v1 hides it ("fut" in the sketch — consumable IAP is v1.1).
- **No reference to slow-mode / fallback model.** Per §5.6, the fallback mechanism is never named in user-facing copy. The banner is purely about the **balance**.
- **No per-agent pip on the avatar.** That was a holdover from the initial draft, which assumed per-agent balances. With account-level credits, a per-avatar pip would either always-on-for-every-agent (visual noise) or always-off-when-low (which contradicts the truth), so we don't ship it.

**Tap target:** the Upgrade button presents the same `PaywallView` sheet used everywhere else. Reads from `MockCreditsService.shared.balancePublisher` today; swap for the real service post-StoreKit wiring.

**Gating:** non-production only, parity with HOME pill / Settings row / contact out-of-credits section.

**Operated-by-someone-else case (post-§5.6.1 ownership rollout):** a non-owner sees their **own** balance state in the banner, not the conversation owner's. They never see "this conversation's owner is out of credits" as a banner — that signal lives on the agent contact sheet (Frame 5) and only when they open it.

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

Shipped in `Convos/Conversation Detail/ConversationMemberView.swift`. An `outOfCreditsSection` renders at the top of the agent member detail (above the agent-specific sections) when:

- `member.isAgent` (the credits surface only makes sense on agent contacts), AND
- the account-level credit balance is depleted (`CreditBalance.isDepleted`), AND
- the build is non-production (gating-flag parity with other credits surfaces).

Section contents:

- A header row with an `exclamationmark.octagon.fill` glyph, `"Out of credits"` (semibold), and a one-line explanation: *"Your agents are paused until you upgrade or top up."*
- An **Upgrade** button (red, leading-aligned) that presents the existing paywall sheet (`PaywallView` + `PaywallViewModel(subscriptionService: MockSubscriptionService.shared)` — swap for real `SubscriptionService` once StoreKit lands).

Explicit non-content (per §5.6 framing rule):

- **No mention of "slow mode" or "slower model" anywhere.** The product just states the upgrade ask.
- **No "Top up" button in v1** — the sketch's TOP-UP CTA is deferred to v1.1 with consumable SKUs.

For **non-owners** in the depleted state (post-§5.6.1 ownership rollout), the section shows a passive note: *"This agent's owner is out of credits."* No upgrade CTA (we can't sell a subscription on someone else's behalf) and, again, no "slow mode" copy.

The low-balance pre-zero state is covered by the in-conversation banner (Frame 2), not the contact sheet — the contact sheet stays calm until balance actually hits zero.

### Frame 6 — SETTINGS (subscription row)

Shipped. A `subscriptionSection` in `Convos/App Settings/AppSettingsView.swift` sits between `connectionsSection` and `customizeSection`, gated to non-production. The row title is **"Subscription"** with a trailing live credit count (e.g. *"1,400 credits"*) read from `MockCreditsService.shared.balancePublisher` via `.onReceive` on the enclosing `List`. The row navigates to a new detail view.

**New view:** `Convos/Subscription/SubscriptionSettingsView.swift`. List-based, sections from top to bottom:

1. **Status** — single row: plan title (e.g. *"Builder plan"*, *"Builder trial"*, or *"Free plan"*) on top, status subtitle below (*"Monthly · Renews May 28, 2026"*, *"Monthly · Trial ends in 4 days"*, *"Subscribe to power your agents"*).
2. **Balance** — *"Credits remaining"* on the left, `balance / monthlyGrant` on the right (monospaced digit). Footer: *"Refreshes May 28, 2026"*. Only rendered when a balance is available.
3. **Actions** —
   - Single red button: **Subscribe** when no active subscription, **Change plan** otherwise. Presents the same `PaywallView` sheet used elsewhere.
   - When a subscription is active: secondary **Manage in App Store** button opening `https://apps.apple.com/account/subscriptions` via `Environment(\.openURL)`.

Per-agent **usage chart** (last 30 days, byAgent) is deferred — it's the third unbuilt sketch piece. When it lands it'll live on the agent contact sheet (Frame 4), not in Settings.

Real-StoreKit notes (for the v1 wiring pass that happens after this PRD revision):

- `Restore purchases` lives on the paywall today (`PaywallViewModel.restoreTapped`); we may also surface it inside the Settings detail once we switch to a real `SubscriptionService` — minor.
- The "Manage in App Store" link is a deep link, not a StoreKit call, so it's already production-ready.

### Frame 7 — SUBSCRIBE / paywall (Monthly / Annual toggle, Builder / Pro tiles)

Shipped in `Convos/Subscription/PaywallView.swift`, `TierCard.swift`, and `SubscriptionCopy.swift`. Native SwiftUI (no third-party paywall library).

**Hero copy.**

- Title: **"Power your agents"** — note "agents", not "assistants". The team's product language uses "agents".
- Subtitle: *"Subscribe to keep your agents working for you."*
- Eyebrow: *"Subscription"*.

**Layout** (top to bottom, with `step6x` (24pt) section spacing and `step3x` (12pt) between cards — see §5.9 for the spacing rationale):

1. Hero block (eyebrow + title + subtitle, `step3x` internal spacing).
2. Segmented Monthly / Annual picker.
3. Tier stack — two `TierCard`s, one per tier, current tier outlined in `.colorRed`.
4. Legal row — Terms / Privacy / Restore (text button) + a small auto-renewal disclaimer.

**Tier card content** (all bullets in one VStack with uniform `step2x` (8pt) spacing — see §5.9 on even rhythm):

- Header row: tier name + price (and per-month caption when present).
- A subhead line — *"Enough credits each month to:"* — sourced from `SubscriptionCopy.outcomeIntro`.
- A flat list of bullet rows (one VStack, one spacing value) sourced from `SubscriptionCopy.bullets(for:)`. Builder example: *"Plan ~5 trips"*, *"Run a daily agent for a month"*. Pro adds *"Power a team of agents"* and *"Priority support"*.
- For non-current tiers: a primary **Subscribe** button at the bottom. The label stays `Text("Subscribe")` to lock the layout; the purchase spinner sits in `.overlay` (with `controlSize(.small)`) so the button never resizes between idle and in-flight states.

**What is intentionally NOT on the paywall** (per §5.9):

- No "Standard model on every reply" / "Premium model access" / "Use any model" bullets — model gating is not the product axis.
- No "Free slow-mode when credits run low" — there is no slow-mode at all (§5.6).
- No per-message token counts.

**ViewModel** (unchanged from initial draft): `PaywallViewModel`. Loads products via `Product.products(for: ProductIDs.all)`, maps to tiers, handles purchase / restore / error states. Today injected with `MockSubscriptionService`; swap to the real `SubscriptionService` once the StoreKit + backend wiring lands.

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
- `.builder_depleted` — Builder, 0 credits (next turn → out-of-credits paywall)
- `.pro_ample` — Pro, 4,500 credits
- `.trial_active` — trial, 350 credits, expires in 4 days
- `.trial_expired` — no sub, 0 credits (next turn → out-of-credits paywall)
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
| 1 (highest) | Pro | Pro Annual (-20%) | `app.convos.subs.pro.annual` | 1 year | $1919.90 | OFF (v1) |
| 2 | Pro | Pro Monthly | `app.convos.subs.pro.monthly` | 1 month | $199.99 | OFF |
| 3 | Builder | Builder Annual (-10%) | `app.convos.subs.builder.annual` | 1 year | $214.89 | OFF |
| 4 (lowest) | Builder | Builder Monthly | `app.convos.subs.builder.monthly` | 1 month | $19.99 | OFF |

For each subscription, fill:

- **Subscription Display Name** (English-US): "Convos Builder" / "Convos Pro"
- **Description** (English-US, ~70 words): mention monthly credit allotment, agent usage, renewal/billing wording. **No "slow mode" copy** — there is no slow-mode mechanism (§5.6). Plain English only — Apple rejects marketing speak like "best" / "amazing" / "limited time".
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
| **Migration of `UserCredits` from `inboxId` to `accountId`** — ✅ landed inside PR #191; no longer a blocker. | (resolved) |
| **macOS test compilation rule** (per CLAUDE.md). | StoreKit 2 is iOS/macOS compatible. `ProductIDs` and `PaywallView` are main-app only (iOS-only) so the constraint is only on `Credits*Service` and models in ConvosCore — those use only Foundation. |
| **Free-tier abuse** (user creates many accounts to farm trial credits). | Trial grant is per `accountId`; SIWE binding means a wallet can only generate one accountId. Multi-wallet farming is possible but bounded. Add a per-IP cap in v1.1 if abuse appears. |
| **Retention cliff at 0 balance.** No slow-mode means users hit a hard stop. If real data shows churn spike at depletion, revisit. | Track depletion → upgrade conversion. If <X%, propose a concrete slow-mode-or-something proposal with cost model. v1 explicitly ships without it (§5.6). |
| **CDO (Cloudflare Durable Object) enforcement architecture timing.** Nick's design eventually gates OpenRouter at infra level. If it lands in v1, iOS bypasses Hermes-side coordination; if v1.1+, we ship Hermes-based first and migrate later. Ledger model unchanged. | See team Q C1 for timing. v1 plan assumes Hermes-based enforcement; migration is purely server-side. |
| **Hermes per-session cache staleness.** If a user tops up (or renews) mid-session, the cached balance is stale until next turn. | v1: re-check via `/v2/credits/check` at every turn boundary anyway. v1.1: push refresh from backend on grant events. |

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
| B1 | Confirm launch values: `PAYMENTS_MARKUP_RATE` (currently 2.0), `PAYMENTS_CREDITS_PER_USD` (currently 1000), `PAYMENTS_RESERVED_MAX_TURN_CREDITS` (currently 1), `PAYMENTS_MIN_BALANCE_CREDITS` (currently 0, hard floor — no slow-mode). Plus `PAYMENTS_GRANT_BUILDER_MONTHLY` (placeholder 2500) and `PAYMENTS_GRANT_PRO_MONTHLY` (placeholder 10000). Final per-tier numbers TBD by product. Use Borja's `credit-pricing-calculator.html`. | Saul + Borja |
| B2 | Daily cron free-tier grant — amount + cadence + eligibility. Options: (a) every account, N credits/day forever; (b) only "active in last 7d"; (c) only "no active sub"; (d) something else. Will flow through `grant({ kind: "daily_refill" })`. | PM + Borja |
| B3 | ~~Subscription grant cadence~~ — **resolved**: subscription credits are derived, not granted (§5.5). Period rollover = move `currentPeriodStart` on `DID_RENEW`, used = Σ consumes since that boundary. | (resolved) |
| B4 | Cross-grade Builder↔Pro mid-cycle — Apple sends `DID_CHANGE_RENEWAL_PREF`; backend updates `tier`/`period`/`productId` in the row. `monthlyGrant` reads the new tier on the next API call. No proration write. Confirm UX expectation matches. | PM |
| B5 | ~~Slow-mode cost~~ — **resolved**: there is no slow-mode (§5.6). Consume hard-fails at 0; iOS shows paywall. | (resolved) |
| B6 | "Earn on usage" credit source mentioned by @borja — referral, engagement reward, both, neither? When does it ship? Will flow through `grant()` with a new `GrantKind` row. | PM |
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

### Group F — Builder incentives *(flagged as "most important early lever" in the team thread)*

The thesis from the Revision-history team thread: the Meetup precedent — charging the people who drive growth — is a category mistake. Builders publishing agents and inviting users are doing the growth work; the early monetization needs to come from consumer subscribers while we **subsidize the builders**. The shape is open, but the direction is decided. Captured as open product questions so the implementation pass doesn't ship without a position.

| # | Question | Owner |
|---|---|---|
| F1 | What counts as a "builder"? (a) Any account that publishes an agent; (b) account with ≥N published agents; (c) account whose agents have ≥M cumulative invocations by non-owners. Eligibility gate matters because it determines the abuse surface. | PM + Borja |
| F2 | What credit-earning events should grant credits to builders? Candidate menu: (a) publishing a new agent (one-time bonus); (b) someone joining a convo with your agent; (c) someone using your agent (per-invocation, capped); (d) milestone bonuses (10/100/1000 users). | PM |
| F3 | Builder grants — are they (i) a separate `GrantKind { id: 'builder_incentive_2026_05', expiresAfterDays: 30 }`, (ii) tagged ledger rows against the same `subscription_*` GrantKind, or (iii) a parallel `BuilderCredits` table joined at balance-fetch time? Affects whether builder credits expire, stack, and how the UI surfaces "earned" vs "purchased" credits. | Borja + PM |
| F4 | UI surface for "earned" builder credits — invisible (just adds to balance), separate "Earned this month" line in Settings → Subscription, or a dedicated badge on the HOME pill? Affects perceived value and how loud we want this lever to be. | Design + PM |
| F5 | Abuse model. Self-invites, fake user rings, agent spam, and (later) agents farming invocations of each other. What rate limits, eligibility windows, and human-review hooks does v1 need? Likely a soft cap per month + admin override. | Borja + ops |
| F6 | Anti-cannibalization. Does aggressive builder subsidy create a path where heavy builders never need to subscribe? If yes, the lever still works as long as their agents drive paying users, but it changes the LTV math we report. Worth a short model before launch. | PM + Borja |
| F7 | Timing. Ship builder incentives in v1, v1.1, or only after we see organic builder behavior? Risk of v1: it'll be the most novel piece of the product and the most likely to misfire; risk of v1.1: we miss the chance to make builders the early flywheel. | PM (decision-maker) |

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
Convos/Conversation Detail/Messages/MessagesListView/MessagesGroupView.swift (no per-message UI — out-of-credits is the conversation banner)
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
# convos-backend env vars — launch defaults (PR #191 + PR #215)
PAYMENTS_CREDITS_PER_USD=1000              # 1 credit = $0.001 nominal
PAYMENTS_MARKUP_RATE=2.0                   # 2× multiplier (50% gross margin) — see §5.2
PAYMENTS_RESERVED_MAX_TURN_CREDITS=1       # advisory check: balance must be ≥ this to start a turn
PAYMENTS_MIN_BALANCE_CREDITS=0             # hard floor; consume() throws below this. No slow-mode.

# Per-tier monthly credit allotments (PR #215). Annual = 12× monthly per renewal cycle.
# Placeholder values — final TBD by product. Read at /v2/accounts/me/credits.
PAYMENTS_GRANT_BUILDER_MONTHLY=2500
PAYMENTS_GRANT_PRO_MONTHLY=10000

# Apple integration (PR #215)
APPLE_BUNDLE_ID=org.convos.ios             # required at runtime
APPLE_ENV=production                       # one of: production | sandbox | local-testing (local-testing rejected in prod)
APPLE_APP_APPLE_ID=<numeric app id>        # required in production (numeric, from App Store Connect)
APPLE_API_ISSUER_ID=<uuid>                 # In-App Purchase Key issuer ID
APPLE_API_KEY_ID=<10 chars>                # In-App Purchase Key ID
APPLE_API_SIGNING_KEY=<.p8 PEM contents>   # SECRET — goes in AWS Secrets Manager, not env_vars
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
