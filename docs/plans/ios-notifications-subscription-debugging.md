# iOS Push Notification Registration and Subscription Debugging Plan

## Problem statement

We can receive and decode a push on a clean simulator with the current iOS codebase, which makes a global APNS rejection unlikely. The remaining failure modes are around state we maintain before delivery:

- the local APNS push token may not be registered in the backend,
- the backend may have a stale or missing `DeviceRegistration`,
- the current XMTP `clientId` may not be mapped to the current `deviceId`,
- the user may not be subscribed to the expected XMTP notification topics,
- the app may be repeatedly re-sending full topic subscription sets without knowing whether anything changed.

The debugging gap is that the backend does not currently persist the applied topic set, and the XMTP notifications server client generated in `../convos-backend/src/gen/notifications/v1/service_pb.ts` exposes only `registerInstallation`, `deleteInstallation`, `subscribe`, `subscribeWithMetadata`, `unsubscribe`. There is no `listSubscriptions` or `getInstallation` RPC, so the backend cannot answer "what is this installation actually subscribed to in the XMTP notification server?". It can only infer from calls that passed through our API.

This plan distinguishes:

- **actual remote subscription state** in the XMTP notification server (not queryable today),
- **last desired subscription state** recorded by our backend when iOS called `/v2/notifications/subscribe` (what we will persist and debug against).

## Plan summary

Per `/plan-eng-review` decision D1, this plan ships as two PR stacks:

| Stack | Ships | Surface |
|-------|-------|---------|
| **Stack 1 — iOS bug fixes** | first | iOS-only: AppDelegate token handoff, debug button fix, debounce, decoupled discovery |
| **Stack 2 — Diagnostics + backend hardening** | after Stack 1 observed in Datadog | Backend snapshot model + debug-status endpoint + DebugPushNotificationsView + webhook diagnostics + absorbed register/unregister bugs |

The split is intentional: Stack 1 is the actual fix; Stack 2 is the visibility we'd want to confirm Stack 1 worked and to debug future incidents. The 24-48h Datadog observation between stacks tells us whether iOS-side changes alone resolved the noise.

Companion artifacts (review them alongside this plan):
- **Test plan**: [`ios-notifications-subscription-debugging-test-plan.md`](./ios-notifications-subscription-debugging-test-plan.md) — affected routes, key interactions, edge cases, critical regression tests pinned by IRON RULE.
- **Implementation tasks (JSONL)**: [`ios-notifications-subscription-debugging-tasks.jsonl`](./ios-notifications-subscription-debugging-tasks.jsonl) — machine-readable T1–T19 task list with effort estimates and file lists; consumable by `/autoplan` aggregation.

## Decisions locked in eng review

Eng review session 2026-05-29. All decisions accepted with my recommendation unless noted.

| # | Decision | Outcome |
|---|----------|---------|
| D1 | Plan scope split | Stack 1 (iOS fixes) → Datadog observation → Stack 2 (diagnostics + backend hardening) |
| D2 | AppDelegate token race fix | Use `PushNotificationRegistrar.save(token:)` static; drop injected `pushNotificationRegistrar` property on AppDelegate |
| D3 | requestDiscovery → reconcile decoupling | `discoverNewConversations()` returns `Int`; reconcile only when count > 0 — paired with D14 token-change trigger |
| D4 | Snapshot identity model | Keyed `clientId @id`; `accountId` indexed; `topicHashes[]` dropped. **D13 reverses the at-apply field drop** (see below) |
| D5 | `/v2/notifications/debug/status` deployment | Production-safe, JWT-gated, hashes-only response, rate-limited 1/sec/JWT |
| D6 | Subscribe body shape | Aggregate `kindSummary` (structured JSON), `context`, `source`, `accountId`. Correction: phrase is "no raw topics in **logs/debug responses**", not "on the wire" — subscribe necessarily sends raw topics |
| D7 | `PushTopicSubscriptionManager` shape | Extract `computeDesiredSubscriptions(...)` as private actor method before adding debounce + diagnostics layers |
| D8 | iOS debounce cache contract | Write only inside subscribe()'s success branch; key = `environment + accountId + deviceId + clientId + apnsEnv + pushTokenSha256`; clear on sign-out / delete / unregister / identity rotation; **only write when D16 `remoteApplied: true`** |
| D9 | ASCII diagrams | Required at three sites: AppDelegate token receive, reconcilePushTopics pipeline, requestDiscovery decision |
| D10 | Static `save(token:)` safety | Graceful: log error + no-op if `configure()` hasn't run; do NOT propagate fatalError on the hot path. Bootstrap test asserts configure-before-save in real lifecycle, not just no-crash |
| D11 | Backend idempotency TTL | 10 minutes on identical `(clientId, deviceId, topicHash, apnsEnv, pushTokenHash)` tuples |
| D12 | Outside voice | Codex consulted; cross-model tensions in D13–D17 |
| D13 | **Cross-model P0**: snapshot at-apply fields are NOT derivable | Restore `pushTokenSha256AtApply` + `apnsEnvAtApply` on snapshot. They are correctness state, not redundancy. Idempotency compares these to current DeviceRegistration; either differs → re-apply |
| D14 | **Cross-model P0**: D3 gate misses token/identity triggers | Add second reconcile trigger: listen for `.convosPushTokenDidChange` and identity rotation; D8 cache key change ensures the trigger fires the network call |
| D15 | **Cross-model P0**: cross-account push delivery | `ClientIdentifier` gains `accountId` column (set from JWT on subscribe); webhook refuses to deliver when `client.accountId != deviceRegistration.accountId`; one-time backfill migration |
| D16 | **Cross-model P1**: HTTP 200 ≠ remote-applied | Subscribe response shape `{ ok, remoteApplied: bool, snapshot: {hash, count, lastSubscribeAt}, skipped?: 'idempotent' | 'no_push_token' | 'disabled' }`. iOS writes debounce cache only when `remoteApplied: true`. `skipped` enum surfaces in debug screen verbatim |
| D17 | Absorbed existing backend bugs into Stack 2 | (a) NSE unregister path accepts NSE JWT via separate middleware with reduced privilege (delete-own-installation only); (b) `/v2/device/register` resets `disabled=false`, `pushFailures=0` when a NEW token (different from stored) arrives |
| D18 | TODO for upstream `listSubscriptions` RPC | Skipped — not creating TODOS.md for this |

