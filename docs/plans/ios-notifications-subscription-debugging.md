# iOS Push Notification Registration and Subscription Debugging Plan

## Problem statement

We can receive and decode a push on a clean simulator with the current iOS codebase, which makes a global APNS rejection less likely. The remaining failure modes are more likely around the state we maintain before delivery:

- the local APNS push token may not be registered in the backend,
- the backend may have a stale or missing `DeviceRegistration`,
- the current XMTP `clientId` may not be mapped to the current `deviceId`,
- the user may not be subscribed to the expected XMTP notification topics,
- the app may be repeatedly re-sending full topic subscription sets without knowing whether anything changed.

The debugging gap is that the backend does not currently persist the applied topic set, and the XMTP notifications server client generated in `../convos-backend/src/gen/notifications/v1/service_pb.ts` exposes only:

- `registerInstallation`
- `deleteInstallation`
- `subscribe`
- `subscribeWithMetadata`
- `unsubscribe`

There is no visible `listSubscriptions` or `getInstallation` RPC. As a result, the backend cannot currently answer "what is this installation actually subscribed to in the XMTP notification server?" It can only infer from calls that passed through our API.

This plan accounts for that limitation by distinguishing:

- actual remote subscription state in the XMTP notification server, which we cannot query today,
- last desired subscription state recorded by our backend when iOS called `/v2/notifications/subscribe`, which we can persist and debug.

## Current architecture

### iOS registration path

Relevant files:

