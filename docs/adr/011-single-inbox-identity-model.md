# ADR 011: Single-Inbox Identity Model

> **Status**: Accepted (2026-04-19).
> **Supersedes**: [ADR 002 — Per-Conversation Identity Model](./002-per-conversation-identity-model.md).
> **Related**: [ADR 003 — Inbox Lifecycle Management](./003-inbox-lifecycle-management.md)
> (superseded, deleted subsystem), [ADR 004 — Explode Feature](./004-explode-feature.md)
> (amended: remove-all-then-leave), [ADR 005 — Member Profile System](./005-member-profile-system.md)
> (unchanged — per-conversation profiles retained).
> **Refactor plan**: [`docs/plans/single-inbox-identity-refactor.md`](../plans/single-inbox-identity-refactor.md).

## Context

Convos originally provisioned one XMTP inbox per conversation ([ADR 002](./002-per-conversation-identity-model.md))
to maximize cross-conversation identity isolation: every conversation had
its own keys, database, and gRPC streams, and a random `clientId` served as
a privacy-preserving push routing token so the backend never saw inbox IDs.
Strong on privacy, expensive in complexity:

- An LRU lifecycle manager capped concurrent inboxes at 20 and shuffled
  them through wake/sleep state transitions ([ADR 003](./003-inbox-lifecycle-management.md)).
- A pre-creation cache hid the 1–3s latency of registering a new inbox each
  time a user created or joined a conversation.
- Push routing, explode, onboarding, and profile UX each carried their own
  per-conversation coordination logic; the test surface was dominated by
  multi-inbox coordination scenarios that were correspondingly flaky.

The model also imposed user-facing friction (Quickname as a preset to
approximate a single identity across conversations, per-conversation
profile copies to keep display names consistent) without delivering
correspondingly strong privacy: a malicious peer in any one conversation
already sees the user's content in that conversation, and the `clientId`
indirection protects the *backend* from learning inbox IDs regardless of
whether there is one inbox or many.

The single-inbox refactor (`docs/plans/single-inbox-identity-refactor.md`)
consolidates to one inbox per user and deletes the coordination layer.

## Decision

Convos provisions **exactly one XMTP inbox per user**. That inbox's identity
material — the secp256k1 private key and the 256-bit database encryption
key — lives in a single keychain slot shared with the Notification Service
Extension and the App Clip. The `clientId` push routing indirection is
retained; only its cardinality changes (one per user instead of one per
conversation).

### 1. Identity storage

Keychain material:

- One entry in the app-group keychain, account key `single-inbox-identity`,
  service `org.convos.ios.KeychainIdentityStore.v3`.
- `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock` (relaxed from
  `…ThisDeviceOnly` to support sync).
- `kSecAttrSynchronizable = true` — the identity follows the user across
  their Apple ID devices via iCloud Keychain.
- Access group is the app-group identifier, shared with the NSE and the
  App Clip; no other code gains access.

The `KeychainIdentityStore` public API is `save`, `load`, `loadSync`
(nonisolated fast-path for `SessionManager`), and `delete`. The
multi-identity API (`loadAll`, `delete(inboxId:)`, etc.) and the old
`clientId`-keyed lookups were removed in C4a.

### 2. XMTP client configuration

One `XMTPiOS.Client` per user, constructed in `SessionStateMachine.clientOptions`
with:

- `deviceSyncEnabled: true` — a second device signed in under the same
  Apple ID (carrying the iCloud-synced identity) replays group memberships
  and message history from the XMTP history server.
- The full codec list (TextCodec, ReplyCodec, ReactionV2Codec, ReactionCodec,
  AttachmentCodec, RemoteAttachmentCodec, GroupUpdatedCodec,
  ExplodeSettingsCodec, InviteJoinErrorCodec, ProfileUpdateCodec,
  ProfileSnapshotCodec, JoinRequestCodec, AssistantJoinRequestCodec,
  TypingIndicatorCodec, ReadReceiptCodec).
- Local XMTP database at `xmtp-{env}-{inboxId}.db3` under the app-group
  container, encrypted with the per-install db encryption key from the
  keychain.

### 3. Push notification routing

The wire protocol is **unchanged from ADR 002 §3**: the backend sees only
a random `clientId`, ciphertext never leaves XMTP, and the NSE receives
the same v2 payload shape.

NSE-side routing is single-inbox:

- `CachedPushNotificationHandler` caches one `MessagingService` at a time,
  tagged with the `(inboxId, clientId)` it was built for, with a 15-minute
  stale-by-access TTL.