Folded-in obvious wins (no decision needed, from codex):
- AccountId always sourced from JWT, never from request body, on both `/v2/notifications/subscribe` and `/v2/notifications/debug/status`.
- Backend subscribe body fields stay `.optional()` in Zod schema for forward/backward rollout safety.
- Hash canonicalization: sorted UTF-8 topic strings, joined with `\n` separator, SHA-256 hex lowercase. Identical implementation in Swift (CryptoKit) and TS (node:crypto). Pin this in code comments at both call sites.
- Debug screen shows a `registrar configured: y/n` row to surface bootstrap bugs.
- `.iOSExtension` PlatformProviders does not call `configure()`; add a regression test asserting `save(token:)` no-ops cleanly in that environment.
- Debug-status scopes lookups by `JWT.accountId + JWT.deviceId`, not just `deviceId`.

## Current architecture

### iOS registration path

Files: `Convos/ConvosAppDelegate.swift`, `ConvosCore/Sources/ConvosCoreiOS/IOSPushNotificationRegistrar.swift`, `ConvosCore/Sources/ConvosCore/Device/DeviceRegistrationManager.swift`, `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`.

```
ConvosApp.init
  └─> PlatformProviders.iOS
        └─> PushNotificationRegistrar.configure(IOSPushNotificationRegistrar())
              [singleton _shared is set HERE, before UIKit runs]
─── UIKit hands off ───
ConvosAppDelegate.application(_:didFinishLaunchingWithOptions:)
  └─> UIApplication.registerForRemoteNotifications()
APNS
  └─> ConvosAppDelegate.didRegisterForRemoteNotificationsWithDeviceToken
        └─> PushNotificationRegistrar.save(token: token)   ← D2 static
              └─> NotificationCenter.post(.convosPushTokenDidChange)
                    └─> [listener] DeviceRegistrationManager.registerDeviceIfNeeded
                          └─> POST /v2/device/register
                    └─> [D14 listener] PushTopicSubscriptionManager.reconcilePushTopics
```

### iOS topic subscription path

Files: `ConvosCore/Sources/ConvosCore/Syncing/PushTopicSubscriptionManager.swift`, `SyncingManager.swift`, `StreamProcessor.swift`, `MessagingService+PushNotifications.swift`, `ConversationStateMachine.swift`.

The manager computes subscriptions for: inbox welcome topic, group topics, invite DM topics. Posts via `ConvosAPIClient.subscribeToTopics(...)`.

Full reconcile call sites (after Stack 1):
- after initial sync (unchanged)
- after resume (unchanged)
- **after requested discovery — only if `discoveredCount > 0`** (D3)
- **on `.convosPushTokenDidChange`** (D14)
- **on identity rotation** (D14)

`ConversationStateMachine` join flow starts a 3s discovery poll. After D3 + D8, that poll no longer floods `/v2/notifications/subscribe`: most ticks return `discoveredCount == 0` so reconcile isn't called at all; the one tick where the welcome arrives triggers a single reconcile, and the iOS-side hash cache (D8) suppresses any further duplicates.

### Backend registration path

Files in `../convos-backend`: `src/api/v2/device/handlers/register.ts`, `prisma/schema.prisma`.

`/v2/device/register` upserts `DeviceRegistration` (`deviceId`, `pushToken`, `pushTokenType`, `apnsEnv`, `pushFailures`, `disabled`, `lastSentAt`, `lastFailureAt`, `accountId`). Migrates `ClientIdentifier` rows if a push token moves to a new device.

**Stack 2 absorbs D17(b)**: when a new push token arrives that differs from the stored one, also reset `disabled=false` and `pushFailures=0` so a previously-disabled device recovers automatically on token rotation.

### Backend subscription path

Files: `src/api/v2/notifications/handlers/subscribe.ts`, `unsubscribe.ts`, `unregister.ts`, `src/notifications/client.ts`.

`/v2/notifications/subscribe` (current):
1. Parses `deviceId`, `clientId`, `topics`.
2. Logs `Subscribing to topics` with `topicCount`.
3. Verifies JWT `deviceId` matches request `deviceId`.
4. Loads `DeviceRegistration`.
5. Calls XMTP notifications server: `registerInstallation` + `subscribeWithMetadata`.
6. Upserts `ClientIdentifier(clientId -> deviceId)`.

Does not store topic list or hash.

### Backend delivery path

Files: `src/api/v2/notifications/handlers/webhook.ts`, `apns-push.service.ts`, `fcm-push.service.ts`.

XMTP webhook → look up `ClientIdentifier(id: installation.id)` → load `DeviceRegistration` → build payload → APNS/FCM → update `pushFailures`/`lastSentAt`/`lastFailureAt`. APNS 200 logs `[APNS] Push notification sent successfully` and `[APNS] Successfully sent v2 push notification`. Proves Apple accepted; not that iOS displayed.

## Findings so far

### Repeated subscribe logs are explainable from current iOS code

The repeated `Subscribing to topics` logs are iOS reconciliation, especially `requestDiscovery()` during join polling. Backend is not independently polling — it responds to each iOS request.

Most suspicious path:
1. User enters join flow.
2. `ConversationStateMachine` starts discovery polling every 3s.
3. Each `requestDiscovery()` calls `SyncingManager.requestDiscovery()`.
4. `SyncingManager.requestDiscovery()` calls `streamProcessor.reconcilePushSubscriptions(...)`.
5. `PushTopicSubscriptionManager.reconcilePushTopics(...)` sends the full topic set.
6. Backend logs `Subscribing to topics` with high `topicCount`.

**Fixed by Stack 1**: D3 gate + D8 cache.

### Backend does not currently support topic-state debugging

No `listSubscriptions` RPC. Debug UI must label:
- **local desired topics** (computed on-device now),
- **backend last requested topics** (persisted by our backend from the last subscribe call),
- **actual XMTP notification server topics** (NOT queryable with current RPCs).

### Existing debug device-registration button is misleading

`Convos/Debug View/DebugView.swift:402` calls `let platformProviders = PlatformProviders.iOS` inside `registerDeviceAgain()`. `PlatformProviders.iOS.configure()` is guarded (only the first call wins), but the second invocation still constructs a fresh `IOSPushNotificationRegistrar` whose `_token` is nil — so the debug flow can fight the real app's state.

