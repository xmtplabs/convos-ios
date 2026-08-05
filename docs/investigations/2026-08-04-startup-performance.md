# Startup Performance for Heavy Users - Investigation and Ranked Recommendations

Date: 2026-08-04
Scope: cold-start and foreground catch-up for heavy users (hundreds of conversations,
thousands of backlogged messages), plus conversation-list invalidation behavior during
those windows. Covers the app (ConvosCore + Convos targets) and libxmtp internals
(local checkout at `~/workspace/libxmtp`, same 4.12.0 line as the pinned
`ios-4.12.0-nightly.20260804.0f01ea1`).

## TL;DR

The hypothesis is confirmed on both fronts, with one important refinement each:

1. **Catch-up concurrency is unbounded, and it duplicates work libxmtp already does
   bounded.** `BatchCatchUp.prepareAll` spawns one task per conversation with no
   concurrency cap (`BatchCatchUp.swift:359`), and each task performs a full network
   `conversation.sync()` (`ConversationWriter.swift:265`). For N conversations that is
   up to N simultaneous group syncs contending on libxmtp's single SQLite writer.
   Meanwhile libxmtp's own `syncAllConversations` - which the app calls right
   afterwards anyway - does the same job with a batched "which groups changed" check
   and a fixed 10-way concurrency cap. The app runs the expensive unbounded shape
   first and the efficient bounded shape second.

2. **The conversation list does not thrash at the cell layer; it thrashes at the
   query/hydration layer.** The list query has no pagination and hydrates every
   conversation with its full association graph, the entire contact table, and an
   N+1 per-agent-conversation subquery - and the `ValueObservation` driving it has
   no `removeDuplicates`, no debounce, and a tracked region so broad that nearly any
   database write re-runs the whole thing. The UIKit diffable layer downstream is
   already well optimized, so the fix belongs in the repository, not the view.

The single highest-impact change is restructuring catch-up to "sync once via libxmtp,
then read locally with bounded concurrency" (recommendation R1). The best
effort-to-impact ratio is adding debounce + dedup to the list observation (R2), which
is a few lines. Full ranked list below.

---

## Part 1: What actually happens at boot

### 1.1 Boot sequence (cold start, existing identity)

All pre-first-frame work runs synchronously on the main thread in `ConvosApp.init`
(`Convos/ConvosApp.swift:24-165`): Sentry (`:55`), Firebase (`:85`),
`ConvosClient.client(...)` (`:108`) - which opens GRDB and runs migrations
synchronously (`DatabaseManager.swift:30-41`, `:85`) - and
`ConversationsViewModel.init` (`:127`), which primes the list via a bounded read that
blocks main for up to 50ms (`BoundedInitialRead.swift:49-70`).

The async session chain is strictly serial (`SessionManager.swift:156-204`):

```
registerDeviceIfNeeded()          network call, gates everything after it
  -> prewarmUnusedConversation()  builds the XMTP client (Client.build)
     -> SessionStateMachine.authorize
        -> authenticateBackend()  SIWE + App Check round trip, up to 3 retries
        -> handleAuthorized:
             runBatchCatchUp()          <- the heavy part, blocks .ready
             syncingManager.start()     <- streams + syncAllConversations
             emitStateChange(.ready)
```

(`SessionStateMachine.swift:819-845`; catch-up call at `:828`.)

The UI renders from the local DB before `.ready`, so the app is not visually blank -
but the catch-up storm saturates CPU, the libxmtp SQLite writer, and the GRDB reader
pool while the user is trying to scroll, which is what "unusable" looks like in
practice.

### 1.2 The catch-up fan-out (the core problem)

`runBatchCatchUp` (`SessionStateMachine.swift:1053-1066`) reads the cursor from
UserDefaults key `convos.pushNotifications.lastWelcomeProcessed.<inboxId>` - the same
key the NSE advances - and hands it to `BatchCatchUp.run`
(`ConvosCore/Sources/ConvosCore/Syncing/BatchCatchUp.swift:112`):

