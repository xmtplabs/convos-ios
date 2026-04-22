# MessagingService creation — simplification plan

## The bug the reviewer flagged

`SessionManager.messagingServiceSync()` can install a `MessagingService`
bound to `inboxId: ""` / `clientId: ""` into the shared service cache.
Any later caller — sync or async — sees the cache hit and returns the
broken service.

## What we actually want

A single-inbox app should have exactly one `MessagingService` per process
at a time, and constructing it should be serialized. The fix isn't "stop
caching empty-id services" — it's "make the construction path so simple
that there's no way to produce an empty-id service and no way for two
construction paths to race."

## Why the construction is currently async-looking

The async / sync split in `SessionManager` exists for exactly one reason:
`KeychainIdentityStore` is declared `public final actor`, so
`identityStore.load()` is `async` (actor methods are async from outside).
That forced `makeService()` to be `async`, which forced
`loadOrCreateService()` to wrap service construction in a
`Task<MessagingService, Error>`, which forced all the concurrency control
around `serviceState.creationTask` — cancellation, `awaiting` / `startCreating`
state branches, deinit teardown, and so on. Every bit of that machinery
is downstream of one actor-gated read.

Under the hood, the keychain read itself is **not** async. `SecItemCopyMatching`
is a synchronous call into the keychain daemon, which handles its own
concurrency. The `KeychainIdentityStore` actor isn't protecting any
mutable state of its own — `keychainService` and `keychainAccessGroup`
are `let`s set in `init`. The actor wrapper is pure ceremony.

## Fix

### Step 1: expose a sync keychain read

```swift
public protocol KeychainIdentityStoreProtocol: Actor {
    // existing members …
    nonisolated func loadSync() throws -> KeychainIdentity?
}

extension KeychainIdentityStore {
    public nonisolated func loadSync() throws -> KeychainIdentity? {
        let query = KeychainQuery(
            account: Self.identityAccount,
            service: keychainService,
            accessGroup: keychainAccessGroup
        )
        do {
            let data = try Self.loadKeychainData(with: query)
            return try JSONDecoder().decode(KeychainIdentity.self, from: data)
        } catch KeychainIdentityStoreError.identityNotFound {
            return nil
        }
    }

    // Private static helper equivalent to the current instance
    // `loadData(with:)` — lifted out so nonisolated code can call it.
    private static func loadKeychainData(with query: KeychainQuery) throws -> Data {
        // same body as the current instance method
    }
}
```

Same method on `MockKeychainIdentityStore`. The store stays an actor so
existing async callers keep working; the `nonisolated` accessor is an
additional legitimate API, not a workaround.

### Step 2: collapse service construction into one sync function

Every piece of service-building is inherently synchronous once `loadSync`
exists:

- `identityStore.loadSync()` — sync (keychain daemon)
- `AuthorizeInboxOperation.authorize(...)` / `.register(...)` — static
  factories; spawn their own internal tasks for state-machine drive,
  return immediately
- `MessagingService.init(...)` — sync

So the whole path can be one function:

```swift
private func buildMessagingService(for identity: KeychainIdentity?) -> MessagingService {
    let op: AuthorizeInboxOperation = identity.map { existing in
        .authorize(
            inboxId: existing.inboxId,
            clientId: existing.clientId,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            startsStreamingServices: true,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient
        )
    } ?? .register(
        identityStore: identityStore,
        databaseReader: databaseReader,
        databaseWriter: databaseWriter,
        environment: environment,
        platformProviders: platformProviders,
        deviceRegistrationManager: deviceRegistrationManager,
        apiClient: apiClient
    )
    return MessagingService(
        authorizationOperation: op,
        databaseWriter: databaseWriter,
        databaseReader: databaseReader,
        identityStore: identityStore,
        environment: environment,
        backgroundUploadManager: platformProviders.backgroundUploadManager
    )
}
```

No empty-id branch. Identity in keychain → `.authorize`. No identity in
keychain → `.register` (generates a `clientId`, drives the state machine
through onboarding, writes the keychain slot + DBInbox row as it lands
`.ready`). This mirrors exactly what the current async `makeService` does
— we're just doing it synchronously now that `loadSync` is available.

### Step 3: rewrite `loadOrCreateService` as a locked one-shot

```swift
private func loadOrCreateService() -> MessagingService {
    serviceState.withLock { state in
        if let existing = state.messagingService {
            return existing
        }
        let identity = try? identityStore.loadSync()
        let service = buildMessagingService(for: identity)
        state.messagingService = service
        return service
    }
}
```

The lock serializes everything. Two callers racing to build a service
now behave trivially: whichever takes the lock first builds + installs,
the second sees the cache hit. Only one `AuthorizeInboxOperation` —
and therefore only one state machine, only one `.register` — ever exists
for a given process lifetime.

### Step 4: public surface follows

```swift
public func messagingService() -> AnyMessagingService {
    loadOrCreateService()
}

public func messagingServiceSync() -> AnyMessagingService {
    loadOrCreateService()
}

public func addInbox() -> (service: AnyMessagingService, conversationId: String?) {
    let service = loadOrCreateService()
    let conversationId = Task {
        await unusedConversationCache.consumeUnusedConversationId(databaseWriter: databaseWriter)
    }
    // … see below on the async cache lookup
}
```