**Fixed by Stack 1**: use `PushNotificationRegistrar.shared` directly, or pass the configured `PlatformProviders` into `DebugViewSection`.

### AppDelegate token timing was assumed to be a race; it isn't, but the singleton path is still safer

`PushNotificationRegistrar.configure()` runs inside `PlatformProviders.iOS` at `ConvosApp.init` line 78 — before UIKit fires `application(_:didFinishLaunchingWithOptions:)`. So under SwiftUI lifecycle, the singleton is ready by the time APNS callbacks fire.

Per D2, the injected-property pattern is replaced with `PushNotificationRegistrar.save(token:)` static. Per D10, the static is graceful (log + no-op) if configure() didn't run, so test environments and any future lifecycle change degrade safely rather than crashing.

## Stack 1 — iOS bug fixes

Goal: fix the production bugs causing the Datadog noise. No UI changes. Validate via Datadog drop in `/v2/notifications/subscribe` calls over 24-48h.

### 1.1 — Replace injected `pushNotificationRegistrar` with static singleton

`ConvosAppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`:

```swift
// Lifecycle ordering invariant (D2):
//   ConvosApp.init               ──> PlatformProviders.iOS
//                                       └─> PushNotificationRegistrar.configure()
//   UIKit                        ──> application(_:didFinishLaunching:)
//                                       └─> registerForRemoteNotifications()
//   APNS                         ──> this method runs HERE
//                                       └─> shared singleton is ready
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    Log.info("Received device token from APNS")
    PushNotificationRegistrar.save(token: token)
}
```

Also delete the `var pushNotificationRegistrar` property and its assignment in `ConvosApp.init`.

Per D10, `PushNotificationRegistrar.save(token:)` becomes graceful — current implementation calls `shared` which `fatalError`s if unconfigured. Change to:

```swift
public static func save(token: String) {
    lock.lock()
    let configured = _shared
    lock.unlock()
    guard let registrar = configured else {
        Log.error("PushNotificationRegistrar.save called before configure() — token dropped (env: \(Self.environmentDescription()))")
        return
    }
    registrar.save(token: token)
}
```

Keep the fatalError on `shared` itself — explicit reads still want loud failures.

### 1.2 — Fix debug `Register Device Again` button

`Convos/Debug View/DebugView.swift:398-410`: remove `let platformProviders = PlatformProviders.iOS` line; route through whatever the app already injected (either pass `PlatformProviders` into `DebugViewSection` or use `PushNotificationRegistrar.shared` for the token side and a shared `DeviceRegistrationManager` for the registration side).

### 1.3 — Extract compute step in `PushTopicSubscriptionManager` (D7)

Refactor: introduce a private actor method:

```swift
private func computeDesiredSubscriptions(
    kinds: Set<TopicKind>,
    params: SyncClientParams
) async -> [TopicSubscription]
```

`reconcilePushTopics`, `subscribeToGroupsAndWelcome`, `subscribeToInviteDMTopics` all call this then layer their own behavior on top.

### 1.4 — Add iOS-side hash debounce (D8 + D16)

```
reconcilePushTopics(params:, context:)
 ├─ compute desired subscriptions
 ├─ canonicalize: sorted UTF-8 topics joined with "\n", SHA-256 hex lowercase
 ├─ cache key: environment + accountId + deviceId + clientId + apnsEnv + pushTokenSha256
 ├─ cache.get(key) == currentHash?
 │    ├─ yes ──> Log.debug("Reconcile no-op, cache hit"); return
 │    └─ no  ──> subscribe(to: subscriptions)
 │                ├─ on throw         ──> Log.warning + emit QAEvent + DO NOT write cache
 │                └─ on .ok response  ──> if response.remoteApplied { cache.put(key, currentHash) }
 │                                       else                       { Log.warning("Subscribe \(response.skipped ?? "unknown") — cache not written") }
```

Cache storage: `UserDefaults` (per-environment). Cache cleared on sign-out, delete, unregister, and identity rotation (explicit hook).

### 1.5 — Decouple `requestDiscovery` from reconcile (D3) + add token-change trigger (D14)

`SyncingManager.discoverNewConversations` changes return type to `Int` (count of new conversations actually written).

```
requestDiscovery() {
  await syncAllConversations
  let discovered = await discoverNewConversations()
  // D3: only reconcile if conv set actually grew. The 3s join-poll loop will
  //     see discovered==0 on every tick after the first, so the noisy path is silent.
  if discovered > 0 {
    await streamProcessor.reconcilePushSubscriptions(params:, context: "after requested discovery")
  }
}
```

Token-change trigger (D14) wires a `.convosPushTokenDidChange` listener somewhere durable (likely in `DeviceRegistrationManager` or `SyncingManager.setupNotificationObservers`):

```swift
// When IOSPushNotificationRegistrar.save(token:) detects a change it posts
// .convosPushTokenDidChange. The TOPIC subscription side needs to re-apply
// even when the conversation set is unchanged, because XMTP server still
// has the old deliveryMechanism until subscribeWithMetadata fires.
NotificationCenter.default.addObserver(forName: .convosPushTokenDidChange) { _ in
    Task { await streamProcessor.reconcilePushSubscriptions(params:, context: "after token change") }
}
```

Identity rotation: invalidate the iOS hash cache via `cache.clear(forIdentity:)` and let the next reconcile compute fresh.

### 1.6 — ASCII diagrams in code (D9)

Inline at three sites:
- `ConvosAppDelegate.didRegisterForRemoteNotifications`: lifecycle ordering invariant (the one above).
- `PushTopicSubscriptionManager.reconcilePushTopics`: the pipeline (the one above).
- `SyncingManager.requestDiscovery` decision: the count-gate plus token-change trigger note.

Add diagram maintenance to PR checklist.

### Stack 1 acceptance criteria

- From a stuck join flow (30 seconds of 3s polling with no new conversation appearing), `/v2/notifications/subscribe` is hit **at most once** total (Datadog).
- A reconcile with an empty topic set is suppressed by the iOS hash cache.
- A simulated subscribe failure does NOT update the cache (next reconcile re-attempts).
- Force-quit + relaunch: the `PushNotificationRegistrar.save(token:)` call from APNS succeeds and `DeviceRegistration` rows in backend show the current token (not previous).
- The `Register Device Again` debug button does not construct a fresh `IOSPushNotificationRegistrar`.
- Token rotation triggers a single subscribe call via the D14 listener.
- Sign-out clears the iOS hash cache so a new sign-in's first reconcile hits the wire.