- `listGroups(lastActivityAfterNs: cursor)` - one FFI call. With a nil cursor
  (fresh install, pushes disabled, or NSE never ran) this returns **every**
  conversation.
- `prepareAll` (`BatchCatchUp.swift:353-400`) then fans out:

```swift
return await withTaskGroup(of: PreparedEntry?.self) { taskGroup in
    for group in groups {          // N groups -> N tasks, no concurrency bound
        taskGroup.addTask {
            try await Self.withTimeout(seconds: timeout) {   // 30s per conversation
                try await Self.prepareEntry(group: group, ...)
            }
        }
    }
    ...
}
```

- Each `prepareEntry` (`:402-448`) calls `conversationWriter.prepare`, whose first
  line is `try await conversation.sync()` (`ConversationWriter.swift:265`) - a
  network round trip per conversation - followed by metadata extraction, a member
  fetch, a DB cursor read, and `group.messages(afterNs:)`.

The only guard is the per-conversation 30-second timeout. There is no semaphore, no
window, no chunking. Elsewhere in the same codebase the equivalent loops are bounded:
`ConversationConsentReconciler` uses a 6-wide sliding window
(`ConversationConsentReconciler.swift:85`), and push-topic reconcile chunks at 100
topics per request (`PushTopicSubscriptionManager.swift:116`).

To BatchCatchUp's credit, the write side is already excellent: one big transaction
for all conversations and regular messages (`:167-176`), one cursor-advance
transaction (`:230-235`), supplementals in small per-type transactions, and side
effects on a detached background task. The problem is purely the prepare-phase
network fan-out.

**Answer to "how many tasks concurrently catch up for N conversations": up to N,
unbounded, each performing a network group sync - and the whole thing re-runs on
every foregrounding and every network reconnect** (`SessionStateMachine.swift:982`,
`:1488-1501`), followed each time by another `syncAllConversations` inside
`SyncingManager.resume()` (`SyncingManager.swift:760`).

### 1.3 What libxmtp does underneath (why the fan-out is redundant)

From the local checkout (`crates/xmtp_mls/src/groups/welcome_sync.rs`):

- `sync_all_welcomes_and_groups` (the FFI `syncAllConversations`) pulls welcomes
  serially, then makes **one batched** `get_newest_message_metadata(group_ids)` call
  and compares against local per-group cursors, so only groups with genuinely new
  server messages get synced (`welcome_sync.rs:219, 439`). Quiet groups are nearly
  free.
- Groups that do need sync are processed with a **fixed 10-way concurrency cap**
  (`sync_groups_in_batches(filtered, 10)`, `welcome_sync.rs:377-392`).
- `conversation.sync()` per group takes a per-group mutex, makes ~1-2 network round
  trips, and processes each message as **one SQLite write transaction** (MLS decrypt
  + cursor + insert; `mls_sync.rs:2321`). SQLite is WAL with a 25-connection pool,
  but WAL still means **one writer at a time** (`xmtp_configuration/src/common/db.rs`,
  `pool.rs:37-38`). Concurrent group syncs serialize at the writer; extra app-side
  concurrency buys decrypt CPU parallelism at best and lock contention at worst.
- Cold-boot extra: the per-group `maybe_update_installations` throttle (30 min) has
  always expired at boot, so every actively-synced group also issues per-member
  identity-update network queries (`mls_sync.rs:4066`) - a per-group-times-members
  network burst the app cannot see but pays for.
- libxmtp also ships `catch_up_to_live(timeout_ms)` (XIP-83 bounded bidi catch-up,
  `bindings/mobile/src/mls.rs:786`, `subscriptions/catch_up.rs`): one multiplexed
  stream over all owned topics from durable cursors, chunked so a large account gets
  a bounded first frame, with a timeout that returns a partial summary. The app does
  not use it (it is d14n-gated; the `XMTP_BIDI_STREAMS_ENABLED` env hook already
  exists at `ConvosApp.swift:45-48`).