`messagingService()` drops `async throws`. `addInbox()` still needs `async`
because `consumeUnusedConversationId` is on an actor, but it no longer
`throws` — service construction can't fail. The two sync/async overloads
become equivalent; we keep both for now to avoid churning call sites,
and the duplication can go away in a follow-up sweep.

### Step 5: delete dead code

- `ServiceState.creationTask: Task<MessagingService, Error>?` — deleted
- `LoadAction` enum inside `loadOrCreateService` (with `.awaiting` and
  `.startCreating`) — deleted
- The `task.isCancelled → stop + throw CancellationError` branch
  (review fix commit `7fb3040b`) — obsoleted, deleted. Not a regression;
  there's no Task left to cancel.
- The `creationTask?.cancel()` in `deinit` (same commit) — obsoleted,
  deleted.
- `serviceState.creationTask?.cancel()` inside `messagingServiceSync`'s
  concurrent-install block (lines 392-400) — obsoleted, deleted.
  Construction is already serialized by the lock.
- Every `try await session.messagingService()` at call sites — becomes
  `session.messagingService()`. Every `try await session.addInbox()`
  becomes `await session.addInbox()`.

### Step 6: drop `async throws` from the protocol

```swift
public protocol SessionManagerProtocol: AnyObject, Sendable {
    func addInbox() async -> (service: AnyMessagingService, conversationId: String?)
    // deleteAllInboxes stays async throws — it actually awaits things
    func messagingService() -> AnyMessagingService
    func messagingServiceSync() -> AnyMessagingService
    // …
}
```

Mock conforms by just returning the mock service.

## New architecture

### Service construction

```
┌─────────────────────────────────────────────────────────────────────┐
│                         SessionManager                               │
│                                                                      │
│   messagingService()        messagingServiceSync()                   │
│   addInbox().service                                                 │
│           │                         │                                │
│           └──────────┬──────────────┘                                │
│                      ▼                                               │
│       ┌────────────────────────────────────────┐                    │
│       │      loadOrCreateService()             │                    │
│       │                                        │                    │
│       │   serviceState.withLock { state in     │                    │
│       │     if let existing { return existing }│ ◄── single writer   │
│       │     let id = identityStore.loadSync()  │ ◄── keychain sync   │
│       │     let svc = buildMessagingService(   │                    │
│       │       for: id)                         │                    │
│       │     state.messagingService = svc       │                    │
│       │     return svc                         │                    │
│       │   }                                    │                    │
│       └──────────────────┬─────────────────────┘                    │
│                          ▼                                          │
│       ┌────────────────────────────────────────┐                    │
│       │  buildMessagingService(for: identity?) │                    │
│       │                                        │                    │
│       │   identity != nil?                     │                    │
│       │     → AuthorizeInboxOperation          │                    │
│       │         .authorize(inboxId, clientId)  │                    │
│       │                                        │                    │
│       │   identity == nil?                     │                    │
│       │     → AuthorizeInboxOperation          │                    │
│       │         .register()                    │                    │
│       │                                        │                    │
│       │   → MessagingService(op, …)            │                    │
│       └────────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────────────┘

       Single entry point. Single lock. Single AuthorizeInboxOperation
       per process lifetime. No tasks, no cancellation, no races.
```

### Scenario walkthroughs

#### Fresh install / onboarding

Keychain empty, DBInbox empty, no iCloud restore.

```
App.init
  ▼
SessionManager.init
  └─ initializationTask: Task {
       prewarmUnusedConversation()
         ▼
       loadOrCreateService()
         ├─ lock acquired
         ├─ cache miss
         ├─ loadSync() → nil
         ├─ buildMessagingService(for: nil)
         │    → AuthorizeInboxOperation.register()
         │      (generates clientId, spawns internal task)
         │    → MessagingService(…)
         ├─ state.messagingService = service
         └─ lock released → return service

     Meanwhile, the AuthorizeInboxOperation's internal task drives:
       .idle → .registering → .authenticatingBackend → .ready
       handleRegister writes keychain slot + DBInbox row
     }

User later taps "Start a convo"
  → NewConversationViewModel → addInbox()
    → loadOrCreateService() → cache hit → existing service
      (by which point the state machine has reached .ready)
```

#### Existing account, warm relaunch

Keychain has identity X, DBInbox has row for X.

```
App.init
  ▼
SessionManager.init
  └─ initializationTask: Task {
       prewarmUnusedConversation()
         ▼
       loadOrCreateService()
         ├─ lock acquired
         ├─ cache miss
         ├─ loadSync() → X
         ├─ buildMessagingService(for: X)
         │    → AuthorizeInboxOperation.authorize(X.inboxId, X.clientId)
         │    → MessagingService(…)
         ├─ state.messagingService = service
         └─ lock released → return service
     }

User taps conversation row
  → ConversationsViewModel → ConversationViewModel.createSync
    → messagingServiceSync() → loadOrCreateService()
      → cache hit → return cached authorized service
```