## Stack 2 — Diagnostics + backend hardening

Ships after Stack 1 lands and we've observed the Datadog drop for 24-48 hours. Stack 2 is the visibility we'd want for future incidents PLUS the backend hardening D17 named.

### 2.1 — Backend schema (Prisma migration)

```prisma
model NotificationSubscriptionSnapshot {
  clientId                  String   @id
  client                    ClientIdentifier @relation(fields: [clientId], references: [id], onDelete: Cascade)
  accountId                 String
  topicCount                Int
  topicHash                 String
  kindSummary               Json?      // {welcome:1, group:42, inviteDM:7}
  lastContext               String?
  lastSubscribeAt           DateTime @default(now())
  lastRemoteApplySucceeded  Boolean
  lastRemoteApplyError      String?
  pushTokenSha256AtApply    String     // D13 — correctness, not redundancy
  apnsEnvAtApply            ApnsEnvironment   // D13 — correctness, not redundancy
  createdAt                 DateTime @default(now())
  updatedAt                 DateTime @updatedAt

  @@index([accountId])
  @@index([updatedAt])
}

// D15 — cross-account push delivery prevention
model ClientIdentifier {
  id        String  @id
  deviceId  String
  accountId String?  // new column; backfilled by migration, set from JWT going forward
  // ...existing fields...

  @@index([accountId])
}
```

One-time migration backfills `ClientIdentifier.accountId` from the joined `DeviceRegistration.accountId` (best effort; ambiguous joins leave NULL, which the webhook treats as stale).

### 2.2 — `POST /v2/notifications/debug/status` (new, production-safe)

D5 contract: JWT-gated, response is hashes-and-booleans only, rate-limited 1/sec/JWT, scoped by `JWT.accountId + JWT.deviceId`. Audit-log every call.

Request:
```json
{
  "clientId": "...",
  "pushTokenSha256": "hex sha256 of local APNS token",
  "pushTokenType": "apns",
  "apnsEnv": "production"
}
```

Response:
```json
{
  "registrarConfigured": true,
  "device": { "exists": true, "hasPushToken": true, "pushTokenMatches": true, "pushTokenTypeMatches": true, "apnsEnvMatches": true, "disabled": false, "pushFailures": 0, "lastSentAt": "...", "lastFailureAt": null, "updatedAt": "..." },
  "client": { "exists": true, "mappedDeviceId": "...", "deviceIdMatchesJwt": true, "accountIdMatchesJwt": true, "updatedAt": "..." },
  "subscriptionSnapshot": { "exists": true, "topicCount": 50, "topicHash": "...", "kindSummary": {"welcome": 1, "group": 42, "inviteDM": 7}, "lastContext": "after resume", "lastSubscribeAt": "...", "lastRemoteApplySucceeded": true, "lastRemoteApplyError": null, "pushTokenMatchesAtApply": true, "apnsEnvMatchesAtApply": true, "isActualRemoteState": false }
}
```

Negative tests assert: response never contains a raw push token, raw topic string, or JWT echo.

### 2.3 — Extend `/v2/notifications/subscribe`

Body adds (all `.optional()` in Zod for rollout safety):
```json
{
  "deviceId": "...",
  "clientId": "...",
  "topics": [...],
  "context": "after requested discovery",
  "source": "ios-main",
  "kindSummary": { "welcome": 1, "group": 42, "inviteDM": 7 },
  "force": false
}
```

`accountId` is read from JWT only — never from request body.

Idempotency (D11, D13, D16):
- Look up snapshot by `clientId`.
- Skip XMTP server calls when ALL of: `topicHash` matches, `snapshot.pushTokenSha256AtApply == DeviceRegistration.pushTokenSha256`, `snapshot.apnsEnvAtApply == DeviceRegistration.apnsEnv`, `snapshot.lastSubscribeAt < 10 minutes ago`, `snapshot.lastRemoteApplySucceeded == true`, and `force != true`.
- Otherwise, call `registerInstallation` + `subscribeWithMetadata`, then upsert snapshot with the new `pushTokenSha256AtApply` and `apnsEnvAtApply`.

Response shape (D16):
```json
{
  "ok": true,
  "remoteApplied": true,
  "snapshot": { "hash": "...", "count": 50, "lastSubscribeAt": "..." },
  "skipped": null
}
```
or
```json
{
  "ok": true,
  "remoteApplied": false,
  "snapshot": { ... },
  "skipped": "idempotent" | "no_push_token" | "disabled"
}
```

iOS writes the debounce cache only when `remoteApplied == true`. `skipped` value displays verbatim in `DebugPushNotificationsView`.

Datadog logs: `context`, `source`, `topicCount`, `topicHash`, `accountId`, `clientId`, `deviceId`, `remoteApplied`, `skipped`.

Hash canonicalization (pin in code comments at both call sites):
- Topics sorted lexicographically as UTF-8 strings.
- Joined with `\n` separator (single LF, not CRLF).
- SHA-256, hex output lowercase.
- Same routine on iOS (CryptoKit) and Node (node:crypto).

### 2.4 — `/v2/device/register` reset on new token (D17b)

When the incoming `pushToken` differs from the stored `DeviceRegistration.pushToken`:
- set `disabled = false`,
- set `pushFailures = 0`,
- (existing) update `pushToken`, `apnsEnv`, `lastSentAt = null`, `lastFailureAt = null`.

This guarantees a device that was auto-disabled due to BadDeviceToken on the previous token recovers automatically on token rotation.

### 2.5 — NSE `/notifications/unregister` accepts NSE JWT (D17a)

Today the NSE-triggered unregister goes through `authMiddleware` which rejects NSE JWTs. Result: stale `ClientIdentifier` rows pile up.

Fix: new `nseAuthMiddleware` that validates the NSE JWT shape and grants reduced privilege — only `DELETE` of the installation the JWT identifies. Mount it on `/notifications/unregister`. Audit-log every call.

### 2.6 — Webhook diagnostics (existing plan item)

