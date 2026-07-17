# NSE cached `MessagingService` identity validation

## Problem

`CachedPushNotificationHandler` caches a single `MessagingService?` for the lifetime of the NSE process (or until `maxServiceAge = 15min` elapses). The cache has no identity key — it's a one-slot cache keyed on "is anything present?".

Concrete failure case the review flagged (review comment on `CachedPushNotificationHandler.swift:54`, PR #713):

1. User A is signed in; NSE process wakes, delivery for A's inbox arrives.
2. `handlePushNotification` loads identity A, matches payload's `clientId` to `identity.clientId`, builds `MessagingService` for A, caches it.
3. User A signs out; user B signs in within seconds. The keychain slot is overwritten with B's identity (ADR 002 / C3 — single keychain slot, `KeychainIdentityStore.save` overwrites).
4. A delivery for B lands **in the same NSE process** before `maxServiceAge` (15 min) elapses.
5. `cleanupIfStale()` is a no-op (still fresh).
6. `identityStore.load()` returns B; `identity.clientId == payload.clientId` (both B) — validates fine.
7. `getOrCreateMessagingService(inboxId: B, clientId: B)` — `messagingService` is non-nil and gets returned unchanged. **The cached service is bound to A's client; B's message is decoded against A's MLS state.**

Depending on how MLS handles the decode attempt, this either decrypts to nothing visible, decodes the wrong ciphertext, or trips an internal `FfiError`. In no case does B see the right notification. The hotfix at commit `c8a600e3` added the `identity.clientId == payload.clientId` check earlier in the flow but did not touch the cache-lookup path — that's the piece that rebutts the "fixed" claim.

## Proposed fix

Tag the cached service with the `(inboxId, clientId)` it was built for. Invalidate on mismatch.

### Changes

- **`CachedPushNotificationHandler`**
    - Replace the separate `messagingService: MessagingService?` / `lastAccessTime: Date?` pair with a single private struct:
      ```swift
      private struct CachedService {
          let inboxId: String
          let clientId: String
          let service: MessagingService
          var lastAccessTime: Date
      }
      private var cached: CachedService?
      ```
    - `cleanupIfStale()` works off `cached?.lastAccessTime`.
    - `getOrCreateMessagingService(inboxId:clientId:overrideJWTToken:)` becomes an identity-aware lookup: if `cached` exists with matching `(inboxId, clientId)`, return its service; otherwise tear down the current cached service (if any) and build a fresh one tagged with the new identity.

- **Invalidation callsite**
    - Before building a new service on a mismatch, call `cached?.service.stop()` synchronously so XMTP stream teardown, `SyncingManager` shutdown, and any pending work from the prior identity are flushed before the new service touches its own state. The existing `cleanup()` method already does this — route the mismatch path through it.

- **Logging**
    - Add a single info-level log on the mismatch path: `"Identity rotated mid-process: tearing down cached service for <old-inboxId>, building for <new-inboxId>"`. This is rare enough that it's worth one log line if it ever fires in production.

### Test coverage

Landed in C13. `PushNotificationServiceFactoryProtocol` is a narrow
seam — `makeService(inboxId:clientId:overrideJWTToken:)` returning an
`any PushNotificationProcessing` — that `CachedPushNotificationHandler`
depends on instead of reaching for `MessagingService.authorizedMessagingService`
directly. Production uses the `PushNotificationServiceFactory` wrapper;
`CachedPushNotificationHandlerTests` injects a stub factory + mutable
clock to exercise:

- **Same identity across deliveries reuses the cached service** — stub
  factory made count stays at 1.
- **Different identity invalidates and rebuilds** — two calls with
  different `(inboxId, clientId)` produce two distinct stub services; the
  first is `stop()`-ed before the second is built.
- **Stale-by-age invalidates even on matching identity** — mutable clock
  advances past the 15-minute threshold; next call rebuilds.
- **ClientId-only mismatch still invalidates** — same inboxId, different
  clientId still forces a rebuild.

Test hooks (`_testInstance`, `_getOrCreateMessagingServiceForTesting`,
`_cleanupIfStaleForTesting`) are internal + underscored so they're
clearly not production API.

### What we deliberately don't do

- No cache expansion beyond one slot. The NSE still processes one identity at a time, just not always the *same* identity — the multi-slot cache from the pre-refactor world reintroduces the very LRU coordination problem C4 removed.
- No process-wide lock or actor promotion. The NSE is single-threaded enough that `CachedPushNotificationHandler` can stay a plain class; the invalidation is a simple compare-and-swap at the top of `getOrCreateMessagingService`.
- No change to the identity-mismatch unregister path in `handlePushNotification` — that already fires when the *payload* targets a clientId the keychain never held. The bug is specifically about the *cached-service's* identity drifting out from under a payload that passed the earlier identity check.

### Rollout

Ship as a follow-up commit to the C9/C10 work; does not require an ADR amendment because the routing contract (backend → clientId → NSE) is unchanged. Add the fix + the three unit tests in a single commit tagged `Fix NSE cached-service invalidation on identity rotation`.