So the net effect on a heavy cold boot: N unbounded app-side `conversation.sync()`
calls race each other into a single-writer SQLite funnel, then `syncAllConversations`
re-checks everything (cheaply, but still), then `discoverNewConversations`
(`SyncingManager.swift:569-613`) lists all groups again and - for any group missing
from the app DB - processes them **sequentially** with two awaited FFI calls per
group (`creatorInboxId()`, `members.count`). On a fresh install/pairing, where the
app DB is empty, that discover loop is the dominant cost: ~N sequential
per-conversation stores.

### 1.4 The stream path per-message cost

Once streams are live, every incoming group message runs
`StreamProcessor.processMessage` (`StreamProcessor.swift:231-340`), which calls
`conversationWriter.store(conversation:)` (`:285`) before storing the message.
`store` = `prepare` + persist, and `prepare` starts with `conversation.sync()` - so
**every streamed message triggers another network group sync plus a full
conversation/member reconciliation write, then a second write transaction for the
message itself, plus a possible third for unread state** (`:316`, `:328`). The no-op
diff short-circuit (#857) makes the conversation persist cheap when nothing changed,
but the sync round trip and the 2-3 write transactions per message remain. During a
stream burst this both floods the writer and (see Part 2) fires the list observation
per transaction.

## Part 2: The conversation list pipeline

### 2.1 The query: unpaginated, everything hydrated

`ConversationsRepository.composeAllConversations`
(`ConvosCore/Sources/ConvosCore/Storage/Repositories/ConversationsRepository.swift:147-204`)
fetches **all** non-draft, consented, non-expired conversations - no LIMIT anywhere
in the pipeline (verified: no limit/prefix/page machinery exists in the repository,
view model, or view controller). Per row, `detailedConversationQuery()` (`:311-375`)
loads: all invites, creator member with 5 nested optional joins (profile, avatar
slot, inviter identity, my-profile identity, inviter-my-profile identity), local
state, agent-builder summary, last message via CTE, latest agent join request via
CTE, and **all members** each with the same 5 nested joins. The two CTEs are cheap
(pointer-based PK lookups with substr-capped text, `DBConversation.swift:239-266`).

On top of the main query, each fire also runs:

- A **whole-contact-table read**: `contactNameResolverInTransaction` does
  `DBContact.fetchAll(db)` (`ContactsRepository.swift:265-274`), pulling every
  contact into a dictionary and adding `contact` to the tracked region.
- An **N+1 agent-DM fold**: for every conversation with a verified agent member, a
  full extra `composeOneToOne` detailed query runs inside the same transaction
  (`ConversationsRepository.swift:169-189`).

### 2.2 The invalidation storm

The publisher (`ConversationsRepository.swift:51-62`) is:

```swift
ValueObservation
    .tracking { db in try db.composeAllConversations(consent: consent) }
    .publisher(in: dbReader)
    .replaceError(with: [])
```

No `.removeDuplicates()`, no debounce, no throttle. The auto-tracked region is the
union of every table the read touches: conversation, message (via CTEs), contact,
conversation_members, profile, avatar slots, localState, invite,
agent_builder_summary, inbox. The message-insert trigger
`conversation_pointer_message_insert` (`SharedDatabaseMigrator.swift:439-448`)
updates `conversation.lastMessageId` on every eligible message insert, so **a single
message insert anywhere re-runs the entire compose**. During catch-up/stream bursts
- where the stream path produces 2-3 transactions per message and supplementals run
one small transaction each - the full query + full-contact read + N+1 fold + full
re-hydration re-executes per commit.

The sibling agent-template publisher in the same file added `.removeDuplicates()`
with a comment explaining exactly this hazard (`ConversationsRepository.swift:113-115`).
The main list publisher and the count publisher
(`ConversationsCountRepository.swift:15-25`) never got the same guard.

Multiplier: every `sink` on a ValueObservation publisher starts an independent
observation. `ConversationsViewModel` (`ConversationsViewModel.swift:638`) and
`ThingsOverviewViewModel` (`ThingsOverviewViewModel.swift:68`) both subscribe (and
`AgentDmPageView` adds another while open), so the full compose typically runs 2-3
times per fire. `ThingsOverviewViewModel` additionally holds one
`agentFilesLinksRepository` observation **per conversation** (`:84-92`).

### 2.3 The in-memory side

`ConversationsViewModel` receives the full `[Conversation]` on main and replaces the
array wholesale (`ConversationsViewModel.swift:644-646`), then re-runs
`ShareSuggestionDonator.donate` over the whole list per emission (`:648`). Because
the type is `@Observable`, derived properties (`pinnedConversations`,
`unpinnedConversations`, etc., `:219-256`) re-filter/re-sort the full array on the
main thread on every access with no memoization. The view controller then does an
O(N) changed-id diff per emission (`ConversationsViewController.swift:161-198`).

Importantly, the downstream is already good: the list is a UICollectionView with an
id-keyed diffable data source that only reconfigures rows whose displayed fields
changed (`ConversationsViewController.swift:436-473`), and cells update in place via
an observable wrapper (`ConversationListItemCell.swift:24-63`). The wasted work is
above the snapshot: SQL, hydration, main-thread delivery, and diffing - all O(full
list), all per commit, times the number of subscribers.

### 2.4 Per-row costs at first render

- Every DM row's avatar starts its **own per-inbox GRDB ValueObservation**
  (`InboxProfileAvatarView.swift:47-49, 71-74`;
  `ProfilesRepository.profilePublisher`, `ProfilesRepository.swift:68-86`). 50
  visible-ish DMs = 50 extra observations against a reader pool capped at **5
  connections** (`DatabaseManager.swift:58`), all re-firing during sync writes.
- Avatar views seed synchronously in `init` via `ImageCache.shared.image(for:)`
  (`ConversationAvatarViews.swift:27`), which can fall through to a synchronous disk
  read + decode once per identity on the main thread; DM rows pay it twice
  (conversation + profile).
- Encrypted-avatar prefetch fires per stored conversation during sync
  (`ConversationWriter.swift:1451` -> `EncryptedImagePrefetcher`, 4-wide), competing
  with interactive fetches on a shared serial disk queue that also runs a full
  cache-directory enumeration at launch (`ImageCache.swift:196, 218, 805-866`).

## Part 3: Ranked recommendations

One unified ranking by estimated impact on heavy-user boot/foreground. The three
candidates under evaluation are marked **[candidate]**; the rest are the additional
alternatives requested. Impact estimates assume a heavy user (300-500 conversations,
1k+ message backlog).

### R1. Restructure catch-up: sync once via libxmtp, then read locally, bounded - **[candidate: catch-up concurrency]**

Impact: **very high** (likely 5-20x reduction in boot network calls and writer
contention). Effort: medium. Risk: low - data flow is unchanged, only ordering and
concurrency.

Three coordinated changes:

- Run **one** `syncAllConversations` first (it is activity-filtered and internally
  capped at 10-way concurrency), then run BatchCatchUp's prepare phase **without**
  the per-conversation `conversation.sync()` - after the global sync,
  `group.messages(afterNs:)` is a local read. This deletes N network round trips
  and lets libxmtp's own batched metadata check decide which groups need work.
  (Prepare would need a sync-free variant of `ConversationWriter.prepare`;
  `conversation.sync()` at `ConversationWriter.swift:265` is the line to bypass.)
- Bound whatever concurrency remains in `prepareAll` to ~4-8 (mirror
  `ConversationConsentReconciler`'s sliding window at
  `ConversationConsentReconciler.swift:112-129`). Local-only prepares are
  reader-pool-bound; more than that just contends.
- Parallelize (bounded) and batch `discoverNewConversations`
  (`SyncingManager.swift:590-603`) - it is currently strictly sequential with two
  awaited FFI calls per new group, which dominates fresh-install/pairing boot.

Also fold in: skip the duplicate `syncAllConversations` in `resume()` when
`runBatchCatchUp` just ran one (foreground currently pays batch + sync + discover +
push reconcile back-to-back; `SessionStateMachine.swift:982` +
`SyncingManager.swift:760`).

### R2. Debounce + dedupe the conversation list observation - **[candidate: invalidation/thrashing]** (cheapest big win)

Impact: **high** (collapses hundreds of full recomposes into a handful during any
burst). Effort: **trivial to small**. Risk: minimal.

- Add `.removeDuplicates()` to `conversationsPublisher`
  (`ConversationsRepository.swift:60`) - the agent-template publisher already does
  this for exactly this reason - and to `ConversationsCountRepository`.
  Note: dedup happens after the query runs, so this fixes main-thread churn, not
  query cost; pair with a debounce for the query itself.
- Throttle emissions (e.g. `.throttle(for: .milliseconds(250), latest: true)`) or
  schedule the observation on a dedicated queue with coalescing. GRDB runs the
  fetch per impactful commit; a debounce between commit and fetch is the lever that
  actually cuts query executions during a catch-up burst.
- Share one observation between `ConversationsViewModel` and
  `ThingsOverviewViewModel` (`.share()`/`.multicast` on the publisher, or route both
  through one repository instance) so the compose runs once per fire, not 2-3 times.

### R3. Paginate / limit the conversation list query - **[candidate: pagination]**

Impact: **high** for heavy users (per-fire cost becomes O(page) instead of O(N);
first paint faster; memory down). Effort: medium (repository + view model + data
source incremental load). Risk: medium - ordering with the in-memory agent-DM
re-sort and pinned handling needs care.

Concretely: `composeAllConversations` gains a `limit`/`after` cursor keyed on the
existing sort key `COALESCE(lastMessage.date, createdAt) DESC`; the collection view
requests the next page near the end of scroll. Two subtleties found in this
investigation:

- Pinned conversations are a separate small set - query them separately (a
  `PinnedConversationsCountRepository` already exists) so the paged query is pure.
- The unread filter and the "float on agent-DM reply" re-sort currently operate on
  the full in-memory array; both are expressible in SQL (unread via localState join,
  DM lane via a max over the folded DM date) once R5/R6 land.

Even a blunt `LIMIT 100` with "show more" would deliver most of the win for the
worst-affected users.

### R4. Stop per-message `conversation.sync()` + conversation persist on the stream path

Impact: **high** during any message burst (removes a network round trip and 1-2
write transactions per incoming message). Effort: low-medium. Risk: low.

`StreamProcessor.processMessage` calls `conversationWriter.store` for every group
message (`StreamProcessor.swift:285`), which re-syncs and re-reconciles the group.
Gate it: only run the full store when the conversation is unknown locally or a
group-updated/commit message arrived; plain application messages should write just
the message row. The existing no-op diff short-circuit proves the persist is usually
redundant - the point is to skip the sync and member fetch that precede it.

### R5. Remove the N+1 agent-DM fold and whole-contact-table read from compose

Impact: medium-high (directly multiplies R2/R3 savings; the contact fetch also
broadens the tracked region to every contact write). Effort: low-medium.

- Fold the agent-DM summary in SQL (a lateral-style join on the agent member's DM
  conversation) or cache the DM ids so the per-conversation `composeOneToOne`
  (`ConversationsRepository.swift:173`) disappears.
- Resolve contact names only for the inboxes actually present in the page
  (`WHERE inboxId IN (...)`) instead of `DBContact.fetchAll`
  (`ContactsRepository.swift:266`).

### R6. In-memory conversation list with incremental updates - **[candidate: in-memory list]**

Impact: medium-high, **but largely subsumed by R2+R3+R5 at much lower risk**.
Effort: high. Risk: high (cache-invalidation correctness, the exact bug class GRDB
observation currently absorbs for free).

Maintaining the hydrated list in memory and applying row-level deltas (per-table
DatabaseRegionObservation, or diffing snapshots) eliminates re-query cost entirely,
which R2/R3 only reduce. Recommended sequencing: do R2/R3/R5 first and re-measure;
adopt R6 only if a profile still shows compose dominating. If pursued, the shape is
a repository-level actor cache keyed by conversation id, invalidated per-table, with
the existing publisher emitting from the cache - the view layer needs no changes
(it already diffs by id).

### R7. Coalesce the foreground/reconnect re-sync avalanche

Impact: medium-high for users who app-switch often or ride flaky networks. Effort:
low-medium.

Every foreground runs: `assertInstallationActive` (blocking network probe,
`SessionStateMachine.swift:975`) -> full `runBatchCatchUp` -> `resume()` (stream
restart + another `syncAllConversations` + discover + push reconcile). Every network
up-transition triggers `resume()` too (`:1488-1501`). Suggestions: skip catch-up when
the last one completed within a short window (e.g. 30-60s); make
`assertInstallationActive` non-blocking (verify concurrently, tear down on failure);
debounce network-flap resumes; after R1, `resume()` needs no extra
`syncAllConversations` at all.

### R8. Batch the per-DM-row profile observations

Impact: medium (removes 50+ concurrent observations competing for 5 reader
connections during boot; fixes avatar-driven read contention). Effort: medium.

`InboxProfileAvatarView` starts one `profilePublisher` per row
(`InboxProfileAvatarView.swift:47`). The list hydration already loads every member's
profile in the main query - pass the hydrated profile/avatar down instead of
re-observing per row, or introduce one shared observation keyed by the set of
visible inbox ids. Related cheap fix: make the synchronous `ImageCache.image(for:)`
seed in avatar `init`s (`ConversationAvatarViews.swift:27`) async-first so first
render never does main-thread disk I/O.

### R9. Take non-critical work off the serial boot chain

Impact: medium for time-to-interactive (hundreds of ms to seconds, variance-heavy).
Effort: low per item.

- `registerDeviceIfNeeded()` (network) currently gates the XMTP client build
  (`SessionManager.swift:156-204`) - build the client first, register concurrently.
- `authenticateBackend()` (SIWE, up to 3 retries) sits between client build and
  `.ready` (`SessionStateMachine.swift:1349-1420`) - evaluate whether catch-up and
  streams can start on cached credentials while it refreshes.
- Migrations run synchronously pre-first-frame (`ConvosApp.swift:108` ->
  `DatabaseManager.swift:85`); releases that add full-table backfills
  (`SharedDatabaseMigrator.swift:388, 606, 1026`) make heavy users pay them on the
  launch frame. Consider an async migration gate with a lightweight splash.
- Cold-launch niceties already exist (libxmtp log writer detached, profile backfill
  post-ready) - this extends the same pattern.

### R10. Adopt libxmtp `catch_up_to_live` (XIP-83 bounded catch-up) - strategic

Impact: potentially the biggest long-term win (bounded first frame regardless of
account size, partial-progress timeouts, one multiplexed stream instead of per-group
round trips). Effort: high; gated on d14n availability per environment. The
`XMTP_BIDI_STREAMS_ENABLED` hook already exists (`ConvosApp.swift:45-48`). Track it
as the eventual replacement for the R1 shape rather than an immediate fix. Also
worth raising upstream: the cold-boot `maybe_update_installations` storm (30-minute
throttle always expired at boot; per-member identity queries per active group,
`mls_sync.rs:4066`) - a boot-time grace or lazy path would benefit every client.

### Smaller items noticed (not ranked, worth tickets)

- DEBUG builds trace **every SQL statement** (`DatabaseManager.swift:78-80`), and
  DEBUG covers Dev and PR TestFlight - skews any profiling done on those builds;
  measure on Release-configuration or gate the trace.
- `ImageCache` runs a full disk-cache enumeration at init on the same serial queue
  as interactive reads (`ImageCache.swift:196, 218`) - head-of-line blocking at
  first render; delay it or use a concurrent queue with a barrier.
- `IncomingMessageWriter.chronologicalSortId` does an O(n) `UPDATE ... sortId + 1`
  shift for out-of-order inserts (`IncomingMessageWriter.swift:541-569`) - backlog
  replay after pairing can hit this repeatedly.
- `ShareSuggestionDonator.donate` runs over the full list on every emission
  (`ConversationsViewModel.swift:648`) - throttle to once per few minutes.
- The temporary agent-join poll re-runs `syncAllConversations` every 5s for 150s
  after joins (`SyncingManager.swift:1111-1123`) - fine once R1 lands, but worth
  remembering it exists when reading boot traces.

## Measurement plan

`[PERF]` logs already cover the key spans: `sync.all_conversations`
(`SyncingManager.swift:503`), `catchup.batch.messages` with conv/message/skip counts
(`BatchCatchUp.swift:253`), `message.process` (`StreamProcessor.swift:332`),
`catchup.batch.invites` (`SyncingManager.swift:336`). Missing and cheap to add
before starting: a counter/timer on `composeAllConversations` executions (count per
minute is the thrash metric R2/R3 must drive down), a gauge for
`BatchCatchUp.prepareAll` peak in-flight tasks, and time-to-first-list-render.
Baseline on a heavy account with a Release-config build (see DEBUG trace caveat),
then re-measure after each of R1/R2/R3 independently.

## Appendix: where each conclusion comes from

- Unbounded fan-out: `BatchCatchUp.swift:353-400`; per-conversation network sync:
  `ConversationWriter.swift:260-281`; boot trigger: `SessionStateMachine.swift:828`;
  foreground trigger: `:982`; network-flap trigger: `:1488-1501`.
- libxmtp bounded sync + activity filter: `welcome_sync.rs:219, 377-392, 439`;
  single-writer SQLite: `xmtp_configuration/src/common/db.rs`, `pool.rs:37-38`;
  per-message write transaction: `mls_sync.rs:2321`; installation-update storm:
  `mls_sync.rs:4066`; unused bounded catch-up API: `bindings/mobile/src/mls.rs:786`.
- List query and observation: `ConversationsRepository.swift:42-204, 311-375`;
  contact-table read: `ContactsRepository.swift:265-274`; message-insert trigger:
  `SharedDatabaseMigrator.swift:439-448`; missing dedup vs the sibling publisher:
  `ConversationsRepository.swift:113-115`.
- View model / view: `ConversationsViewModel.swift:638-662, 219-256`;
  `ConversationsViewController.swift:161-198, 436-473`;
  `ThingsOverviewViewModel.swift:67-92`.
- Per-row profile observations and image seeds: `InboxProfileAvatarView.swift:47-89`;
  `ProfilesRepository.swift:68-86`; `ConversationAvatarViews.swift:27`;
  `ImageCache.swift:196-245, 805-866`; reader pool cap: `DatabaseManager.swift:58`.
- Boot chain and main-thread work: `ConvosApp.swift:24-165`;
  `SessionManager.swift:156-204, 323-460`; `SessionStateMachine.swift:521-584,
  1349-1420`; `BoundedInitialRead.swift:49-70`.
- Prior art this builds on: #857 (stream write-storm fixes),
  `docs/plans/batch-catchup-since-last-background.md` (the batch catch-up design),
  `docs/plans/conversations-uicollectionview.md` (the landed list rendering
  migration).