In `webhook.ts`:
- If no `ClientIdentifier` exists for `notification.installation.id`: log structured warning with `installationId`, `contentTopic`, `messageType`, `timestampNs`. Return 200.
- **D15**: If `ClientIdentifier.accountId != DeviceRegistration.accountId`: log structured `client_account_mismatch` warning with the IDs, return 200, do NOT call APNS. Prevents cross-account push delivery.

### 2.7 — iOS `DebugPushNotificationsView`

Linked from `DebugViewSection.pushNotificationsSection`. Read-only display plus action buttons.

Local state rows:
- registrar configured: y/n (surfaces D10 bootstrap bugs)
- notification authorization status
- local accountId, deviceId, current keychain clientId, current inboxId
- APNS env, bundle id
- local APNS token present: y/n; SHA-256 (truncated); env
- last local device-registration UserDefaults state

Backend state rows (from `/v2/notifications/debug/status`):
- device row exists / push token match / APNS env match / push token type match / disabled / failure count / last sent / last failure
- client row exists / mapped deviceId / matches JWT / accountId matches JWT
- snapshot row exists / topic count / topic hash / kind summary / last context / last subscribe / last remote applied / last error / **pushTokenMatchesAtApply** (D13) / **apnsEnvMatchesAtApply** (D13) / "actual remote XMTP state not queryable"

Actions:
- Request APNS token
- Force device register
- Probe backend registration
- Force topic reconcile (sets `force: true` in subscribe body)
- Copy diagnostics JSON (output contains hashes only, no raw token/topics/JWT)

## NOT in scope

- Querying actual remote XMTP notification server topic state — requires upstream `listSubscriptions` RPC that doesn't exist (D18 skipped, won't track in repo).
- Exposing raw APNS tokens in responses or logs.
- Exposing raw topic names broadly in production diagnostics. Subscribe body still carries raw topics (necessary), but logs/debug responses must redact.
- Redesigning the authorization-then-register flow on cold launch.
- Adding a feature flag for the debug screen — DEBUG menu gating is the existing pattern.
- Changing APNS payload structure or notification rendering.
- FCM (Android) path — same code lives there but Android push state is out of scope for this iOS plan.
- Cross-device cleanup beyond what D17a (NSE unregister) and D17b (register reset) do — broader keychain-restore / multi-device sync is a separate concern.

## What already exists

Inventory of code that already partially solves the problem, surfaced during eng review:

- `PushNotificationRegistrar` static singleton with `.configure()` / `.shared` / `.save(token:)` accessors — `ConvosCore/Sources/ConvosCore/Inboxes/PushNotificationRegistrarProtocol.swift`. Replaces D2's hand-rolled buffering.
- `PushTopicSubscriptionManager.dedupe` already collapses duplicate topics by string (line 392-400). No new dedupe layer needed — the hash debounce sits above this.
- `XMTPPushTopicConversationLister` already abstracts the XMTP-side conversation enumeration cleanly (lines 59-93) — D7's `computeDesiredSubscriptions` calls into it, no new abstraction needed.
- `SyncingManager.discoverNewConversations` (lines 488-530) already counts new conversations internally — D3 just promotes that count to a return value.
- `IOSPushNotificationRegistrar.save(token:)` already posts `.convosPushTokenDidChange` on actual change (line 28-31) — D14 adds a listener; the change-detection is already there.
- `RecordingPushAPIClient` test fixture (in `PushTopicSubscriptionManagerTests.swift`) — extend with failure injection for the D8 negative tests; no new fixture needed.
- `SyncingManagerPushReconciliationTests` already covers the "reconciles after initial sync / after resume / after requested discovery" wiring — D3 needs to UPDATE the "after requested discovery" assertion to reflect the count-gate.
- `MockPushNotificationRegistrarProvider` already exists for test wiring (used in `TestHelpers.swift`) — D10 graceful save covers the path where this isn't configured.

## Failure modes

For each new codepath, one realistic production failure + whether (1) a test covers it, (2) error handling exists, (3) user sees a clear signal.

| Codepath | Failure mode | Test? | Error handling? | User-visible? |
|----------|-------------|-------|----------------|---------------|
| `PushNotificationRegistrar.save` static | Called before `configure()` (UI test, extension, future lifecycle change) | Yes (D10 — bootstrap test + extension no-op test) | Yes — graceful log + return | Yes via `registrarConfigured: false` row on debug screen (Stack 2). Stack 1 alone: Datadog `Log.error` |
| `PushTopicSubscriptionManager.subscribe` | Network failure mid-reconcile | Yes (D8 — URLProtocol-stubbed failure path) | Yes — Log.warning + QAEvent + NO cache write | Partially — silent recovery on next reconcile. Stack 2 surfaces via `subscriptionSnapshot.lastRemoteApplyError` |
| Subscribe response `remoteApplied: false` (D16) | Backend returns 200 with `skipped: "no_push_token"` because device row has no token yet | Yes (Stack 2 backend tests + iOS contract test) | Yes — iOS doesn't write cache, next reconcile retries | Stack 2: `skipped` value displayed verbatim |
| `requestDiscovery` after D3 + D14 | Discovery throws after a partial result | Update existing tests; treat thrown discovery as `discovered=0` (conservative) | Yes — Log.error in catch | No (existing behavior) |
| `.convosPushTokenDidChange` listener (D14) | Listener task is cancelled mid-reconcile | Yes — add test that token change triggers exactly one reconcile call | Yes — Task cancellation cooperative | No |
| Debug status endpoint (Stack 2) | Backend 500 / network failure | Yes (iOS test against URLProtocol error) | Yes — surfaces in `DebugPushNotificationsViewModel.probeBackendStatus` as user-readable string | Yes — inline error row |
| Webhook with mismatched `client.accountId != device.accountId` (D15) | Old-account ClientIdentifier still routes a push at new-account device | Yes (backend integration test simulating account switch with stale rows) | Yes — drops the push, logs warning, returns 200 | No (silently NOT delivered, which is correct; debug screen would surface the warning trail) |
| NSE unregister via `nseAuthMiddleware` (D17a) | NSE JWT shape changes upstream | Add JWT-shape compatibility test | Yes — middleware rejects malformed; returns 401 | No (NSE bug class — invisible to user) |
| Snapshot cascade on `ClientIdentifier` delete | Cascade misfires; snapshot row orphaned | Yes (DB test) | Yes — `onDelete: Cascade` in Prisma | No |