- On every delivery the handler reads the singleton identity, validates
  the payload's `clientId` against the stored `clientId`, and either
  delegates to the cached service (on match) or tears it down and rebuilds
  for the new identity (on mismatch — user signed out + in during the same
  NSE process). Mismatch + no identity at all both trigger a best-effort
  `apiClient.unregisterInstallation(clientId:)` so the backend stops
  routing to a clientId the device can no longer decrypt for.
- Identity-keyed cache tagging is the invariant proved by
  `CachedPushNotificationHandlerTests` — same identity reuses the cache,
  different identity forces a rebuild with `stop()` on the stale service
  before the new one is built.

### 4. Session lifecycle

`SessionManager.messagingService()` is a synchronous, lock-guarded
lookup under `OSAllocatedUnfairLock<MessagingService?>`. First call
synchronously loads the keychain identity via `loadSync()` and builds a
service (the `.authorize` path if an identity exists, `.register` if not);
subsequent calls return the same cached instance. The entire
async/Task-based plumbing from the multi-inbox era is gone — there are no
placeholder services, no creation-in-flight tasks, no awaited caches.

On wipe (explode of a conversation, or an error-state fallback) the
service is torn down; the next call rebuilds. The NSE and main app share
the keychain, so a main-app wipe of the keychain causes the NSE to drop
the next delivery and unregister its clientId.

### 5. Conversation explode

