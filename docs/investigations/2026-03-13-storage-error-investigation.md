# Investigation: "Error accessing the storage" — March 13, 2026

## Summary

A user encountered `"Error accessing the storage"` when trying to create a new conversation
at 15:00:05 UTC on March 13, 2026. Root cause: a conversation explosion deleted an inbox's
XMTP database file at 14:58:16 while the Notification Service Extension (NSE) had the same
file open in a separate process. A surviving third client instance for that inbox later tried
to use the deleted database, producing the storage error.

**Two bugs contributed:**

1. **Triple authorization** — Inbox `783cdf5a` was authorized three separate times at app
   launch, creating three independent `InboxStateMachine` instances for the same inbox. When
   the explosion triggered deletion, two machines deleted the database while the third still
   held a reference.

2. **Cross-process file deletion** — The main app deleted the `.db3` file while the NSE
   (a separate OS process) had active SQLCipher connections to it. The NSE's connection pool
   was not notified.

## Environment

- App version: 1.1.2, build 619, dev environment
- Device: iPhone 14 Pro (iPhone15,2)
- XMTP SDK: libxmtp v1.9.0
- SQLCipher: 4.6.1 community, OpenSSL 3.5.4
- Log bundle: `convos-logs-EC279E60`

## The Inbox

- **Inbox ID**: `783cdf5a29b9a29afc98cbf74ce19f68ca39bf6673acfaed04f5962fd79202e8`
- **Client ID**: `C9C4ED5A-52A4-4C42-9070-756BCC6E4AE2`
- **Installation ID**: `168bc6cd092e9482211d7f7f16bcbe581aceadd532e37dfb37b911bd4f41609a`
- **Conversation**: `a4149f3a141d2b7c51d6dbacdf5de6f3` (with profile name "Shane")
- **DB file**: `xmtp-grpc.dev.xmtp.network-783cdf5a...e8.db3`
- **Origin**: Created from unused conversation cache at 03:45:59, immediately consumed for
  a real conversation

## Detailed Timeline

### 14:51:44 — App launches, inbox authorized three times

The main app (PID 6394) creates **three** XMTP Client instances for inbox `783cdf5a`, each
opening the same `.db3` file. All three validate successfully.

```
# Client 1 — 14:51:44.571
[xmtpv3::mls] Creating message store with path: Some("/.../xmtp-grpc.dev.xmtp.network-783cdf5a...e8.db3")
[xmtp_mls::builder] ➣ Client created {inbox_id: "783cdf5a...", installation_id: 4f41609a, timestamp: ...637654000}

# Client 2 — 14:51:44.644
[xmtpv3::mls] Creating message store with path: Some("/.../xmtp-grpc.dev.xmtp.network-783cdf5a...e8.db3")
[xmtp_mls::builder] ➣ Client created {inbox_id: "783cdf5a...", installation_id: 4f41609a, timestamp: ...665569000}

# Client 3 — 14:51:44.982
[xmtpv3::mls] Creating message store with path: Some("/.../xmtp-grpc.dev.xmtp.network-783cdf5a...e8.db3")
[xmtp_mls::builder] ➣ Client created {inbox_id: "783cdf5a...", installation_id: 4f41609a, timestamp: ...987721000}
```

The convos-app.log confirms the triple authorization:

```
[14:51:44] Started authorization flow for inbox: 783cdf5a..., clientId: C9C4ED5A...
[14:51:44] Started authorization flow for inbox: 783cdf5a..., clientId: C9C4ED5A...
[14:51:44] Started authorization flow for inbox: 783cdf5a..., clientId: C9C4ED5A...
```

This is the first bug — the same inbox should only be authorized once. The likely cause is
that the unused conversation cache still had `783cdf5a` in its keychain entry (from before the
inbox was consumed for a real conversation), so both the normal inbox loader and the unused
cache independently authorized it, plus a duplicate from one of those paths.

### 14:51:47 — NSE opens the same database (separate process)

Three seconds later, a push notification arrives. The NSE (PID 6396) creates its **own** XMTP
Client for the same inbox, opening the same `.db3` file from a separate OS process:

```
# NSE (PID 6396) — 14:51:47.541
[xmtpv3::mls] Creating message store with path: Some("/.../xmtp-grpc.dev.xmtp.network-783cdf5a...e8.db3")
[sqlcipher_connection] SQLCipher Database validated.
[xmtp_db::encrypted_store] Migrations successful
[xmtp_mls::builder] ➣ Client created {inbox_id: "783cdf5a...", installation_id: 4f41609a}
```

**At this point, four XMTP Client instances across two OS processes have independent
connection pools to the same SQLCipher `.db3` file.**

### 14:51:47–14:53:43 — Both processes actively use the database

The main app syncs conversation `a4149f3a`, publishes intents, processes commits.
The NSE syncs groups, queries commit logs, rotates key packages. Both write to the database.

```
# Main app — publishing intents
[14:51:46.494] ➣ Commit published successfully. {group_id: "df5de6f3", intent_id: 5, intent_kind: MetadataUpdate}

# NSE — syncing and processing
[14:51:52.248] [783cdf5a...] syncing group
[14:51:57.694] Key package rotation successful
```

