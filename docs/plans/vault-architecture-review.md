# Vault Architecture Review

Analysis of structural risks in the vault system, with concrete recommendations.

## Current Architecture

```
SessionManager
  ├── VaultManager (actor)
  │     ├── VaultClient (actor) — XMTP connection, vault group streaming
  │     ├── KeySharing — GRDB observation → share keys via vault group
  │     ├── Pairing — invite creation, PIN exchange, emoji verification
  │     └── Archive — create/import XMTP archives
  ├── VaultImportSyncDrainer (actor) — wakes imported inboxes sequentially
  └── NotificationCenter — glue between VaultManager and SessionManager
```

## Problem Areas

### 1. NotificationCenter as the integration bus

VaultManager communicates with SessionManager via 7 notification names (`vaultDidImportInbox`, `vaultDidReceiveKeyBundle`, `vaultDidDeleteConversation`, `vaultPairingError`, `vaultDidReceivePin`, `vaultDidEnterBackground`, `vaultWillEnterForeground`). This creates several problems:

- **No compile-time safety.** Notification userInfo dictionaries use string keys (`"inboxId"`, `"clientId"`, `"importedCount"`) with force-casts. A typo or type mismatch fails silently at runtime.
- **Invisible data flow.** Tracing how a key bundle import triggers a sync drain requires searching for notification name usage across files. There's no function call chain to follow.
- **Fire-and-forget semantics.** The sender has no way to know if the receiver processed the message, or if anyone is listening at all. If SessionManager hasn't set up its observers yet (race during init), notifications are lost.
- **Mixed concerns.** Some notifications carry domain data (imported inbox IDs), while others are lifecycle signals (enter background). They use the same mechanism with no type distinction.

**Recommendation:** Replace domain notifications with a `VaultEventDelegate` protocol on SessionManager. Keep only the system lifecycle notifications (background/foreground) as NotificationCenter since those originate from UIKit.

```swift
protocol VaultEventHandler: AnyObject, Sendable {
    func vaultDidImportInbox(inboxId: String, clientId: String) async
    func vaultDidImportKeyBundle(inboxIds: Set<String>, count: Int) async
    func vaultDidDeleteConversation(inboxId: String, clientId: String) async
}
```

VaultManager holds a weak reference to the handler. SessionManager conforms. Direct async calls replace notification posts. The compiler enforces the contract.

### 2. VaultManager is a god object

VaultManager is ~350 lines in the main file plus 3 extensions (~200, ~180, ~60 lines). It handles:
- XMTP connection lifecycle
- Vault group bootstrap
- Device management (list, add, remove, sync to DB)
- Key sharing (observe GRDB, share individual keys, share all keys, import bundles, import shares)
- Pairing initiation (create invite, DM streaming, PIN exchange)
- Pairing joining (send join request, joiner DM/poll streaming)
- Conversation deletion broadcast
- Archive create/import
- Delegate callbacks from VaultClient

The existing tech debt doc (item 5) already identifies this. The risk is that every new vault feature (backup restore, device management UI, conflict resolution) adds more to this actor, making it harder to reason about state transitions and harder to test in isolation.

**Recommendation:** Extract three internal actors that VaultManager delegates to:

- `VaultKeyCoordinator` — GRDB observation, key sharing, key import, bundle import. Owns `inboxesBeingShared` state.
- `VaultPairingSession` — all pairing state for a single session (invite, DM streams, slug tracking). Created on demand, discarded after pairing completes/fails. Replaces the mutable `activePairingSlug`, `dmStreamTask`, `joinerDmStreamTask`, `pendingPeerDeviceNames` fields scattered across VaultManager.
- `VaultDeviceManager` — device list, sync to DB, add/remove members, name resolution from messages.

VaultManager becomes a thin coordinator (~150 lines) that creates these on demand and routes VaultClient delegate callbacks.

### 3. VaultImportSyncDrainer is sequential and fragile

The drainer processes inboxes one at a time with a 30s timeout + 3s settle per inbox. For N inboxes, worst case is N × 33 seconds. We already hit this in QA: 3 timeouts consumed 90 seconds, blocking newer inboxes.

The fixes we just made (retry + priority preemption) help, but the fundamental design issue remains: the drainer is a serial queue that blocks on XMTP network calls.

**Problems:**
- Serial execution means total sync time grows linearly with inbox count.
- The `perInboxTimeout` of 30s is a guess. XMTP's `waitForInboxReadyResult()` may need more or less depending on history size.
- `settleDelay` (originally 8s, now 3s) is an arbitrary pause to "let things settle" — it's unclear what it's waiting for.
- On failure, we either retry immediately (same conditions, likely same timeout) or give up.

**Recommendation:** Replace the serial drain loop with a concurrent work pool:

