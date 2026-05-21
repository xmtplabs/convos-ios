# Plan — Batch-fetch catch-up on foreground, then resume streams

Stacks on top of `jarod/stream-write-storm-fixes` (#857). That PR cuts per-event cost in the stream catch-up path. This plan replaces the per-event catch-up *path itself* with a single batched fetch on foreground/cold-start, then lets the stream take over only for genuinely new events.

## Context

When the iOS app comes back to the foreground after time in background (or cold-launches), `SyncingManager.handleResume()` restarts libxmtp's `streamAllMessages` and `stream(type:.groups)`, then calls `syncAllConversations()`. Libxmtp replays the backlog as a sequence of stream events; iOS processes each one through `StreamProcessor.processMessage()` and `processConversation()` individually:

- One DB write transaction per message (and per conversation update).
- One GRDB observer fire per write → conversations-list and messages-list publishers re-emit per event.
- SwiftUI re-renders the conversations list once per backlog event — visible "replay" of message rows as they trickle in (the user has seen this).

The stream-write-storm-fixes PR cuts the *per-event cost*: read receipts skip the writer, no-op saves short-circuit, attestation cache memoizes, profile-image prefetch dedupes. The fan-out path itself is unchanged. Backlogs of 100+ events still produce 100+ writer invocations, 100+ observer fires, 100+ list re-renders.

## Goal

For backlogs that arrive while the app was backgrounded:

- **One** libxmtp call to discover which conversations changed
- **One** libxmtp call *per changed conversation* to fetch the message backlog
- **One** GRDB transaction that writes all conversations + all messages
- **One** observer fire at commit time
- Streams take over after the batch lands — they only deliver genuinely-new events that arrived during/after the batch fetch

Net effect: the user opens the app, sees the conversations list with correct latest-message previews instantly, then live updates flow as new messages arrive normally.

## Scope

**In scope**

- A new batch catch-up path triggered on `SessionStateMachine.handleEnterForeground()` (and cold launch) *before* `SyncingManager` resumes streams.
- Composing the existing libxmtp APIs (`list(lastActivityAfterNs:)`, `Conversation.messages(afterNs:)`) into a single transaction-wrapped write.
- A "stream gate" so streams that fire during the batch don't double-write events the batch is about to write.
- Plumbing the batch hook to **also** run `InviteCoordinator.processJoinRequestOutcomes(since:)` — DM-based join requests have the exact same backlog-replay problem and the batch primitive already exists; it's just never called on foreground.

**Out of scope**

- Push-notification-driven catch-up (already handled by the NSE).
- Real-time stream optimization beyond what already landed (covered by stream-write-storm-fixes).
- New schema columns. The plan uses per-conversation `max(DBMessage.dateNs)` as the implicit cursor — same signal `ConversationWriter.fetchAndStoreLatestMessages` already uses at line 696.
- Multi-inbox coordination (the iOS app has one primary inbox per identity; this is per-`XMTPClientProvider`).

## Design

### Trigger point

`SessionStateMachine.handleEnterForeground()` (ConvosCore/Sources/ConvosCore/Inboxes/SessionStateMachine.swift:771).

Current shape (paraphrased):

```swift
private func handleEnterForeground() async {
    await reconnectLocalDatabase()
    await syncingManager?.resume()        // ← streams restart here
}
```

New shape:

```swift
private func handleEnterForeground() async {
    await reconnectLocalDatabase()
    // Both catch-ups run in parallel against the same cursor.
    async let messages: () = batchCatchUp.run(client: ..., inboxId: ...)
    async let invites: () = inviteCoordinator.processJoinRequestOutcomes(since: cursorDate)
    _ = try await (messages, invites)
    await syncingManager?.resume()
}
```

The batch must complete (or fail with timeout) before streams resume. Streams already wait on `syncAllConversations` today; we're inserting one more await of comparable cost.

### Precedent: invite-join-request batch (and an existing cursor)

**Correctness note up front.** Two paths handle invite join requests today, and both are wired. **Adding the foreground batch path is a perf fix, not a correctness fix** — backlogged join requests already get processed on foreground via the stream's per-event handler.

| Path | Where | Cost shape |
|---|---|---|
| NSE-driven batch | `MessagingService+PushNotifications.swift:137` calls `processJoinRequestOutcomes(since: lastWelcomeProcessed)` | One batched fetch + sequential process |
| Foreground per-event stream | `StreamProcessor.processMessage:247-258` (DM case) calls `joinRequestsManager.processJoinRequestOutcome(message:, client:)` per-DM as libxmtp's `streamAllMessages` replays the backlog | One write per DM event |

If a push notification is dropped (notifications off, NSE killed, offline) and the app cold-launches, libxmtp's stream replays the backlogged DMs and the per-event handler processes them. There's an explicit reconcile comment at `InviteJoinRequestsManager.swift:125-133` documenting that subsequent sync passes heal any race-window gaps. The earlier QA pass (PR #857) verified the analogous behavior for group messages — 80 messages queued while iOS was killed all replayed on foreground via the stream.

This plan adds a **third** path: a foreground batch that runs `processJoinRequestOutcomes(since:)` *before* streams resume, so the user doesn't watch invite acceptances flicker in one-by-one. Same shape as the message batch.

The batch primitive — `InviteCoordinator.processJoinRequestOutcomes(since: Date?)` at ConvosInvites/Sources/ConvosInvites/InviteCoordinator.swift:186-209 — lists DMs with `lastActivityAfterNs:`, fetches each with `dm.messages(afterNs:)`, and processes them in sequence.

It is **already called in production** — but only from the NSE. `MessagingService+PushNotifications.swift:137` invokes it on every push-driven wake, reading and writing a per-inbox cursor in `UserDefaults`:

```swift
// MessagingService+PushNotifications.swift:969-979
private static let lastWelcomeProcessedKeyPrefix: String = "convos.pushNotifications.lastWelcomeProcessed"
private func getLastWelcomeProcessed(for inboxId: String) -> Date?
private func setLastWelcomeProcessed(_ date: Date?, for inboxId: String)
```

The foreground app **never** calls the **batched** `processJoinRequestOutcomes(since:)` and never reads or writes that cursor. On cold start / foreground-after-background, join requests still flow through `StreamProcessor.processMessage` → `joinRequestsManager.processJoinRequestOutcome` (the per-event variant) — correct but slow.

The fix shape:

1. The foreground hook reads the same `lastWelcomeProcessed` cursor on entry — the NSE may have already advanced it while the app was backgrounded, so we don't re-process events the NSE already handled.
2. The hook fans out to both coordinators (messages, invites) using that cursor.
3. After the batch completes, the hook writes back the new cursor, so the next NSE wake or next foreground sees a tight frontier.

Invite outcomes are idempotent (membership is already-added-or-not), so re-processing a request the stream also delivers is free — same property the message-PK dedup gives us on the message side.

The two coordinators stay separate types (different transactional shapes — invites mutate membership through libxmtp calls; messages write directly to GRDB), but they share the single foreground hook and the single cursor.

**Naming note:** the cursor is currently named `lastWelcomeProcessed` with a `pushNotifications.` prefix. Since the foreground path is about to read/write the same value, the right rename is `convos.catchup.lastProcessed.<inboxId>` (or a coordinated migration that reads-old / writes-new for one version). Out-of-scope for the implementation PR; flag for a follow-up.

### Cursor

Per conversation, the cursor is `SELECT MAX(dateNs) FROM message WHERE conversationId = ?`. For conversations that have never received a message locally, the cursor is 0 (fetch everything).

For the **global** "what conversations changed since last sync" call, the cursor is the max `dateNs` across all messages in the local DB:

```sql
SELECT MAX(dateNs) FROM message
```

This becomes `lastActivityAfterNs` for the `list(...)` call. New conversations the user wasn't in last session also surface here because libxmtp tracks them by membership-change time, not just message activity. (Confirm during implementation — fallback is to ALSO call `list(createdAfterNs:)` and merge.)

### The batch path

```swift
struct BatchCatchUp {
    func run(client: XMTPClientProvider, inboxId: String) async throws {
        let cursor = try await readGlobalCursor()                       // SELECT MAX(dateNs) FROM message
        let changedConversations = try await client.list(
            lastActivityAfterNs: cursor
        )
        guard !changedConversations.isEmpty else { return }

        var perConvMessages: [(XMTPiOS.Group, [DecodedMessage])] = []
        try await withThrowingTaskGroup(of: (XMTPiOS.Group, [DecodedMessage]).self) { group in
            for conv in changedConversations {
                group.addTask {
                    let perConvCursor = try await readPerConvCursor(conv.id)
                    let msgs = try await conv.messages(afterNs: perConvCursor)
                    return (conv, msgs)
                }
            }
            for try await pair in group { perConvMessages.append(pair) }
        }

        try await databaseWriter.write { db in
            for (conv, msgs) in perConvMessages {
                try writeConversation(conv, in: db)            // existing logic, no prefetch
                for msg in msgs {
                    try writeMessage(msg, conversation: conv, in: db)   // existing logic
                }
            }
        }
        // Single observer fire at commit
    }
}
```

Two non-trivial pieces:

1. **`writeConversation` inside a transaction.** Today's `ConversationWriter._store` is async (does XMTP `conversation.sync()`, metadata extract, etc.) and *not* invocable from inside a GRDB write closure. We have two options:
   - **Refactor `_store` to split "prepare model" (async) from "persist model" (sync inside transaction).** Bigger refactor but cleaner — the prepare step builds a `DBConversation` + members + profiles value, and the persist step is a pure transaction-scoped function. Stream path can use both phases sequentially; batch path runs all prepares in parallel then all persists in one transaction.
   - **Skip the per-conversation-sync step in the batch path** and only write what the `list(...)` payload already gives us. Cheaper, but risks stale metadata. Probably acceptable since the next stream tick will reconcile.
2. **Suppressing duplicate stream events.** When streams resume after the batch, libxmtp will likely re-deliver some events the batch just wrote. The diff short-circuit from PR #857 (`saveConversation` no-op skip) handles conversation rows. Messages have their own dedup via primary key (`DBMessage.id`); existing `messageWriter.store` uses `INSERT OR REPLACE` semantics. So duplicates are cheap, not duplicate-rendered. **No new gating logic needed.**

### What stays the same

- `StreamProcessor` for live events. Once streams resume, individual events still flow through `processMessage`. The batch path replaces *only* the backlog drain.
- All the writer-side optimizations from PR #857. They still apply when streams catch up on subsequent reconnects within a session.
- `syncAllConversations()` likely still fires from libxmtp during stream resume. Keep it — it's also doing libxmtp-internal state reconciliation.

## Implementation outline

1. **Refactor `ConversationWriter._store`** into `prepare(...)` (async) → `persist(_:in:)` (sync, takes `db`). Stream path uses `try await persist(prepare(...), in: db)`; batch path uses all-prepares-then-all-persists.
2. **Refactor `IncomingMessageWriter.store`** similarly. Most of its work is already sync inside `databaseWriter.write { db in ... }` — extract the in-transaction body as a `persist(_:conversation:in:)` method.
3. **Add `BatchCatchUp` actor** in `ConvosCore/Sources/ConvosCore/Syncing/`.
4. **Wire into `SessionStateMachine.handleEnterForeground`** ahead of `syncingManager?.resume()`, fanning out to (a) `BatchCatchUp.run` for group messages and (b) `InviteCoordinator.processJoinRequestOutcomes(since:)` for invite DMs. Both share the same cursor `Date`.
5. **Telemetry** — log `[PERF] catchup.batch.messages: <ms> convs=<n> messages=<n>` and `[PERF] catchup.batch.invites: <ms> requests=<n>` so we can compare against the current per-event timings.
6. **Tests:**
   - Unit test the batch coordinator with mock `XMTPClientProvider` and an in-memory writer.
   - Integration test: write N messages + M pending invites via CLI while iOS is backgrounded, foreground iOS, assert single PERF batch log line per path, assert no `Conversation save attempt` lines from stream during the catch-up window, assert join-request acceptances happen during the batch window not the stream window.

## Risks

| Risk | Mitigation |
|---|---|
| `list(lastActivityAfterNs:)` misses brand-new conversations (membership change without prior message activity in our local DB). | Also call `list(createdAfterNs:)` with the same cursor and merge. Confirm empirically during implementation. |
| `_store` refactor breaks existing stream path. | Refactor is purely structural (split async-prep from sync-persist), behavior preserved. Existing tests gate it. |
| Stream redelivery after batch double-writes. | Diff short-circuit (#857) makes conversation re-saves free; message `INSERT OR REPLACE` makes message re-writes free. Confirm via the integration test. |
| Batch takes too long on a huge backlog and blocks foreground. | Add a timeout (e.g. 5s); fall back to stream-driven catch-up if exceeded. Per-conv fetch parallelism caps wall-clock time at slowest-conversation time, not sum. |
| New conversations need profile prefetch / invite-generation side effects that `_store` does today. | The prepare/persist split keeps the side-effect calls in the stream path. Batch path runs them on a per-conversation basis *after* the transaction commits, off the foreground path. |
| `MAX(dateNs)` cursor is wrong if local DB has stale state. | Conservative: floor the cursor by `min(MAX(dateNs), Date().addingTimeInterval(-7 * 86400))` so we never reach back further than a week. |

## Open questions for the implementation PR

- Does `list(lastActivityAfterNs:)` return DMs too, or only groups? If groups-only, mirror with `Conversation.list(...)` for DMs and merge.
- Does the libxmtp `Conversation` returned by `list(...)` need an explicit `sync()` before `messages(afterNs:)`, or is the listing already current enough?
- Cold-launch first-ever foreground: cursor is 0, list returns everything, batch is the initial sync. Does this conflict with the existing `syncAllConversations()` call libxmtp does internally? Probably duplicates effort the first time. Acceptable for now.

## Verification plan

Reproduce the same QA scenario we ran for PR #857 (4 CLI senders, 80 messages + 80 read receipts while iOS is backgrounded, then foreground iOS), and compare:

| Metric | Current (PR #857) | After this plan |
|---|---|---|
| `Conversation save attempt` lines in first 30s | ~80 (one per message) | **1** (the batch write) |
| GRDB observer fires on conversations-repository | ~80 | **1** |
| SwiftUI list re-renders | ~80 | **1** |
| Total DB write transactions | ~80 | **1** |
| User-visible "message replay" effect | yes, mild | gone |
| Total catch-up wall time | proportional to N events | proportional to slowest-conv message fetch |

The first three metrics drop from O(N) to O(1) — the structural win this plan exists to deliver.
