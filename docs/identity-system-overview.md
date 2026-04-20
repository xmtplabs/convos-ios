# Identity System Overview

This document describes how the Convos iOS identity system works after the single-inbox refactor (see [ADR 011](adr/011-single-inbox-identity-model.md)). It covers the shape of the system today, what changed from the previous per-conversation-inbox model, and the typical flows a new reader should understand before touching identity code.

## Before the refactor (per-conversation inbox model)

Each conversation had its own XMTP inbox. The app juggled N identities per device, N state machines, N installations. Classes:

- **`InboxLifecycleManager`** coordinated N inboxes, started/stopped each independently.
- **`InboxStateMachine`** — one per inbox, each with its own state, tasks, monitors.
- **`UnusedInboxCache`** pre-registered entire inboxes for fast new-conversation creation.
- Keychain stored many `KeychainIdentity` entries keyed by inboxId.
- Push notifications had to resolve which inbox owned a payload before processing.
- Invites carried per-inbox signing keys; joining a conversation minted a fresh identity.

The model was flexible but heavy: every new conversation was a new install on XMTP's side, every join was a new key pair, and teardown required sweeping many DBs + keychain entries.

## Now (single-inbox identity model — ADR 011)

One identity per install. One `MessagingService`. One state machine. Conversations are MLS groups inside that single inbox. Join-a-conversation becomes "add this inbox to an existing MLS group." Explode becomes "remove everyone and leave."

### Components

| Component | Role |
|---|---|
| **`KeychainIdentityStore`** | Single source of truth for the device's identity (inboxId + clientId + signing keys). `loadSync()` sync, `load()` async. |
| **`SessionManager`** | Process-wide coordinator. Owns the one-slot `OSAllocatedUnfairLock<MessagingService?>` cache. Entry points for every consumer. |
| **`AuthorizeInboxOperation`** | Sync-to-async bridge around the actor-based state machine. Cancellable `Task?` slot for in-flight authorization. Two factories: `.authorize(inboxId:)` (known identity) / `.register()` (fresh registration). |
| **`SessionStateMachine`** (actor) | Drives the inbox lifecycle. States: `idle → authorizing → authenticatingBackend → ready ↔ backgrounded → deleting / error`. Owns `SyncingManager`, `NetworkMonitor`, `AppLifecycle` observer. |
| **`FailedIdentityLoadOperation`** | Null-object for the keychain-read-failed branch. Reports `.error(err)` without spinning up a state machine or task. |
| **`MessagingService`** (protocol) | API surface for the rest of the app. Holds `authorizationOperation`, `sessionStateManager`, and `clientId`. Factory methods for writers and repositories. |
| **`UnusedConversationCache`** (actor) | Pre-creates an MLS *group* (not an inbox) so the first "new conversation" tap is already published. DB-backed (`DBConversation.isUnused = true`). Self-healing: rolls back DB row if post-publish setup fails. |
| **`CachedPushNotificationHandler`** | NSE-side cache keyed by `(inboxId, clientId)`. Invalidates on stale identity or 15-min age. |
| **`ClipIdentityBootstrap`** | App Clip entry that seeds the shared-app-group keychain so the main app skips onboarding. |
| **`LegacyDataWipe`** | One-shot migration: sweeps old per-inbox keychain entries + v1 DBs on first launch of the refactored app. |

### Architecture diagram