**Critical gaps** (must fix before ship): none after Stack 1 + Stack 2 land as scoped. The combination of D8 success-only cache, D14 token-change trigger, D15 webhook accountId check, D16 remoteApplied contract, and D17 register reset closes every silent-failure path I identified.

## Worktree parallelization

| Step | Modules touched | Depends on |
|------|----------------|------------|
| **S1.1** AppDelegate static + graceful save (D2, D10) | `Convos/`, `ConvosCore/Inboxes/PushNotificationRegistrarProtocol.swift` | — |
| **S1.2** Debug button fix | `Convos/Debug View/` | — |
| **S1.3** Compute extraction (D7) | `ConvosCore/Syncing/PushTopicSubscriptionManager.swift` | — |
| **S1.4** Hash debounce + cache (D8 — partial without D16; finalize after Stack 2 lands) | `ConvosCore/Syncing/`, `ConvosCore/API/` | S1.3 |
| **S1.5** D3 count-gate + D14 token-change trigger | `ConvosCore/Syncing/SyncingManager.swift`, `ConvosCore/Device/` | S1.3 |
| **S1.6** ASCII diagrams (D9) | bundled with each step | each step |
| **S2.1** Prisma migration: snapshot model + ClientIdentifier.accountId (D4 + D13 + D15) | `../convos-backend/prisma/` | — |
| **S2.2** debug-status endpoint (D5) | `../convos-backend/src/api/v2/notifications/` | S2.1 |
| **S2.3** subscribe extension + idempotency (D6, D11, D13, D16) | `../convos-backend/src/api/v2/notifications/handlers/subscribe.ts` | S2.1 |
| **S2.4** register reset (D17b) | `../convos-backend/src/api/v2/device/handlers/register.ts` | S2.1 (uses ClientIdentifier.accountId column) |
| **S2.5** NSE unregister middleware (D17a) | `../convos-backend/src/api/v2/notifications/handlers/unregister.ts`, middleware/ | — |
| **S2.6** Webhook accountId check (D15) | `../convos-backend/src/api/v2/notifications/handlers/webhook.ts` | S2.1 |
| **S2.7** DebugPushNotificationsView (iOS) | `Convos/Debug View/`, `ConvosCore/API/` | S2.2 (endpoint exists) |

### Parallel lanes

**Stack 1 (single iOS worktree, sequential because all touch ConvosCore/Syncing):**
- Lane A1 (~30 min CC): S1.1 + S1.2 (parallel sub-steps — different files) → S1.3 → S1.4 + S1.5 (parallel — different files) → S1.6 as part of each. Land as a single PR.

**Stack 2 (5-lane parallel after S2.1 + S2.5):**

```
S2.1 (Prisma migration) ────┬──> S2.2 (debug-status endpoint)
                            ├──> S2.3 (subscribe extension)
                            ├──> S2.4 (register reset)
                            └──> S2.6 (webhook accountId check)

S2.5 (NSE unregister middleware) ──> independent, no dep on S2.1

S2.2 ──> S2.7 (DebugPushNotificationsView, iOS worktree)
```

After S2.1 lands (or in a single worktree with the migration first), spawn 4 sub-worktrees for S2.2, S2.3, S2.4, S2.6 (`isolation: "worktree"` since they touch overlapping middleware/util files). S2.5 runs in parallel with S2.1. S2.7 waits on S2.2.

### Conflict flags

- S2.3, S2.4, S2.6 may all touch a shared logger/audit helper — coordinate import-line conflicts; trivial.
- S2.2 and S2.7 both touch the iOS API client (`ConvosAPIClient.swift`) — sequence so S2.2 defines the response shape first.

## Implementation Tasks

Synthesized from the review's findings. Each task derives from a specific finding above. Run with Claude Code or Codex; checkbox as you ship.

### Stack 1 — iOS bug fixes

- [ ] **T1 (P1, human: ~1h / CC: ~10min)** — AppDelegate / Registrar — Replace injected `pushNotificationRegistrar` with `PushNotificationRegistrar.save(token:)` static; delete property on AppDelegate; delete assignment in `ConvosApp.init`.
  - Surfaced by: D2
  - Files: `Convos/ConvosAppDelegate.swift`, `Convos/ConvosApp.swift`
  - Verify: build; manual cold-launch on simulator confirms a single token-save log line.
- [ ] **T2 (P1, human: ~30min / CC: ~5min)** — Registrar — Make `PushNotificationRegistrar.save(token:)` graceful: log error and no-op when `_shared` is nil.
  - Surfaced by: D10
  - Files: `ConvosCore/Sources/ConvosCore/Inboxes/PushNotificationRegistrarProtocol.swift`
  - Verify: unit test asserts no fatalError when configure() hasn't run.
- [ ] **T3 (P1, human: ~30min / CC: ~5min)** — Debug View — Remove `let platformProviders = PlatformProviders.iOS` from `registerDeviceAgain()`; route through the configured providers.
  - Surfaced by: existing-code finding (line 402)
  - Files: `Convos/Debug View/DebugView.swift`
  - Verify: manual tap, confirm `PushNotificationRegistrar.token` is non-nil and unchanged across button press.
- [ ] **T4 (P1, human: ~2h / CC: ~20min)** — PushTopicSubscriptionManager — Extract `computeDesiredSubscriptions(kinds:params:)` private actor method; refactor `reconcilePushTopics`, `subscribeToGroupsAndWelcome`, `subscribeToInviteDMTopics` to use it.
  - Surfaced by: D7
  - Files: `ConvosCore/Sources/ConvosCore/Syncing/PushTopicSubscriptionManager.swift`
  - Verify: existing tests pass without modification.
- [ ] **T5 (P1, human: ~3h / CC: ~30min)** — PushTopicSubscriptionManager — Add hash debounce cache layer. Key: `environment + accountId + deviceId + clientId + apnsEnv + pushTokenSha256`. Write on success branch only. Clear on identity rotation.
  - Surfaced by: D8
  - Files: same; plus new `PushTopicSubscriptionCache.swift`
  - Verify: new tests for cache-hit-skips, cache-miss-sends, failure-doesn't-write, identity-rotation-clears.