- `Convos/ConvosAppDelegate.swift`
- `ConvosCore/Sources/ConvosCoreiOS/IOSPushNotificationRegistrar.swift`
- `ConvosCore/Sources/ConvosCore/Device/DeviceRegistrationManager.swift`
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`

Flow:

1. `ConvosAppDelegate.application(_:didFinishLaunchingWithOptions:)` calls `application.registerForRemoteNotifications()`.
2. APNS returns a token via `didRegisterForRemoteNotificationsWithDeviceToken`.
3. AppDelegate calls `pushNotificationRegistrar?.save(token:)`.
4. `DeviceRegistrationManager.registerDeviceIfNeeded()` posts to backend `/v2/device/register` with:
   - `deviceId`
   - `pushToken`
   - `pushTokenType = apns`
   - `apnsEnv = sandbox|production`
5. `DeviceRegistrationManager` stores `lastRegisteredDevicePushToken_<deviceId>` and `hasRegisteredDevice_<deviceId>` in UserDefaults after successful registration.

### iOS topic subscription path

Relevant files:

- `ConvosCore/Sources/ConvosCore/Syncing/PushTopicSubscriptionManager.swift`
- `ConvosCore/Sources/ConvosCore/Syncing/SyncingManager.swift`
- `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift`
- `ConvosCore/Sources/ConvosCore/Inboxes/MessagingService+PushNotifications.swift`
- `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift`

The manager computes subscriptions for:

- the inbox-wide welcome topic,
- group topics,
- invite DM topics.

It posts them to backend via `ConvosAPIClient.subscribeToTopics(deviceId:clientId:topics:)`.

Full reconciliation is currently called from:

- after initial sync: `SyncingManager.swift`, context `after initial sync`,
- after resume: `SyncingManager.swift`, context `after resume`,
- after requested discovery: `SyncingManager.swift`, context `after requested discovery`.

The join flow starts a discovery polling task:

- `ConversationStateMachine.swift` calls `sessionStateManager.requestDiscovery()` immediately,
- then calls it again every 3 seconds while waiting for the joined conversation to appear.

Since `requestDiscovery()` also reconciles push topics, a slow or stuck join flow can repeatedly post the full topic set to the backend. A Datadog log with `topicCount: 50` likely represents one full reconcile, not a loop over each topic.

### Backend registration path

Relevant files in `../convos-backend`:

- `src/api/v2/device/handlers/register.ts`
- `prisma/schema.prisma`

`/v2/device/register` upserts `DeviceRegistration`:

- `deviceId`
- `pushToken`
- `pushTokenType`
- `apnsEnv`
- `pushFailures`
- `disabled`
- `lastSentAt`
- `lastFailureAt`
- `accountId`

It also migrates `ClientIdentifier` rows if the same push token moves to a new device.

### Backend subscription path

Relevant files in `../convos-backend`:

- `src/api/v2/notifications/handlers/subscribe.ts`
- `src/api/v2/notifications/handlers/unsubscribe.ts`
- `src/api/v2/notifications/handlers/unregister.ts`
- `src/notifications/client.ts`

`/v2/notifications/subscribe`:

1. Parses `deviceId`, `clientId`, and `topics`.
2. Logs `Subscribing to topics` with `topicCount`.
3. Verifies JWT `deviceId` matches request `deviceId`.
4. Loads `DeviceRegistration`.
5. Calls XMTP notifications server:
   - `registerInstallation({ installationId: clientId, deliveryMechanism: pushToken })`
   - `subscribeWithMetadata({ installationId: clientId, subscriptions })`
6. Upserts `ClientIdentifier(clientId -> deviceId)`.

The backend does not store the topic list or topic hash after a successful subscribe.

### Backend delivery path

Relevant files in `../convos-backend`:

- `src/api/v2/notifications/handlers/webhook.ts`
- `src/api/v2/notifications/apns-push.service.ts`
- `src/api/v2/notifications/fcm-push.service.ts`

Flow:

1. XMTP notification server calls `/v2/notifications/xmtp`.
2. Backend receives webhook with `installation.id`.
3. Backend looks up `ClientIdentifier(id: installation.id)`.
4. Backend loads associated `DeviceRegistration`.
5. Backend builds payload and sends APNS/FCM.
6. Backend updates `pushFailures`, `lastSentAt`, `lastFailureAt`.

If APNS returns HTTP 200, backend logs:

- `[APNS] Push notification sent successfully`
- `[APNS] Successfully sent v2 push notification`

That proves Apple accepted the push. It does not prove iOS displayed it.

## Findings so far

### Repeated subscribe logs are explainable from current iOS code

The repeated `Subscribing to topics` logs are probably caused by iOS reconciliation, especially `requestDiscovery()` during join polling. The backend is not independently polling or looping. It responds to each iOS request.

The most suspicious path is:

1. User enters a join flow.
2. `ConversationStateMachine` starts discovery polling every 3 seconds.
3. Each `requestDiscovery()` calls `SyncingManager.requestDiscovery()`.
4. `SyncingManager.requestDiscovery()` calls `streamProcessor.reconcilePushSubscriptions(...)`.
5. `PushTopicSubscriptionManager.reconcilePushTopics(...)` sends the full topic set.
6. Backend logs `Subscribing to topics` with a high `topicCount`.

### Backend does not currently support topic-state debugging

Because there is no `listSubscriptions` RPC in the generated notifications client, the backend cannot query the actual remote XMTP notification server state.

Therefore, any debug UI must be explicit about what it shows:

- local desired topics calculated by iOS,
- backend last-seen desired topics received from iOS,
- not guaranteed actual remote XMTP notification server state.

### Existing debug device registration button may be misleading

`Convos/Debug View/DebugView.swift` currently has `registerDeviceAgain()` that creates a new `PlatformProviders.iOS` instance:

```swift
let platformProviders = PlatformProviders.iOS
```

That constructs a new `IOSPushNotificationRegistrar`, whose in-memory APNS token may be nil. A debug action can therefore register with a different local provider state than the real app is using.

The debug flow should use the app's existing `PlatformProviders` or the globally configured `PushNotificationRegistrar`, not create a new provider instance.

### AppDelegate token timing is a risk

`ConvosAppDelegate.didFinishLaunching` calls `registerForRemoteNotifications()` before `ConvosApp.init` assigns:

```swift
appDelegate.pushNotificationRegistrar = convos.platformProviders.pushNotificationRegistrar
```

If APNS returns quickly and `pushNotificationRegistrar` is nil, this line drops the token:

```swift
pushNotificationRegistrar?.save(token: token)
```

The token may be recovered later if `requestNotificationAuthorizationIfNeeded()` or another APNS registration call fires again, but this is a real race and should be fixed by buffering pending tokens in AppDelegate or moving registration after registrar assignment.

## Proposed solution

### Goals

1. Confirm from iOS debug UI that the local APNS token matches backend state.
2. Confirm the current `clientId` is mapped to the current `deviceId` in backend.
3. Record the last desired subscription set that passed through backend.
4. Reduce repeated full subscription calls from iOS.
5. Add enough context to Datadog logs to explain why a subscribe happened.

### Non-goals

- Do not claim we can query actual remote XMTP notification server topic state unless an upstream RPC is added.
- Do not expose raw APNS tokens in responses or logs.
- Do not expose raw topic names broadly in production diagnostics.

## Backend plan

### Add a push registration status endpoint

Add an authenticated endpoint, safe to call from the iOS debug menu:

```http
POST /api/v2/notifications/debug/status
```

Use `authMiddleware` so `res.locals.deviceId` comes from the JWT. The endpoint should verify that any requested `deviceId` matches the JWT deviceId. It can accept `clientId` and a local push token hash.

Request:

```json
{
  "clientId": "F33BD880-B607-4DC0-BE35-D8FF5B02C284",
  "pushTokenSha256": "hex sha256 of local APNS token",
  "pushTokenType": "apns",
  "apnsEnv": "production"
}
```

Response:

```json
{
  "device": {
    "deviceId": "...",
    "exists": true,
    "hasPushToken": true,
    "pushTokenMatches": true,
    "pushTokenType": "apns",
    "pushTokenTypeMatches": true,
    "apnsEnv": "production",
    "apnsEnvMatches": true,
    "disabled": false,
    "pushFailures": 0,
    "lastSentAt": "2026-05-28T...Z",
    "lastFailureAt": null,
    "updatedAt": "2026-05-28T...Z"
  },
  "client": {
    "clientId": "...",
    "exists": true,
    "mappedDeviceId": "...",
    "deviceIdMatchesJwt": true,
    "updatedAt": "2026-05-28T...Z"
  },
  "subscriptionSnapshot": {
    "exists": true,
    "topicCount": 50,
    "topicHash": "...",
    "lastContext": "after resume",
    "lastSubscribeAt": "2026-05-28T...Z",
    "lastRemoteApplySucceeded": true,
    "lastRemoteApplyError": null,
    "isActualRemoteState": false
  }
}
```

Important: return only comparisons and hashes for the APNS token. Never return the raw backend-stored token.

### Persist last desired subscription snapshot

Add a backend table or columns that record the last desired subscription set received from iOS.

Suggested table:

```prisma
model NotificationSubscriptionSnapshot {
  clientId                  String   @id
  client                    ClientIdentifier @relation(fields: [clientId], references: [id], onDelete: Cascade)
  deviceId                  String
  topicCount                Int
  topicHash                 String
  topicHashes               String[]
  kindSummary               Json?
  lastContext               String?
  lastSubscribeAt           DateTime @default(now())
  lastRemoteApplySucceeded  Boolean
  lastRemoteApplyError      String?
  pushTokenSha256AtApply    String?
  apnsEnvAtApply            ApnsEnvironment?
  pushTokenTypeAtApply      PushTokenType?
  createdAt                 DateTime @default(now())
  updatedAt                 DateTime @updatedAt

  @@index([deviceId])
  @@index([updatedAt])
}
```

Notes:

- `topicHash` is a stable hash of sorted topic strings.
- `topicHashes` can store per-topic hashes so iOS can compare its locally computed desired topics against the backend's last snapshot without the backend storing or returning raw topic strings.
- `kindSummary` can store counts such as `{ "welcome": 1, "group": 42, "inviteDM": 7 }` when the client sends topic metadata.
- `isActualRemoteState` in debug responses must be `false`, because this is the last desired state, not a remote read.

### Add subscription context to the subscribe request

Extend `/v2/notifications/subscribe` body with optional diagnostic fields:

```json
{
  "deviceId": "...",
  "clientId": "...",
  "topics": [...],
  "context": "after requested discovery",
  "source": "ios-main",
  "topicKinds": {
    "<topic>": "group"
  }
}
```

If sending raw topic-to-kind maps is too much, send only aggregate counts from iOS:

```json
{
  "context": "after requested discovery",
  "source": "ios-main",
  "kindSummary": "group=42,inviteDM=7,welcome=1"
}
```

Datadog logs should include:

- `context`
- `source`
- `topicCount`
- `topicHash`
- `sameAsPreviousSnapshot`
- `clientId`
- `deviceId`

### Add backend idempotency

If the same `clientId`, `deviceId`, `pushTokenHash`, `apnsEnv`, and `topicHash` are posted repeatedly within a TTL, backend can skip `registerInstallation` and `subscribeWithMetadata` and return 200.

This protects the XMTP notification server and makes repeated iOS calls less harmful.

Example policy:

- If snapshot hash matches and `updatedAt` is less than 10 minutes ago, skip remote apply.
- If APNS token changed, always re-apply.
- If `apnsEnv` changed, always re-apply.
- If previous remote apply failed, retry.
- If caller passes `force: true`, re-apply.

### Improve webhook diagnostics

In `src/api/v2/notifications/handlers/webhook.ts`, if no `ClientIdentifier` exists for `notification.installation.id`, log a structured warning before returning 200.

Fields:

- `installationId`
- `contentTopic`
- `messageType`
- `timestampNs`

This identifies pushes for stale or unregistered installations.

## iOS plan

### Fix APNS token buffering

Change `ConvosAppDelegate` so APNS tokens are not dropped if they arrive before `pushNotificationRegistrar` is assigned.

Suggested behavior:

- store `pendingDeviceToken: String?` in AppDelegate,
- when `pushNotificationRegistrar` is set, immediately save pending token,
- in `didRegisterForRemoteNotificationsWithDeviceToken`, if registrar is nil, store pending token and log it.

### Fix debug registration flow

Update `DebugView.registerDeviceAgain()` so it does not create a new `PlatformProviders.iOS` instance. It should use the configured global registrar or the existing app providers.

At minimum:

- use `PushNotificationRegistrar.token` for token display,
- force APNS registration with `UIApplication.shared.registerForRemoteNotifications()` before backend registration,
- wait briefly or refresh once token changes,
- use the same `DeviceInfo.deviceIdentifier` and shared registrar state used by the app.

### Add a Push Registration Probe screen

Add `DebugPushNotificationsView` linked from `DebugViewSection.pushNotificationsSection`.

Local state to display:

- notification authorization status,
- local deviceId,
- current keychain `clientId`,
- current inboxId,
- APNS env,
- bundle id,
- local APNS token present,
- local APNS token masked,
- local APNS token SHA-256,
- last local device-registration UserDefaults state.

Backend state to display from `/v2/notifications/debug/status`:

- device row exists,
- backend token present,
- backend token hash matches local token,
- APNS env matches,
- push token type matches,
- device disabled,
- push failure count,
- last sent/failure timestamps,
- client row exists,
- client row maps to this device,
- last desired subscription snapshot exists,
- last desired topic count/hash/context,
- remote actual state is unknown.

Actions:

- Request APNS token
- Force device register
- Probe backend registration
- Force topic reconcile
- Copy diagnostics JSON

### Add local desired-topic diagnostics

Refactor `PushTopicSubscriptionManager` so the topic derivation logic can be reused for diagnostics without necessarily sending to backend.

Add an internal/public diagnostics value, for example:

```swift
public struct PushTopicDiagnostics: Sendable {
    public let clientId: String
    public let deviceId: String
    public let topicCount: Int
    public let topicHash: String
    public let kindSummary: String
    public let topics: [Topic]
}
```

For debug UI, iOS can display local conversation names/ids mapped to topic hashes. Backend can return `topicHashes` from the last snapshot, and iOS can show:

- desired locally,
- present in backend's last requested snapshot,
- unknown actual remote state.

### Reduce repeated subscription calls

Add local no-op suppression in `PushTopicSubscriptionManager`:

- calculate sorted topic hash,
- key it by `environment + deviceId + clientId + apnsEnv + pushTokenHash`,
- store last successful hash/date/context in UserDefaults,
- skip backend subscribe if unchanged and fresh,
- allow force from debug UI,
- always send when token/device/client/env changes.

Also separate discovery from push reconciliation:

- `requestDiscovery()` should not always reconcile push topics,
- or it should call reconcile only if a discovery actually changed the conversation set,
- or it should debounce push reconcile to at most once per several minutes.

This directly targets the repeated Datadog subscription logs.

## Debug UI interpretation

Because the backend cannot query actual XMTP notification server topic state, the debug UI must label topic state clearly:

- `Local desired topics`: computed on-device now.
- `Backend last requested topics`: persisted by our backend from the last subscribe call.
- `Actual XMTP notification server topics`: not queryable with current RPCs.

Example UI copy:

> Backend snapshot is the last topic set iOS asked the backend to apply. The XMTP notification server does not expose a read/list API in our generated client, so this is not a live remote read.

## Suggested implementation order

1. iOS: buffer APNS token in AppDelegate.
2. iOS: fix debug device registration to use the real registrar.
3. Backend: add `/v2/notifications/debug/status` for device/client/token matching.
4. iOS: add `DebugPushNotificationsView` showing local vs backend registration state.
5. iOS: add `context` to subscription request body.
6. Backend: log `context`, `topicHash`, and repeated snapshot status.
7. Backend: persist subscription snapshots.
8. iOS: show local desired topic hash/count vs backend last snapshot.
9. iOS/backend: add idempotency and debounce to reduce repeated subscribe calls.
10. Backend: log unknown webhook installation ids.

## Acceptance criteria

- From the iOS debug menu, an engineer can tell if the local APNS token matches backend state.
- From the iOS debug menu, an engineer can tell if the current `clientId` is registered and mapped to the current `deviceId`.
- From the iOS debug menu, an engineer can see local desired topic count/hash and backend last requested topic count/hash.
- The UI clearly says actual XMTP notification server subscription state is not queryable today.
- Datadog subscribe logs include the iOS context that caused the subscription.
- Repeated `after requested discovery` calls do not repeatedly call `subscribeWithMetadata` with the same topic hash.
- A stuck join flow no longer floods `/v2/notifications/subscribe` every 3 seconds.
- Backend logs unknown webhook installation ids so stale subscription deliveries are visible.

## Datadog queries to validate behavior

Repeated subscription source:

```text
"Subscribing to topics" @clientId:<client-id>
```

After adding context:

```text
"Subscribing to topics" @context:"after requested discovery"
```

APNS delivery accepted:

```text
"[APNS] Successfully sent v2 push notification" @deviceId:<device-id>
```

Unknown webhook install ids after adding log:

```text
"No ClientIdentifier for XMTP notification installation"
```

Payload stripping secondary check:

```text
"Payload exceeds strip threshold" @deviceId:<device-id>
```

## Open questions

1. Can the XMTP notifications server add a read/list subscriptions endpoint?
2. Are raw XMTP topic strings acceptable to store in a short-retention debug table, or should we store only hashes?
3. Should debug status endpoints be non-production only, or production-safe behind normal user auth with no raw secrets?
4. What TTL should backend idempotency use for identical subscription snapshots?
5. Should iOS force a reconcile after every APNS token change even if topic hash is unchanged? The likely answer is yes.