```
                      ┌──────────────────────────────────────────┐
                      │   Main App / App Clip / Push NSE         │
                      │   (ViewModels, SwiftUI, Intents)         │
                      └──────────────┬───────────────────────────┘
                                     │ messagingService()
                                     │ messagingServiceSync()
                                     ▼
                      ┌──────────────────────────────────────────┐
                      │           SessionManager                  │
                      │                                           │
                      │ OSAllocatedUnfairLock<MessagingService?>  │ ◀── one slot
                      │                                           │     per process
                      │ loadOrCreateService():                     │
                      │  ├─ identityStore.loadSync()              │
                      │  ├─ identity present  → authorize path    │
                      │  ├─ identity nil      → register path     │
                      │  └─ loadSync threw    → Failed null-obj   │
                      └─────┬────────────────────────┬────────────┘
                            │                        │
              ┌─────────────┘                        └────────────┐
              ▼                                                   ▼
    ┌──────────────────┐                              ┌────────────────────┐
    │ KeychainIdentity │                              │ UnusedConvoCache   │
    │     Store        │                              │    (actor)         │
    │                  │                              │                    │
    │ inboxId,         │                              │ Pre-creates MLS    │
    │ clientId,        │                              │ group; DB row with │
    │ signing keys     │                              │ isUnused = true    │
    └──────────────────┘                              └────────────────────┘

                      ┌──────────────────────────────────────────┐
                      │       MessagingService (protocol)         │
                      │                                           │
                      │  - authorizationOperation                 │
                      │  - sessionStateManager (actor-backed)     │
                      │  - clientId (stored, backend API uses it) │
                      │  - writers + repositories factories       │
                      └──────┬───────────────────────────────┬────┘
                             │                               │
                             ▼                               ▼
           ┌──────────────────────────────┐    ┌──────────────────────────────┐
           │  AuthorizeInboxOperation     │    │ FailedIdentityLoadOperation  │
           │  (sync→async bridge)         │    │  (null-object)               │
           │                              │    │                              │
           │  Cancellable Task? slot      │    │  holds: Error                │
           │  stateMachine: actor ref     │    │  currentState: .error(err)   │
           └────────────┬─────────────────┘    │  no task, no monitors        │
                        │                      └──────────────────────────────┘
                        ▼
           ┌──────────────────────────────────────────────────┐
           │       SessionStateMachine (actor)                 │
           │                                                   │
           │  State flow:                                      │
           │   idle                                            │
           │    │                                              │
           │    ├─► authorizing(inboxId) ┐                    │
           │    │                         │                    │
           │    └─► registering ──────────┤                    │
           │                               ▼                    │
           │                      authenticatingBackend        │
           │                               │                    │
           │                               ▼                    │
           │          ┌──────────────►  ready(result) ─────┐   │
           │          │                    ▲               │   │
           │          │                    │               │   │
           │          │                 backgrounded ◀─────┘   │
           │          │                                         │
           │          │  delete from any state → deleting      │
           │          │  throw from any transition → error     │
           │          └── enterForeground retries from error ──│
           │                                                   │
           │  Owns: SyncingManager, NetworkMonitor,            │
           │        AppLifecycle observer, identityStore ref   │
           └────────────────────┬─────────────────────────────┘
                                │ waitForInboxReadyResult()
                                ▼
                 ┌──────────────────────────────────┐
                 │       InboxReadyResult           │
                 │    { client, apiClient }         │
                 │                                  │
                 │  XMTPClientProvider (wraps       │
                 │  XMTPiOS.Client)                 │
                 └──────────────────────────────────┘


  NSE (push) path:                    App Clip path:

  NotificationService.swift           ConvosAppClipApp.init
         │                                   │
         ▼                                   ▼
  CachedPushNotificationHandler       ClipIdentityBootstrap
  (singleton, per-process)            seeds shared-app-group keychain
         │                                   │
         │ payload's clientId                ▼
         │ vs cached                   Main app install sees identity,
         ▼                             skips onboarding flow entirely
  PushNotificationServiceFactory
  builds a per-notification service
  (15-min TTL, LRU-style)
```

### Typical flow: user taps the app

1. `ConvosApp.init` builds `SessionManager` with the platform's `KeychainIdentityStore`.
2. First SwiftUI view calls `messagingService()` → `loadOrCreateService()` acquires the lock.
3. `identityStore.loadSync()` returns the saved identity (or nil on first launch).
4. If identity exists: `AuthorizeInboxOperation.authorize(inboxId:)` is constructed, which builds a `SessionStateMachine` in `.idle` state and enqueues `.authorize(inboxId)`.
5. State machine runs: `.idle → .authorizing → .authenticatingBackend → .ready`. Along the way it starts `SyncingManager`, registers app-lifecycle observation, and kicks off network monitoring.
6. `MessagingService` is cached and returned.
7. ViewModels call `waitForInboxReadyResult()` when they need an XMTP client; the state machine returns the cached `InboxReadyResult` once `.ready`.

### Typical flow: Delete all data

1. User confirms "Delete All Data" → `SessionManager.deleteAllInboxesWithProgress()` yields progress.
2. `tearDownInbox()`:
   - Cancels any in-flight `UnusedConversationCache` prewarm (awaits the task to unwind).
   - Holds the `cachedMessagingService` reference live (doesn't clear the slot yet).
   - Calls `existing.stopAndDelete()` → state machine routes to `handleDelete()`.
   - `handleDelete` runs `performInboxCleanup` (live-client path): unsubscribes welcome topic, unregisters installation, cleans DB rows, deletes identity, sweeps `xmtp-*.db3` files.
   - `identityStore.delete()` and `wipeResidualInboxRows()` run unconditionally.
   - Finally, the cached slot clears → next call fresh-registers.

### Typical flow: New conversation

1. ViewModel calls `sessionManager.addInbox()` (note: legacy name — now really "add a conversation").
2. `SessionManager.consumeUnusedConversationId` atomically flips an `isUnused=true` DB row to `false` and returns its id.
3. If the cache had one pre-prepared, you get an instant, already-published group. If not, the ViewModel creates a fresh group on demand.
4. Either way, a fresh prewarm is kicked off in the background for the next tap.