Deleting an XMTP inbox is no longer the deletion primitive (it would wipe
the user's entire account). Instead — see [ADR 004 C9 amendment](./004-explode-feature.md#single-inbox-amendment-c9-2026-04-16)
— the creator:

1. Sends the `ExplodeSettings` message to the group.
2. Removes every other member from the MLS group with
   `group.removeMembers(…)`.
3. Calls `group.leaveGroup()`.

Receivers drop the conversation locally on the `ExplodeSettings` message
*or* on the MLS "removed" commit, whichever arrives first. No keychain
material is touched. Cryptographic finality is lost — pre-refactor, inbox
destruction made group-key material unrecoverable on the creator's
device; now the guarantee is "messages are gone from the local database
on every participant that applied the commit."

### 6. App Clip handoff

The App Clip target declares the same `keychain-access-groups` as the main
app and instantiates `KeychainIdentityStore` against the same app-group
access group. The clip's first `SessionManager.messagingService()` call
registers the singleton identity and writes it into the shared slot. When
the user later installs the full app, its first launch finds that
identity already present — `makeService` takes the `.authorize` branch,
reuses the clip's inboxId, clientId, and key material, and skips the
onboarding carousel entirely.

### 7. Legacy data wipe

On first launch of the refactor build, `LegacyDataWipe` deletes all
pre-refactor state: the shared GRDB file, every `xmtp-{env}-*.db3` under
the app-group container, and the legacy `v1`/`v2` keychain service
entries. A `convos.schemaGeneration` marker in app-group UserDefaults
records that the wipe has run; it only fires once per generation. There
is no data-migration path; the refactor ships as a clean break.

## Consequences

### Positive

- **Simpler Swift layer.** `InboxLifecycleManager`, `UnusedInboxCache`,
  `SleepingInboxMessageChecker`, `InboxActivityRepository`, the pre-creation
  cache, per-conversation identity state machines, and the multi-inbox
  coordination tests are all deleted. `SessionManager` is a one-slot cache.
- **Standard XMTP model.** No diverging from the SDK's expected shape;
  device sync, history replay, and multi-device UX follow the protocol's
  native mechanisms.
- **Smaller test surface.** The flakiest integration suites (multi-inbox
  LRU, pre-creation timing, triple-inbox authorization) no longer exist.
  Post-refactor full-suite flake rate measured at 0 / 10 runs; see
  [`docs/plans/integration-test-stabilization-log.md`](../plans/integration-test-stabilization-log.md).
- **Consistent display identity.** Quickname is dropped as a preset
  because users no longer need a mechanism to approximate a single identity
  across inboxes — they just have one.

### Negative

- **No cross-conversation isolation.** A malicious peer in one conversation
  cannot see any other conversation's plaintext, but the peer (and any
  relay between the user's device and the XMTP network) observes one
  inbox ID across every conversation that user sends to. Compromising a
  single conversation means compromising the key material that secures
  every conversation.
- **No cryptographic finality on explode.** Deletion is a protocol-level
  request (remove + leave) rather than an unrecoverable cryptographic
  operation on local key material. See [ADR 004 C9 amendment](./004-explode-feature.md#what-doesnt-happen-in-the-new-flow).
- **Identity leaves the device via iCloud.** With `kSecAttrSynchronizable = true`,
  an attacker who compromises the user's Apple ID can obtain the identity.
  Acceptable under the new threat model (typical consumer-app expectation)
  but not compatible with the stricter device-binding claim ADR 002 made.

### Mitigations

- **Backend exposure is still just `clientId`.** The push-routing indirection
  is retained; the backend never learns the `inboxId`.
- **iCloud threat model is documented.** The plan's "Privacy properties we
  lose" section is the contract; no code path re-claims the stricter
  guarantee.
- **The NSE cache is identity-keyed.** An identity rotation mid-process
  can no longer hand B's delivery to A's cached `MessagingService`.

## Security Model

| Threat | Before (ADR 002) | After (this ADR) |
| --- | --- | --- |
| Backend learns user's XMTP identity | Protected — one `clientId` per conversation, never shared with backend | Protected — one `clientId` per user, still never shared with backend |
| Backend correlates user across conversations | Blocked by per-conversation `clientId` | **Unblocked** — single `clientId` per user |
| Peer compromise leaks cross-conversation content | Blocked by per-conversation keys | **Unblocked** — one key per user |
| Device theft (pre-unlock) reads messages | Blocked by `…ThisDeviceOnly` keychain | Blocked by `…AfterFirstUnlock` |
| Device theft (post-unlock) reads messages | Possible (as today) | Possible (as today) |
| iCloud account compromise leaks identity | Blocked — identity never left device | **Unblocked** — identity synced via iCloud |
| NSE serves stale cached service on identity rotation | N/A — NSE held a per-`clientId` map | Protected — `CachedPushNotificationHandler` invalidates on `(inboxId, clientId)` mismatch |
| Explode fails to remove ciphertext from peer devices | Cryptographic finality — peer can't read after inbox destruction | **Best-effort protocol removal** — peer drops on `ExplodeSettings` or MLS remove |

## Related Files

### Code

- `ConvosCore/Sources/ConvosCore/Auth/Keychain/KeychainIdentityStore.swift`
  — singleton identity store.
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift` — one-slot
  `MessagingService` cache.
- `ConvosCore/Sources/ConvosCore/Inboxes/SessionStateMachine.swift` — XMTP
  client options (device sync enabled).
- `ConvosCore/Sources/ConvosCore/Inboxes/CachedPushNotificationHandler.swift`
  — NSE-side identity-keyed service cache.
- `ConvosCore/Sources/ConvosCore/Inboxes/PushNotificationServiceFactory.swift`
  — narrow seam for NSE testability.
- `ConvosCore/Sources/ConvosCore/Storage/LegacyDataWipe.swift` —
  generation-gated one-shot wipe.

### Tests

- `CachedPushNotificationHandlerTests` — identity-keyed cache invariants.
- `SessionManagerServiceCachingTests` — one-slot cache + repeat-call
  identity preservation.
- `LegacyDataWipeTests` — generation marker + artifact removal.
- `AppClipIdentityHandoffTests` — clip → main-app identity reuse.
- `KeychainSyncConfigTests` — access attributes + sync flag.
- `IncomingMessageWriterExplodeTests` — receiver-side explode on
  `ExplodeSettings` / MLS-remove.
- `ExplodeRemoveAndLeaveTests` — sender-side explode call order
  (`sendExplode` → remove → `leaveGroup`, `denyConsent` fallback).
- `SessionStateMachineTests` — client options, single-inbox authorization.

## References

- [ADR 002 — Per-Conversation Identity Model](./002-per-conversation-identity-model.md) (superseded by this ADR)
- [ADR 003 — Inbox Lifecycle Management](./003-inbox-lifecycle-management.md) (superseded; subsystem deleted)
- [ADR 004 — Explode Feature](./004-explode-feature.md) (amended — C9 remove-all-then-leave)
- [ADR 005 — Member Profile System](./005-member-profile-system.md) (unchanged)
- [`docs/plans/single-inbox-identity-refactor.md`](../plans/single-inbox-identity-refactor.md) — the refactor plan, checkpoint breakdown, guiding decisions
- [`docs/plans/nse-cached-service-identity-validation.md`](../plans/nse-cached-service-identity-validation.md) — NSE cache identity-keying fix
- [`docs/plans/messaging-service-sync-cache-fix.md`](../plans/messaging-service-sync-cache-fix.md) — `SessionManager` sync/async collapse
- [`docs/plans/integration-test-stabilization-log.md`](../plans/integration-test-stabilization-log.md) — flake-rate evidence
- [`qa/tests/37-app-clip-handoff.md`](../../qa/tests/37-app-clip-handoff.md) — App Clip → main app QA test