### 14:54:00–14:58:10 — Five background/foreground cycles

The user rapidly switches away from and back to the app. Each cycle calls
`dropLocalDatabaseConnection()` then `reconnectLocalDatabase()` on the main app's XMTP
clients. The NSE's connection pool is unaffected by these calls — it stays open throughout.

```
BG1  14:54:00  →  FG1  14:56:18  (2m 18s in background)
BG2  14:56:33  →  FG2  14:57:18  (45s)
BG3  14:57:39  →  FG3  14:57:49  (10s)
BG4  14:58:10  →  FG4  14:58:11  (1s)
```

XMTP SDK logs `"released sqlite database connection"` for each background transition
(11 releases per cycle, one per inbox), and `"reconnecting sqlite database connection"`
for each foreground. All reconnections succeed through this period — the database is still
intact.

```
# BG1 releases (14:54:00, PID 6394 main app XMTP log)
[14:54:00.744505] released sqlite database connection
[14:54:00.744596] released sqlite database connection
[14:54:00.744723] released sqlite database connection
... (11 total)
```

### 14:58:15 — Conversation explodes

The user triggers an explosion on conversation `a4149f3a141d2b7c51d6dbacdf5de6f3`:

```
[14:58:15] Sending ExplodeSettings message with expiresAt: 2026-03-13 14:58:15 +0000
[14:58:16] ExplodeSettings message sent successfully
[14:58:16] [EVENT] conversation.exploded id=a4149f3a141d2b7c51d6dbacdf5de6f3
```

### 14:58:16 — Inbox deletion and NSE collision

The explosion triggers member removal, which triggers inbox deletion. **Simultaneously**,
the NSE receives the push notification for the explosion and processes it:

```
# Main app — processes the explosion
[14:58:16] Removed members from conversation a4149f3a...: ["41b70e79...", "783cdf5a..."]
[14:58:16] [EVENT] member.removed conversation=a4149f3a... count=2
[14:58:16] Denied exploded conversation to prevent re-sync
[14:58:16] Exploded conversation from list: a4149f3a...

# NSE — processes the SAME explosion as a push notification (interleaved in same log)
[14:58:16] [NotificationService] [PID: 6396] Starting notification processing
[14:58:16] [NotificationService] Processing notification
[14:58:16] [NotificationService] Dropping notification as requested
[14:58:16] [NotificationService] NotificationService instance deallocated

# Main app — starts deleting the inbox (all three InboxStateMachines)
[14:58:16] Deleting inbox for clientId: C9C4ED5A...
[14:58:16] Deleting inbox with clientId: C9C4ED5A...    ← Machine 1 (has initialized client)
[14:58:16] Stopping sync...
[14:58:16] Deleting inbox for clientId: C9C4ED5A...
[14:58:16] Deleting inbox with clientId C9C4ED5A... without initialized client...  ← Machine 2 (no client)
[14:58:16] Cleaning up all data for inbox clientId: C9C4ED5A...
[14:58:16] Found 1 conversations to clean up for inbox clientId: C9C4ED5A...
[14:58:16] Successfully cleaned up all data for inbox clientId: C9C4ED5A...
[14:58:16] Sync stopped
[14:58:16] Deleted inbox with clientId C9C4ED5A...
```

The delete flow for the machine with an initialized client calls
`client.deleteLocalDatabase()`, which the SDK implements by closing the connection pool and
deleting the `.db3` file. The machine "without initialized client" falls through to manual
file deletion via `FileManager.removeItem`. Both paths delete the `.db3` and
`.db3.sqlcipher_salt` files.

The XMTP SDK log confirms the release at this moment:

```
# PID 6394 XMTP log
[14:58:17.267337] released sqlite database connection
```

**The NSE's XMTP client (PID 6396) still has its own connection pool open to the
now-deleted file.** The NSE process was not terminated — its `CachedPushNotificationHandler`
singleton keeps the client alive. Its background workers (disappearing_messages,
pending_self_remove, key_package_cleaner) continue running.

### 14:58:17 — Final log before the database file is gone

```
[14:58:17] Deleted inbox 783cdf5a... with clientId C9C4ED5A...
```

### 14:58:18 — BG5 (final background)

Two seconds after the deletion, the remaining third client instance (which was not involved
in the delete — it was the third of the triple authorization) receives the background event:

```
[14:58:18] App entering background, pausing sync for clientId C9C4ED5A...
```

The SDK calls `dropLocalDatabaseConnection()` on this orphaned client. Since the file has
been deleted, this either no-ops or creates a new empty file.

### 15:00:01 — App foregrounds, reconnect finds empty database

The surviving third client instance reconnects:

```
# PID 6394 XMTP log
[15:00:01.974184] reconnecting sqlite database connection
[15:00:01.974392] reconnecting sqlite database connection
... (10 total reconnections across all inboxes)
```

The reconnection opens the file path. Either the file was recreated empty (by the orphaned
BG5 drop/reconnect cycle), or the NSE's connection pool flushed an empty WAL to the path.
In either case, the file exists but has **zero tables**.

### 15:00:02 — Every table is missing