- [ ] **T6 (P1, human: ~2h / CC: ~15min)** — SyncingManager — Change `discoverNewConversations` return type to `Int`; modify `requestDiscovery` to gate `reconcilePushSubscriptions` on count > 0.
  - Surfaced by: D3
  - Files: `ConvosCore/Sources/ConvosCore/Syncing/SyncingManager.swift`, existing test in `SyncingManagerPushReconciliationTests.swift` (asserts the new gated behavior)
  - Verify: existing reconcile-after-requested-discovery test UPDATED; new test simulates 10 polls with no new conversations and asserts exactly 0 subscribe calls.
- [ ] **T7 (P1, human: ~1h / CC: ~10min)** — Token-change trigger — Add `.convosPushTokenDidChange` listener that calls `reconcilePushSubscriptions(context: "after token change")`.
  - Surfaced by: D14
  - Files: `ConvosCore/Sources/ConvosCore/Device/DeviceRegistrationManager.swift` or `SyncingManager.swift` (whichever has cleanest lifetime; pick at implementation).
  - Verify: test that posting `.convosPushTokenDidChange` triggers exactly one reconcile call.
- [ ] **T8 (P2, human: ~30min / CC: ~5min)** — ASCII diagrams — Add inline diagrams at AppDelegate token receive, reconcilePushTopics, requestDiscovery decision.
  - Surfaced by: D9
  - Files: bundled with T1, T4/T5, T6
  - Verify: visual review.
- [ ] **T9 (P2, human: ~30min / CC: ~10min)** — Regression test for `.iOSExtension` PlatformProviders — assert `PushNotificationRegistrar.save(token:)` no-ops cleanly when invoked from the extension PlatformProviders setup.
  - Surfaced by: codex P2 future-footgun
  - Files: new test in `ConvosCoreTests/`
  - Verify: test passes.

### Stack 2 — Diagnostics + backend hardening

- [ ] **T10 (P1, human: ~3h / CC: ~30min)** — Prisma migration — `NotificationSubscriptionSnapshot` model (D4 + D13 fields) + `ClientIdentifier.accountId` column (D15) + backfill.
  - Surfaced by: D4, D13, D15
  - Files: `../convos-backend/prisma/schema.prisma`, new migration
  - Verify: migration runs on a copy of prod DB; backfill leaves no nulls for active accounts.
- [ ] **T11 (P1, human: ~4h / CC: ~45min)** — Subscribe handler — Add Zod-optional fields (`context`, `source`, `kindSummary`, `force`); accountId from JWT; idempotency check via snapshot at-apply fields; response `{ ok, remoteApplied, snapshot, skipped? }`; persist snapshot.
  - Surfaced by: D6, D11, D13, D16
  - Files: `../convos-backend/src/api/v2/notifications/handlers/subscribe.ts`
  - Verify: integration tests covering each branch in the test plan; assert response shape never has raw topics.
- [ ] **T12 (P1, human: ~3h / CC: ~30min)** — Debug-status endpoint — `POST /v2/notifications/debug/status`, JWT-gated, hashes-only, rate-limited 1/sec/JWT, scoped by JWT accountId+deviceId.
  - Surfaced by: D5
  - Files: `../convos-backend/src/api/v2/notifications/handlers/debug-status.ts`
  - Verify: negative test asserts response stringified body contains no raw token / no raw topic / no JWT.
- [ ] **T13 (P1, human: ~2h / CC: ~20min)** — Register reset on new token (D17b).
  - Surfaced by: D17b (codex P1)
  - Files: `../convos-backend/src/api/v2/device/handlers/register.ts`
  - Verify: test that auto-disabled device + new token = disabled:false, pushFailures:0.
- [ ] **T14 (P1, human: ~3h / CC: ~30min)** — NSE unregister middleware (D17a) — `nseAuthMiddleware` validates NSE JWT shape, reduced-privilege; mount on `/notifications/unregister`.
  - Surfaced by: D17a (codex P0)
  - Files: `../convos-backend/src/middleware/`, `../convos-backend/src/api/v2/notifications/handlers/unregister.ts`
  - Verify: test that NSE-shaped JWT succeeds at unregister; non-NSE-JWT fails.
- [ ] **T15 (P1, human: ~2h / CC: ~20min)** — Webhook accountId enforcement (D15) — drop deliveries where `client.accountId != device.accountId`; log structured warning.
  - Surfaced by: D15 (codex P0)
  - Files: `../convos-backend/src/api/v2/notifications/handlers/webhook.ts`
  - Verify: integration test simulating account-switch with stale ClientIdentifier row asserts no APNS call.
- [ ] **T16 (P1, human: ~2h / CC: ~20min)** — Webhook unknown-installation diagnostic — log structured warning when `installation.id` has no `ClientIdentifier`.
  - Surfaced by: original plan + D15
  - Files: same as T15
  - Verify: test asserts log structure.
- [ ] **T17 (P1, human: ~6h / CC: ~1h)** — DebugPushNotificationsView (iOS) — read-only local + backend state display; actions (probe, force reconcile, copy diagnostics); `registrarConfigured` row.
  - Surfaced by: original plan + codex P1
  - Files: `Convos/Debug View/DebugPushNotificationsView.swift`, `DebugPushNotificationsViewModel.swift`, `ConvosCore/API/ConvosAPIClient.swift` (add status method)
  - Verify: snapshot test of view at each state combination; copy-diagnostics output has no raw token.