#### iCloud restore (keychain has X, DBInbox empty)

This was the narrow poisoning window the reviewer flagged. After the fix
it's a non-event:

```
App.init
  ▼
SessionManager.init
  ├─ initializationTask: Task {
  │    prewarmUnusedConversation()
  │      → loadOrCreateService()     ← call A
  │  }
  │
  └─ Some main-thread caller hits messagingServiceSync
       → loadOrCreateService()        ← call B

     A and B both contend for serviceState lock.
     Whichever wins:
       ├─ acquires lock
       ├─ cache miss
       ├─ loadSync() → X  (from iCloud-restored keychain)
       ├─ buildMessagingService(for: X)
       │    → AuthorizeInboxOperation.authorize(X.inboxId, X.clientId)
       │    → MessagingService
       ├─ state.messagingService = service
       └─ releases lock

     The loser:
       ├─ acquires lock
       ├─ cache hit — returns the winner's service
       └─ releases lock

     Only one AuthorizeInboxOperation exists. No races.
```

No empty-id service is ever constructed. There's no branch in the code
that can produce one.

#### NSE path (CachedPushNotificationHandler)

Unchanged by this refactor. The NSE handler owns its own
`MessagingService` lifecycle separate from `SessionManager`'s cache,
caches one service tagged by `(inboxId, clientId)`, and rebuilds on
identity rotation (review fix `f8f05020`). That path doesn't interact
with `loadOrCreateService` at all.

## What this touches

- `ConvosCore/Sources/ConvosCore/Auth/Keychain/KeychainIdentityStore.swift`
  — add `loadSync`, refactor `loadData` to a static helper so nonisolated
  code can call it.
- `ConvosCore/Sources/ConvosCore/Auth/Keychain/MockKeychainIdentityStore.swift`
  — add `loadSync`.
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift` — collapse
  `makeService` + `loadOrCreateService` + `messagingServiceSync` into a
  single locked path; delete the task plumbing; drop `async throws` from
  `messagingService()`.
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManagerProtocol.swift` —
  update signatures.
- `ConvosCore/Sources/ConvosCore/Inboxes/MockInboxesService.swift` —
  conform to updated protocol.
- Every call site of `try await session.messagingService()` — drop the
  `try await`.
- Every call site of `try await session.addInbox()` — drop the `try`.

## Tests

- `ConvosCore/Tests/ConvosCoreTests/KeychainSyncConfigTests.swift` —
  add a `loadSync` round-trip test against the mock.
- `KeychainIdentityStoreTests/KeychainIdentityStoreTests.swift` (real
  keychain) — add `loadSync returns same identity as load`,
  `loadSync returns nil on empty slot`.
- New: `ConvosCore/Tests/ConvosCoreTests/SessionManagerServiceCreationTests.swift`
    1. Empty keychain → `messagingService()` returns a service whose
       `sessionStateManager` transitions through `.registering`.
    2. Keychain has identity X → `messagingService()` returns a service
       backed by `.authorize(X.inboxId, X.clientId)` (observable via
       `sessionStateManager.currentState` eventually matching X).
    3. Two concurrent callers (`async let a = session.messagingService();
       async let b = session.messagingService(); _ = await (a, b)`)
       return the same instance — lock serialization is correct.
    4. Sync + async mixed callers return the same instance.
    5. Post-construction, `state.messagingService` is populated with the
       service — no empty-id poisoning possible because no such path
       exists in the code.

Exposing `state` requires a `@testable internal` accessor on
`SessionManager`; minor.

## Commits

Single commit is too big — split into two for review clarity:

1. `KeychainIdentityStore: add nonisolated loadSync` — adds the accessor
   + tests, no SessionManager changes. Safe to ship on its own.
2. `SessionManager: collapse service creation into one locked path` —
   collapses makeService/loadOrCreateService/messagingServiceSync,
   deletes the creationTask plumbing, drops `async throws` from the
   public surface, updates all call sites.

## What this makes obsolete

- The `task.isCancelled → stop + throw CancellationError` branch we
  added in review fix `7fb3040b` (#4). There's no `Task` to cancel now.
  Not a regression — the new code has no need for that control flow
  at all.
- The `serviceState.creationTask?.cancel()` in `deinit` we added in the
  same commit (#5). Same reason.
- The concurrent-install compare-and-swap block at
  `messagingServiceSync` lines 392-400. Redundant under the new lock
  discipline.

None of these deletions regress review-feedback coverage; they address
the feedback by removing the code that caused the concerns in the first
place.

## Out of scope

- `deleteAllInboxes` auto-register-after-wipe. If the keychain is
  cleared and `messagingService()` is subsequently called before
  onboarding UI can intercept, we'll auto-register. The conversations
  list is empty in that state and the onboarding screen is presented,
  so this isn't reachable in practice — but worth a higher-level
  check (probably in the UI layer) in a follow-up.
- Making `KeychainIdentityStore` a plain thread-safe class instead of
  an actor. The actor is ceremony, but changing it cascades through
  every async caller.  Follow-up cleanup.