Immediately after reconnecting, every SDK worker fails:

```
# PID 6394 XMTP log — all tables gone
[15:00:02.030] sync_welcomes failed: "no such table: refresh_state"
[15:00:02.042] TaskRunner worker error: "no such table: tasks"
[15:00:02.043] Failed to create conversation stream: "no such table: refresh_state"
[15:00:02.043] Failed to create message stream: "no such table: refresh_state"
[15:00:02.047] Failed to fetch expired key packages: "no such table: key_package_history"
[15:00:02.047] KeyPackageCleaner worker error: "no such table: identity"
[15:00:02.047] Failed to delete expired messages: "no such table: group_messages"
[15:00:02.047] Failed to get groups with pending leave: "no such table: groups"
```

The convos-app.log shows the sync failure:

```
[15:00:02] [error] syncAllConversations on resume failed: "no such table: conversation_list"
[15:00:02] [error] Failed to discover new conversations: "no such table: conversation_list"
```

Meanwhile, 9 other inboxes (with no NSE contention and no deletion) resume fine:

```
[15:00:02] [PERF] sync.resume_conversations: 189ms
[15:00:02] [PERF] sync.resume_conversations: 196ms
... (9 successes total)
```

### 15:00:05 — User opens New Conversation, hits the broken client

The unused conversation cache returns a `MessagingService` for the broken inbox. The
`ConversationStateMachine` tries to create a new XMTP group, but the database has no tables:

```
[15:00:05] Created for draft conversation: draft-F64AB96A...
[15:00:05] [error] Failed to save consumed inbox: identityNotFound("Data not found in keychain")
[15:00:05] [PERF] NewConversation.inboxAcquired: 138ms
[15:00:05] State changed from uninitialized to creating
[15:00:05] Inbox ready, creating conversation...
[15:00:05] [error] Failed state transition creating -> create:
    "[ClientError::Group] Client error: group create: Error accessing the storage."
```

The `identityNotFound` error confirms this is inbox `783cdf5a` — its keychain identity was
deleted at 14:58:16 as part of the inbox deletion, but the orphaned third client instance
still appeared to be in `.ready` state.

### 15:05:52 — NSE also sees corruption

Five minutes later, the NSE's background workers (still running in PID 6396 against the same
file path) confirm the database is empty:

```
# PID 6396 NSE XMTP log
[15:05:52.748] Failed to delete expired messages: "no such table: group_messages"
[15:05:52.748] Failed to delete expired messages: "no such table: group_messages"
... (20+ repetitions)
```

## Root Causes

### Bug 1: Triple authorization of the same inbox

Inbox `783cdf5a` was authorized three times at 14:51:44, creating three independent
`InboxStateMachine` instances. When the explosion triggered deletion at 14:58:16:

- Machine 1 (initialized client): Called `client.deleteLocalDatabase()` — deleted the file
- Machine 2 (no client): Called `deleteDatabaseFiles()` via FileManager — deleted again
- Machine 3: Was not involved in the delete. Continued to hold a stale client reference.

Machine 3 survived the deletion, went through BG5/FG5, and its client tried to use a
database that no longer existed. This machine is also what the unused conversation cache
returned at 15:00:05.

**Likely cause**: The unused conversation cache's `clearUnusedFromKeychain()` call (which
logs at debug level, not captured) may have failed silently when the inbox was consumed for
a conversation. This left `783cdf5a` in the keychain as both a real conversation inbox and
the "unused" inbox, causing both the normal inbox loader and the unused cache to authorize
it independently.

### Bug 2: Cross-process database file deletion

The main app deleted the `.db3` file at 14:58:16 while the NSE (PID 6396) had active
connections to it. Neither `client.deleteLocalDatabase()` nor `FileManager.removeItem()`
coordinates with other processes. The NSE was never notified that the file was deleted.

On Unix systems, deleting a file while another process has it open causes the file to remain
accessible to the existing file descriptors but become invisible in the filesystem. When the
NSE's connections are later closed or when the orphaned main-app client reconnects, a new
empty file is created at the same path.

## Recommendations

1. **Prevent triple authorization**: Add a guard to ensure each inbox ID is only authorized
   once per app launch. Deduplicate before creating `InboxStateMachine` instances.

2. **Coordinate cross-process database access**: Before deleting an inbox's database files,
   either:
   - Use a file coordination mechanism (e.g., `NSFileCoordinator`) to signal the NSE
   - Accept that the NSE may have stale connections and ensure `reconnectLocalDatabase()`
     validates table existence before reporting `.ready`

3. **Validate database health after reconnect**: In `handleEnterForeground`, after calling
   `reconnectLocalDatabase()`, run a lightweight query (e.g., `SELECT 1 FROM identity
   LIMIT 1`) before emitting `.ready`. If the query fails, transition to `.error` instead.

4. **Validate database health before `.ready` in unused cache**: The unused cache's
   `consumeInboxOnlyService` should verify the consumed service's database is functional
   before returning it.

5. **Guard inbox deletion against orphaned clients**: The deletion flow should locate and
   stop **all** `InboxStateMachine` instances for the target inbox, not just the one that
   received the `.delete` action.