```swift
actor VaultImportSyncDrainer {
    private let maxConcurrent = 3  // wake up to 3 inboxes at once

    private func drain() async {
        while true {
            let remaining = pendingInboxIds.subtracting(syncedInboxIds)
            guard !remaining.isEmpty else { break }

            let batch = await fetchAndSortByActivity(inboxIds: remaining)
            guard !batch.isEmpty else { break }

            await withTaskGroup(of: Void.self) { group in
                var inflight = 0
                for inbox in batch {
                    if inflight >= maxConcurrent {
                        await group.next()  // wait for one to finish
                        inflight -= 1
                    }
                    group.addTask { await self.syncOneInbox(inbox) }
                    inflight += 1
                }
            }
        }
    }
}
```

This cuts sync time by ~3x for the common case. Also replace the fixed `settleDelay` with an actual readiness check — if `waitForInboxReadyResult()` returns successfully, the inbox is ready; no additional sleep needed. The settle delay was likely papering over a race condition that should be fixed at the source.

For retry, use exponential backoff: retry after 5s on first failure, 15s on second, then give up. Don't retry immediately — if XMTP timed out, retrying instantly hits the same conditions.

### 4. No idempotency or crash recovery

If the app crashes or is terminated during the sync drain, all progress is lost. `syncedInboxIds` is in-memory only. On next launch, the drainer has no record of what was already synced. Depending on how the key bundle is stored, it may re-process the entire bundle or (worse) not re-process at all because the notification was already consumed.

Similarly, `sharedToVault` in the inbox table tracks which keys have been shared, but if the app crashes between sending the vault message and updating the DB, the key is shared but the flag isn't set — leading to duplicate shares (harmless but wasteful). The reverse (flag set but message not sent) means the key is never shared.

**Recommendation:**
- Persist sync drain progress to the database. Add a `vaultSyncState` column to the `inbox` table (enum: `pending`, `syncing`, `synced`, `failed`). The drainer reads `pending` and `failed` rows on launch. No notification needed to resume.
- Make key sharing idempotent. `importKeyShare` already guards on `hasIdentity` so re-processing is safe. But the initial bundle import should record which inboxes were imported so it can be resumed after crash.

### 5. Pairing has no error recovery path

If pairing fails at the "addingDevice" or "sharingKeys" step, the flow transitions to `.failed` and the user sees "Please try again." But the vault group may be in an inconsistent state:

- **addMember succeeded but shareAllKeys failed:** The new device is a member of the vault group but has no keys. It can receive future key shares but has no history. There's no mechanism to re-share the initial bundle.
- **addMember failed partway:** The XMTP group operation may have partially committed. There's no rollback.

**Recommendation:** Add a `VaultHealthCheck` that runs on launch:
- If the local device is in the vault group but has received no key bundles, request a re-share from the initiator (send a "key request" message to the vault group).
- If the vault group has members whose device names are unknown, sync device info.
- If `sharedToVault` flags are inconsistent with actual vault group messages, reconcile.

### 6. VaultClient has reconnection gaps

The vault group stream (`startStreaming`) has exponential backoff reconnection, but there's a gap between when the stream dies and when it reconnects. Messages sent during this gap are only caught by `processMissedMessages`, which uses `lastStreamDate` as the cutoff.

But `lastStreamDate` is only updated when messages are received or when streaming starts. If no messages arrive for hours and the stream silently disconnects, `lastStreamDate` could be stale. The missed message query might return a large batch or miss the window entirely.

**Recommendation:** Update `lastStreamDate` on each successful reconnection (not just on message receipt). Also add a periodic sync of the vault group (e.g., every 5 minutes while in foreground) as a safety net, similar to how the main conversation sync works.

### 7. Test coverage is thin for the integration layer

There are unit tests for `VaultManagerArchiveTests` (22 tests), `PairingCoordinatorTests`, and content type codecs. But the critical integration points are untested:

- GRDB observation → key sharing → vault message send
- Key bundle receive → identity save → drainer start → inbox wake
- Conversation deletion broadcast → receive → local deletion
- Crash recovery / resume after app restart
- Concurrent pairing attempts (second device tries to pair while first is in progress)

The existing tech debt doc (item 9) calls out integration tests. These should be prioritized because the vault system has the most complex state machine in the app and the most ways to fail silently.

## Priority Order

| Priority | Item | Status | Commit |
|----------|------|--------|--------|
| 1 | Concurrent sync drainer | ✅ Done | `025dab3a` |
| 2 | Crash recovery / DB persistence | ✅ Done | `025dab3a` |
| 3 | Replace NotificationCenter with delegate | ✅ Done | `025dab3a` |
| 4 | Split VaultManager | ✅ Done | `d0ff3403` |
| 5 | Pairing error recovery | ✅ Done | `f9ab50c7` |
| 6 | Integration tests | Deferred | Requires Docker/XMTP node |
| 7 | VaultClient reconnection hardening | ✅ Done | `12c82eac` |

## Non-Goals

- **iCloud keychain integration** — separate scope, different risk profile
- **Multi-vault support** — not on the roadmap
- **Conversation archive bundling** — handled by the restore orchestrator, not the vault layer