- [ ] **T18 (P2, human: ~1h / CC: ~15min)** — iOS subscribe-API client — Add `force`, `context`, `source`, `kindSummary` parameters; parse `remoteApplied` + `skipped` from response; update D8 cache contract to write only when `remoteApplied`.
  - Surfaced by: D16 (closes Stack 1's T5 cache contract)
  - Files: `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`, `ConvosCore/Sources/ConvosCore/Syncing/PushTopicSubscriptionManager.swift`
  - Verify: test for `remoteApplied:false → no cache write`.
- [ ] **T19 (P2, human: ~1h / CC: ~15min)** — Hash canonicalization pin — add code comments in iOS + backend defining sorted UTF-8 / `\n` separator / SHA-256 hex lowercase; cross-link to each other.
  - Surfaced by: codex P2
  - Files: `PushTopicSubscriptionManager.swift`, `../convos-backend/src/notifications/hash.ts` (new helper)
  - Verify: cross-stack hash equality test (same topic set, same hex output).

### Stack 2 additions from broken-device validation

- [ ] **T11.5 (P1, human: ~30min / CC: ~5min)** — Add `accountId` to backend `Subscribing to topics` log line.
  - Surfaced by: broken-device validation; Datadog filters didn't have an accountId field, forcing us to look up deviceId via account first.
  - Files: `../convos-backend/src/api/v2/notifications/handlers/subscribe.ts`
  - Verify: a new `Subscribing to topics` entry in Datadog has an `accountId` field for filtering.
  - Independent of every other task; can ship as a one-line PR before T10 lands.
- [ ] **T20 (P1, human: ~2h / CC: ~30min)** — One-time orphan `ClientIdentifier` cleanup migration.
  - Surfaced by: broken-device validation found 24 orphan rows for one device, accumulated over 4 months. Cross-account variants are caught by T15 going forward; same-account orphans (the common case from identity rotations) are not.
  - SQL (Prisma migration):
    ```sql
    WITH ranked AS (
      SELECT "id", "deviceId", "updatedAt",
             ROW_NUMBER() OVER (PARTITION BY "deviceId" ORDER BY "updatedAt" DESC) AS rn
      FROM "ClientIdentifier"
    )
    DELETE FROM "ClientIdentifier"
    WHERE "id" IN (
      SELECT "id" FROM ranked
      WHERE rn > 1
        AND "updatedAt" < NOW() - INTERVAL '7 days'
    );
    ```
  - Optional follow-up: async job that calls `unregisterInstallation(clientId:)` on the XMTP notifications server for each deleted row so XMTP stops webhooking us. Without it, XMTP keeps sending us pushes for the deleted installations; backend silently drops them at the `ClientIdentifier`-not-found boundary (per T16 logging). Either way the device is unwedged.
  - Files: `../convos-backend/prisma/migrations/<timestamp>_orphan_cleanup/migration.sql`
  - Verify: pre-migration row count - post-migration row count = expected orphan reduction; spot-check that the most-recent row per device survived.
- [x] **T7.5 (P1, already in PR #908)** — NSE LibXMTP logging mitigation for `tracing-oslog` panic.
  - Surfaced by: broken-device validation; NSE crashed in `tracing-oslog-0.3.0/src/logger.rs:166` ("invalid span, this shouldn't happen") on physical iOS device when processing a 5+ envelope backlog.
  - Mitigation: disable LibXMTP file log writer + native log level setting in NSE on non-prod builds (shipped in Stack 1 PR #908).
  - Removal plan: once libxmtp pins a `tracing-oslog` version without the panic (or replaces the integration), revert the NSE block in `NotificationService.swift` to re-enable logging.
  - Upstream: filed with libxmtp; panic trace + libxmtp version `ios-4.10.0-nightly.20260528.6451ef9` + iOS device + "5+ envelopes in NSE" repro.

## Format gotcha: `installationId` != `clientId`

Documenting because this cost us a debugging cycle on the broken-device validation:

- **`installationId`** is the 64-char hex XMTP identifier. It's what iOS prints in the `welcome:<source>` topic log line (e.g. `welcome:75f19f4b933258d3f7755e118872f9bbd9ce54041a8f236cddce0aa3c5697b12`). It's also what the XMTP notifications server uses internally as the subscription key.
- **`clientId`** is a Convos-issued UUID (e.g. `9A430A09-C7E0-45FD-8F8A-5723A3DE9329`). It's what iOS sends in the body of `/v2/notifications/subscribe` and what backend stores as `ClientIdentifier.id`.
- The two are different strings tied to the same identity. When debugging "the subscribe call's target", the iOS topic log gives you the installationId; the backend DB row gives you the clientId. Don't try to match them as the same value.

## Open questions (remaining)

1. **`listSubscriptions` upstream RPC** — not tracked in repo (D18 skipped). Revisit if Stack 2 debug screen reveals investigations we couldn't close without it.
2. **Snapshot table retention policy** — table grows ~1 row per unique `clientId`. With D17a (NSE unregister) + cascade-on-delete + D17b (token rotation cleanup), the table self-prunes for active clients. Inactive clients (cold abandoned devices) accumulate slowly. Defer: revisit if row count exceeds 1M.

## Datadog queries to validate behavior

Repeated subscription source (should drop after Stack 1):
```
"Subscribing to topics" @clientId:<client-id>
```

After Stack 2 adds context:
```
"Subscribing to topics" @context:"after requested discovery"
```

After Stack 2 adds `skipped` log:
```
@skipped:"idempotent"
@skipped:"no_push_token"
@skipped:"disabled"
```

APNS delivery accepted:
```
"[APNS] Successfully sent v2 push notification" @deviceId:<device-id>
```

Webhook unknown installation:
```
"No ClientIdentifier for XMTP notification installation"
```

Webhook account mismatch (D15):
```
"client_account_mismatch" @clientId:<client-id>
```

Payload stripping secondary check:
```
"Payload exceeds strip threshold" @deviceId:<device-id>
```

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | not run |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 (via PI) | CLEAR | 14 findings surfaced; 5 P0/P1 cross-model tensions resolved into D13–D17; remaining wins folded |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 17 decisions (D1–D17) + 1 deferred (D18); 6 P0/P1 codex tensions absorbed; 0 unresolved |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | not run; Stack 2 has a new SwiftUI screen but Stack 1 is server-side-fix-only |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | not run |

**CODEX:** Outside voice surfaced 4 P0, 7 P1, 3 P2 findings. All P0 absorbed into D13 (snapshot at-apply correctness), D14 (token-change trigger), D15 (cross-account push prevention), D17 (NSE + register fixes). P1s either absorbed (D16 remoteApplied contract) or folded as unambiguous wins (accountId from JWT only, accountId in cache key, sign-out cache clear, register reset, Zod-optional rollout safety, D6 wording correction). P2s folded as code comments and one regression test (T9, T19).

**CROSS-MODEL:** Tensions on D4 (snapshot derivability), D3 (reconcile triggers), D8 (cache write contract), and Stack 1/2 ordering. Codex's analysis was correct in all four cases; original recommendations updated.

**UNRESOLVED:** 0 decisions. 2 open questions (listSubscriptions RPC, retention policy) explicitly deferred as not-blocking-ship.

**VERDICT:** ENG CLEARED (PLAN) — ready to implement Stack 1. Stack 2 implementation should wait until Stack 1 has been observed in Datadog for 24-48 hours.
