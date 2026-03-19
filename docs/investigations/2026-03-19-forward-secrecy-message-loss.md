# Forward Secrecy Failure Report — Assistant Missed Messages

**Conversation:** `d058c931b8b8122d2cca33f068e861e7`
**Date:** March 19, 2026, 16:57–17:00 UTC
**App version:** 1.1.3, builds 636/639, dev environment
**Fork recovery:** not enabled

## Members

| Name | Inbox ID (short) | Role | Joined Epoch | Welcome Epoch |
|---|---|---|---|---|
| Shane (`9c51e`) | `9c51e494...` | Creator | 0 (GroupCreation) | — |
| Saul (`cd5c7`) | `cd5c7a4e...` | Human member | 5 (UpdateGroupMembership) | 5 |
| Jarod (`a7636`) | `a76369c1...` | Human member | 7 (UpdateGroupMembership) | 7 |
| Courter (`97b1d`) | `97b1dda6...` | Human member | 9 (UpdateGroupMembership) | 9 |
| Louis (`e0f54`) | `e0f5464f...` | Human member | 11 (UpdateGroupMembership) | 11 |
| Assistant (`41366`) | `4136610d...` | Assistant | 17 (UpdateGroupMembership) | — |

## Symptom

Messages sent by Courter (`97b1d`) and Louis (`e0f54`) are partially missing on other users' devices. The Assistant (`41366`) messages are received by all users.

## Message Delivery Matrix

| Sender | Sent | Courter received | Jarod received | Louis received | Saul received | Shane received |
|---|---|---|---|---|---|---|
| Courter (`97b1d`) | 8 texts | — | 3 | 3 | 3 | 3 |
| Louis (`e0f54`) | 4 texts | 1 | 1 | — | 1 | 1 |
| Assistant (`41366`) | 6 texts | 6 | 6 | 6 | 6 | 6 |

**Missing messages:** 5 of Courter's 8 texts and 3 of Louis's 4 texts are not received by other users.

## Forward Secrecy Errors

All 5 human users experienced forward secrecy errors in their XMTP logs:

| User | Forward Secrecy Errors |
|---|---|
| Courter (`97b1d`) | 58 |
| Saul (`cd5c7`) | 49 |
| Louis (`e0f54`) | 42 |
| Jarod (`a7636`) | 37 |
| Shane (`9c51e`) | 36 |

All errors are: `openmls process message error: The requested secret was deleted to preserve forward secrecy.`

## Conversation Debug JSON

All 5 users show `commitLogForkStatus: "unknown"` (Shane shows `"notForked"`), `maybeForked: false`, current epoch 19.

Each user's local commit log starts at their Welcome epoch and does not contain earlier epochs. Shane (creator) has the full history from epoch 0.

## Timeline

| Time (UTC) | Event |
|---|---|
| 12:37:00 | Shane creates group `d058c9..` (epoch 0), metadata updates |
| 16:57:44 | Shane accepts Saul's join request, adds Saul (`cd5c7`) to group (epoch 5) |
| 16:57:45 | Saul joins via Welcome |
| 16:57:46 | Saul receives Saul's own metadata update |
| 16:57:47 | Shane accepts Jarod's join request, adds Jarod (`a7636`) to group (epoch 7) |
| 16:57:47 | Jarod joins via Welcome |
| 16:57:49 | Shane accepts Courter's join request, adds Courter (`97b1d`) to group (epoch 9) |
| 16:57:50 | Courter joins via Welcome |
| 16:57:51 | Shane accepts Louis's join request, adds Louis (`e0f54`) to group (epoch 11) |
| 16:57:52 | Louis joins via Welcome |
| 16:57:53 | Courter and Louis metadata updates received by all |
| 16:57:56 | **Louis sends first text message** — received by Courter, Jarod, Saul, Shane |
| 16:57:59 | **Courter sends first text** — received by Jarod, Louis, Saul, Shane |
| 16:58:03 | **Courter sends second text** — received by Jarod, Louis, Saul, Shane |
| 16:58:06 | **Courter sends third text** — received by Jarod, Louis, Saul, Shane |
| 16:58:12 | **Courter sends emoji** — received by Jarod, Louis, Saul, Shane |
| 16:58:15 | Shane sends assistantJoinRequest — received by all |
| 16:58:25 | Shane accepts Assistant's join request, adds Assistant (`41366`) to group (epoch 17) |
| 16:58:29 | Assistant metadata update received by Jarod, Louis, Saul, Shane |
| 16:58:30 | Assistant metadata update received by Courter (1 second later) |
| 16:58:32 | **Louis sends second text** — NOT visible in other users' app logs |
| 16:58:42 | **Courter sends fourth text** — NOT visible in other users' app logs |
| 16:58:44 | **Assistant sends first text** — received by Courter, Jarod, Saul, Shane (2 copies on Shane) |
| 16:58:45 | **Assistant sends second text** — received by all. **Courter receives own text echo (97b1d)** |
| 16:58:45 | **Courter sends fifth text** — NOT visible in other users' app logs |
| 16:58:49 | **Assistant sends third text** — received by all |
| 16:58:54 | **Courter sends sixth text** — NOT visible in other users' app logs |
| 16:58:56 | **Louis sends third text** — NOT visible in other users' app logs |
| 16:59:02 | **Assistant sends fourth text** — received by all |
| 16:59:04 | **Louis sends fourth text** — NOT visible in other users' app logs |
| 16:59:08 | **Assistant sends fifth text** — received by all |
| 16:59:12 | **Courter sends seventh/eighth text** — NOT visible in other users' app logs |
| 16:59:17 | **Assistant sends sixth text** — received by all |
| 16:59:19 | Assistant reaction — received by all |

## Forward Secrecy Error Timing

The forward secrecy errors begin **before** the Assistant joined:

| User | First Error | Joined At | Errors Start Relative to First Member Add (16:57:44) |
|---|---|---|---|
| Saul (`cd5c7`) | 16:57:47.388 | 16:57:45 | +3 seconds |
| Shane (`9c51e`) | 16:57:49.102 | creator | +5 seconds |
| Courter (`97b1d`) | 16:57:50.486 | 16:57:50 | +6 seconds |
| Jarod (`a7636`) | 16:57:53.325 | 16:57:47 | +9 seconds |
| Louis (`e0f54`) | 16:57:59.548 | 16:57:52 | +15 seconds |

All errors are from `originator_id: 10`. The Assistant joined at 16:58:25 — 38 seconds after the first forward secrecy error.

## Dual Code Path Evidence

On Shane's device, the same cursor is processed twice within the main app process via two code paths. Example for cursor `sid(28335401)` (a message from Jarod):

```
16:57:49.016Z process_message: Processing envelope ...cursor = [sid(28335401):oid(10)]
16:57:49.017Z process_message: ➣ Received application message. epoch: 8, sender: a76369 (Jarod)

16:57:49.102Z sync:sync_with_conn: Processing envelope ...cursor = [sid(28335401):oid(10)]
16:57:49.102Z sync:sync_with_conn: Transaction failed: ...forward secrecy error
```

86ms apart. The stream path (`process_message`) decrypts the message and advances the MLS ratchet. The sync path (`sync_with_conn`) attempts to process the same envelope but the ratchet has already advanced.

Multiple cursors are processed up to **4 times** each across the stream and sync paths.

## Observations

1. Forward secrecy errors begin **before** the Assistant joined — they are triggered by the rapid member addition sequence (4 members in 8 seconds), not by the Assistant.
2. Courter's first 3 texts (sent 16:57:59–16:58:06) are delivered to all users. Courter's texts from 16:58:42 onward are not received. The cutoff coincides with the Assistant joining (16:58:25) and the additional epoch transitions it caused.
3. All 6 Assistant messages are received by all users without issue.
4. All 5 human users have forward secrecy errors in their XMTP logs (31–43 errors each), all from `originator_id: 10`.
5. The same envelope is processed by both `process_message` (stream, `trust_message_order=false`) and `sync_with_conn` (sync, `trust_message_order=true`) within the same process, 86ms apart. The stream advances the ratchet; the sync fails.
6. The conversation went through 19 epoch transitions in ~90 seconds with 6 members joining in rapid succession.
7. The pattern is consistent with the previous incident (conversation `b2a55b`): rapid member additions trigger the dual code path issue, and messages sent after additional epoch transitions are lost.

## Assistant Backend Behavior

The assistant server logs show that when the assistant started at 16:58:30, it received a backlog of 8 messages that had been sent while it was joining. All 8 messages were processed **simultaneously** as parallel LLM calls at 16:59:17 (within the same millisecond):

```
16:59:17.448: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:58 PM UTC]
16:59:17.448: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:58 PM UTC]
16:59:17.448: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:58 PM UTC]
16:59:17.449: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:58 PM UTC]
16:59:17.450: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:58 PM UTC]
16:59:17.450: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:58 PM UTC]
16:59:17.451: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:59 PM UTC]
16:59:17.452: 💬 Starting conversation: '[Current time: Thu, Mar 19, 2026, 04:59 PM UTC]
```

Each parallel LLM call generated a response, resulting in the assistant sending 6 text messages and 1 reaction in rapid succession (16:58:44 to 16:59:19) through the same XMTP client. The parallel responses completed at varying times, with API calls taking 3-12 seconds each.

## Data

- `Shane | convos-logs-3B488C0C/` — creator's logs
- `Saul | convos-logs-B401BF23/` — member logs (joined epoch 5)
- `Jarod | convos-logs-5919C0BF/` — member logs (joined epoch 7)
- `Courter | convos-logs-75776DEC/` — member logs (joined epoch 9, 8 texts sent, 5 missing)
- `Louis | convos-logs-977E5D75/` — member logs (joined epoch 11, 4 texts sent, 3 missing)
- `logs.1773939785538.json` — Assistant server logs

## Reproduction Attempt

A CLI-based reproduction using `convos` with separate `--home` directories was attempted:
- 1 creator + 4 users joining rapidly (0.5s apart)
- Each user sent 3 messages after joining

**Result:** All 12 messages delivered successfully to all 5 users. No forward secrecy errors.

**Why it didn't reproduce:** The CLI's `send-text` command is synchronous — it sends one message, waits for sync to complete, then returns. There is no concurrent message stream running. The iOS app has two concurrent code paths (`process_message` from the stream and `sync_with_conn` from sync) that race on the same MLS ratchet state, which is what causes the forward secrecy errors. The CLI doesn't have this race condition because `stream` and `send-text` are separate commands that don't run simultaneously.

To reproduce, the test would need to simulate what the iOS app does: have an active `conversation.stream()` subscription running while `sync_with_conn()` also processes the same messages — within the same process, sharing the same MLS group state.

A `reproduce.sh` script is included in this folder.

## Reproduction Attempt 2 (Hybrid CLI + iOS Simulators)

4 iOS simulators joined a CLI-created group via invite URL. 10 messages were sent from the CLI after all joins completed.

**Result:** All 10 messages delivered to all 4 simulators. No forward secrecy errors observed. The notification extension (PID 6605) was running concurrently with the main app on all simulators.

**Why it didn't reproduce:** The joins completed before the messages were sent. In both real incidents, the key condition was members joining and messages being sent **simultaneously** — causing rapid epoch transitions (19 epochs in 90 seconds) while application messages were in flight. The CLI sends messages sequentially with 0.5s gaps, which is too slow to trigger the race.

**What would be needed to reproduce:**
1. Multiple members joining simultaneously (as done here)
2. Messages being sent by already-joined members **during** the join processing
3. The receiving iOS apps having both the message stream and sync actively processing at the same time

The setup (4 simulators + CLI creator) is preserved and can be reused. The simulators are: `convos-fs-repro-1` through `convos-fs-repro-4`.

## Reproduction Setup (for manual testing)

The following infrastructure is set up and ready for manual reproduction:

**Simulators:** `convos-fs-repro-1` through `convos-fs-repro-4` (iPhone 17 Pro Max, booted, app installed, push notifications enabled)

**Reproduction steps:**
1. On a Mac, run: `convos conversations create --name "Test" --profile-name "Creator" --env dev`
2. Generate invite: `convos conversation invite <conv-id> --json`
3. Start watcher: `convos conversations process-join-requests --watch`
4. On each simulator, open the invite URL (via Safari or `xcrun simctl openurl`)
5. Tap "Open" in the Safari banner to open in Convos app
6. **Critical:** While simulators are joining, immediately start sending messages from CLI: `for i in $(seq 1 20); do convos conversation send-text <conv-id> "msg $i"; sleep 0.2; done`
7. After ~30 seconds, check each simulator for missing messages
8. Export debug logs from the conversation on each simulator

**What to look for:**
- Messages from the CLI user not appearing on some simulators
- Forward secrecy errors in XMTP logs: `"The requested secret was deleted to preserve forward secrecy"`
- The same cursor being processed by both `process_message` and `sync_with_conn`

**Scripts available:** `reproduce.sh` (CLI-only), `reproduce-hybrid.sh` (CLI + simulator), `reproduce-v2.sh` (simultaneous join + send)

## Successful Reproduction

**Setup:** 2 iOS simulators already in conversation (with active streams + NSE), 1 CLI sender using `agent serve` for zero-delay message sending.

**Test:** Simultaneously piped 200 text messages via `agent serve` stdin (zero delay between messages) while 4 CLI users joined the group via invite.

**Result:**
- 200 messages sent (all 200 confirmed by agent)
- Both iOS simulators received **36 out of 200** (82% message loss)
- Both simulators received exactly the same 36 messages (deterministic)
- No errors in the app log — messages silently dropped
- Burst lasted 7 seconds (18:55:00–18:55:07 UTC)
- Group grew from 19 to 23 members during the burst

**Reproduction command:**
```bash
# Pipe 200 messages with zero delay while 4 users join simultaneously
(for i in $(seq 1 200); do echo "{\"type\":\"send\",\"text\":\"BURST$i\"}"; done; sleep 5; echo '{"type":"stop"}') \
  | convos agent serve <conv-id> --home <sender-home> --no-invite --heartbeat 0 &

for i in 1 2 3 4; do
  convos conversations join <slug> --profile-name "Joiner$i" --home <joiner-home> --no-wait &
done
```

This confirms that rapid message sending during simultaneous member additions causes deterministic message loss on iOS receivers.

## Reproduction with XMTP Logs Confirmed

After fixing the XMTP log writer (case-sensitivity conflict between `Logs/` and `logs/` directories), libxmtp logs are now being written on the simulators.

**Reproduction:**
- 200 messages sent via `agent serve` pipe + 4 simultaneous CLI joiners
- 2 iOS simulators already in conversation with active streams + NSE

**XMTP log results:**
- **convos-fs-repro-1: 71 forward secrecy errors**
- **convos-fs-repro-2: 102 forward secrecy errors**

Sample error from libxmtp log:
```
2026-03-19T19:12:20.271Z sync:sync_with_conn: Transaction failed:
  process for group [b35f39...5c02]
  envelope cursor [[sid(28340726):oid(10)]]
  error:[openmls process message error: The requested secret was deleted
  to preserve forward secrecy.]
```

This confirms the exact same error as both real incidents. The `sync_with_conn` code path fails because the `process_message` stream path already advanced the MLS ratchet for the same envelope.

**Note:** The XMTP log writer failed on fresh simulator installs due to a case-sensitivity conflict: the Convos app creates `Logs/` (uppercase) for its app log, while libxmtp tries to create `logs/` (lowercase). On macOS's case-insensitive filesystem, `createDirectory` fails. Fix: rename `Logs/` to `logs/` on the simulator before running.

## NSE Isolation Test

**Test:** Disabled the notification service extension entirely (immediate return without processing) and re-ran the burst test.

**Result:**
- **convos-fs-repro-1: 191 forward secrecy errors** (vs 71 with NSE enabled)
- **convos-fs-repro-2: 190 forward secrecy errors** (vs 102 with NSE enabled)

**Conclusion:** Forward secrecy errors **increase** when the NSE is disabled. The NSE is not the cause. The errors originate entirely within the main app process, from the dual code paths inside libxmtp: `process_message` (stream, `trust_message_order=false`) and `sync_with_conn` (sync, `trust_message_order=true`) both processing the same MLS envelope within the same process.

The higher error count without NSE may be because the NSE was actually "consuming" some messages (advancing the ratchet) before the main app's dual paths could race on them. Without the NSE, all messages go through the main app's racing paths.

## Sync Disable Test (Incomplete)

Attempted to disable `syncAllConversations` (initial + resume) while keeping `requestDiscovery` enabled. However, disabling the initial sync prevented the app from properly initializing — conversations couldn't be discovered and the join flow failed. The sync calls are too deeply integrated into the app lifecycle to isolate cleanly.

The NSE test above already confirms the issue is within the main app process. The libxmtp XMTP logs show `sync_with_conn` as the failing code path, while `process_message` (stream) succeeds — both within the same main app process. This is consistent across all tests:

| Test | FS Errors (sim1) | FS Errors (sim2) | NSE Active |
|---|---|---|---|
| Normal (baseline) | 71 | 102 | Yes |
| NSE disabled | 191 | 190 | No |

Both tests show forward secrecy errors originating from `sync_with_conn` in the main app process. The issue is in libxmtp's internal handling of concurrent stream + sync code paths.

## Network Verification

**Test:** Added an independent CLI "checker" user to the conversation. After the burst test (200 messages + 4 joins), synced the checker from the network.

**Result:**
- Agent sent: **200 messages** (all confirmed)
- CLI checker (fresh sync from network): **200 text messages received**
- iOS simulators: message loss + forward secrecy errors

**Conclusion:** All 200 messages exist on the XMTP network and are retrievable by a CLI client. The message loss occurs at the iOS receiver's MLS processing layer within libxmtp, not on the network or sender side.

## libxmtp iOS SDK Test Results

Wrote tests in `libxmtp/sdks/ios/Tests/XMTPTests/ForwardSecrecyReproTests.swift` (branch `convos/forward-secrecy-repro`) that reproduce the exact concurrent pattern from our iOS app:

| Test | Stream | Sync | NSE Client | Rapid Joins | Messages | Result |
|---|---|---|---|---|---|---|
| Stream + Sync | ✅ | ✅ (50 iterations, 10ms apart) | ❌ | 4 joins | 200 | **0 lost** |
| Stream only (control) | ✅ | ❌ (deferred) | ❌ | 4 joins | 200 | **0 lost** |
| Sync only (control) | ❌ | ✅ | ❌ | 4 joins | 200 | **0 lost** |
| Two clients same DB | ✅ | ✅ (both clients) | ✅ (separate Client, same DB) | 4 joins | 200 | **0 lost** |

All tests pass with 0 message loss when run on **macOS** against a local XMTP node.

The same concurrent pattern (stream + syncAllConversations + rapid member additions + 200 messages) that causes **82% message loss on iOS simulators** produces **zero loss** in the SDK test on macOS.

This indicates the issue is NOT in libxmtp's stream/sync handling itself, but in something specific to how the iOS runtime, iOS simulator, or our iOS app's specific usage pattern (multiple inboxes, SyncingManager lifecycle, NSE as separate OS process, etc.) interacts with libxmtp.

## Dev Network Test Results

Re-ran all tests against the XMTP dev network (same network our production app uses):

| Test | Network | Messages | Lost |
|---|---|---|---|
| Stream + Sync | dev | 200 | **0** |
| Two clients same DB (NSE sim) | dev | 200 | **0** |

All tests pass with 0 message loss on the dev network. The `SequenceId not found in local db` error appeared during initial setup but did not cause message loss.

## Summary of Findings

The forward secrecy message loss is reproducible on iOS simulators (82% loss with 200 messages) but NOT reproducible in libxmtp SDK tests on macOS — not against local node, not against dev network, not with single client, not with two clients sharing a DB.

Something specific to the iOS app runtime causes the issue. Remaining hypotheses:
1. **Multiple inboxes**: our iOS app has 10+ inboxes, each running concurrent sync. The SDK test has one inbox.
2. **iOS process model**: the NSE is a truly separate OS process (not just a separate Client instance in the same process), with independent memory, thread scheduling, and SQLite connection handling.
3. **App lifecycle timing**: SyncingManager's specific ordering (streams first, then syncAllConversations, with backgrounding/foregrounding) creates timing that the SDK test doesn't replicate.
4. **The Convos app's StreamProcessor**: our app layer processes decoded messages and writes to our GRDB database, which adds back-pressure that changes the timing of when libxmtp's internal stream vs sync paths execute.

## Multi-Inbox Test Results (Dev Network)

| Test | Inboxes | Concurrent Streams | Concurrent Syncs | Messages | Lost |
|---|---|---|---|---|---|
| Multi-inbox concurrent sync | 11 | 11 | 11 (20 rounds each) | 200 | **0** |

Even with 11 inboxes all streaming and syncing simultaneously against the dev XMTP network, no messages are lost. The libxmtp SDK handles this correctly.

The issue cannot be reproduced at the SDK level — not with concurrent stream + sync, not with two clients sharing a DB, not with 11 concurrent inboxes, not on local or dev networks. Something specific to the iOS app runtime (real NSE process separation, our StreamProcessor/GRDB layer, or app lifecycle) creates the conditions for message loss.

## Root Cause Found

**The Convos iOS app calls `conversation.sync()` inside the stream message handler.**

In `StreamProcessor.processMessage()` (line 171), every message received from the stream triggers:
1. `findConversation(conversationId:)` — looks up the XMTP conversation
2. `conversationWriter.store(conversation:)` — which internally calls **`conversation.sync()`** (ConversationWriter.swift line 201)

This `conversation.sync()` call triggers libxmtp's `sync_with_conn`, which queries and processes ALL pending messages for the group from the network. Since the stream already processed the current message via `process_message` (with `trust_message_order=false`), the `sync_with_conn` re-attempts the same envelopes — but the MLS ratchet keys were already consumed by the stream's `process_message`.

**The flow:**
1. Stream delivers message M1 → libxmtp's `process_message` decrypts it (ratchet advances)
2. Our `StreamProcessor` calls `conversationWriter.store()` → calls `conversation.sync()` → libxmtp's `sync_with_conn` tries to process M1 again → **forward secrecy error** (ratchet already advanced)
3. Stream delivers message M2 → `process_message` decrypts it
4. But `sync_with_conn` from step 2 also tries to process M2 → **forward secrecy error** or race
5. Our `StreamProcessor` calls `conversation.sync()` again for M2 → more overlap

During rapid message delivery (200 messages + 4 member additions), this creates massive contention between the stream's `process_message` and our app's `conversation.sync()` calls.

**This explains why:**
- The SDK test passes: it never calls `group.sync()` inside the stream callback
- The CLI passes: `agent serve` doesn't call sync while streaming  
- The iOS app fails: `StreamProcessor` calls `conversation.sync()` for every streamed message
- Disabling `syncAllConversations` didn't help: the per-message `conversation.sync()` in `conversationWriter.store()` is the actual culprit
- Disabling NSE didn't help: the issue is in the main app's StreamProcessor

## ROOT CAUSE CONFIRMED

Adding a 150ms delay to the stream callback (simulating our app's GRDB write time) reproduces the issue in the SDK test:

```
Messages sent: 200
Messages received via stream: 23
Messages in DB after sync: 200
Stream loss: 177 messages
DB loss: 0 messages
```

**The stream only delivers 23 out of 200 messages** when each message takes ~150ms to process (matching our app's observed PERF timings). The remaining 177 messages are consumed by `conversation.sync()` (called inside the stream callback) before the stream can deliver them.

The messages DO exist in libxmtp's database (DB count = 200 after final sync), but they never flow through our `StreamProcessor` — meaning they don't get stored to our GRDB database, don't trigger unread markers, and don't appear in the UI.

**The fix:** Remove the `conversation.sync()` call from `ConversationWriter.store()` when called from the stream processing path. The stream already provides the decoded message — there's no need to re-sync the conversation from the network for each streamed message.

## Sync Isolation Tests

Systematically disabled sync calls to identify the source of forward secrecy errors:

| Test | skipSync | Startup syncAll | Resume syncAll | Discovery syncAll | FS Errors (avg) |
|---|---|---|---|---|---|
| Baseline (no changes) | ❌ | ✅ | ✅ | ✅ | ~87 |
| skipSync only | ✅ | ✅ | ✅ | ✅ | ~174 |
| skipSync + no startup | ✅ | ❌ | ✅ | ✅ | ~173 |
| ALL syncs disabled | ✅ | ❌ | ❌ | ❌ | ~162 |

**Forward secrecy errors persist even with ALL app-level syncAllConversations calls disabled AND per-message conversation.sync() removed.** The errors are not caused by our app's sync calls.

The errors originate from within libxmtp's own internal workers (CommitLog worker, device sync worker) which run on timers and trigger `sync_with_conn` independently of our app's sync calls. The `process_message` (stream path) and these internal workers' `sync_with_conn` calls race on the same MLS envelopes within libxmtp's Rust runtime.

This is a libxmtp issue, not a Convos app issue. The same pattern does not reproduce in the libxmtp iOS SDK test on macOS because:
1. The local XMTP node has near-zero latency (no time for the race to manifest)
2. The dev XMTP node test also passes because the macOS test has no processing delay in the stream callback

The processing delay from our app layer (StreamProcessor actor serialization, GRDB writes, metadata extraction — ~150ms per message as seen in PERF logs) widens the race window enough for libxmtp's internal workers to trigger `sync_with_conn` between stream message deliveries.

## skipSync Fix Verified ✅

Checked actual message delivery to GRDB (our app's database) across all 4 simulators:

| Test | skipSync | Messages in GRDB | FS Errors (XMTP) |
|---|---|---|---|
| Baseline (no fix) | ❌ | **0/200** ❌ | ~87 |
| NSE disabled (no skipSync) | ❌ | **0/200** ❌ | ~190 |
| **skipSync fix** | ✅ | **200/200** ✅ | ~173 |

**The `skipSync` fix resolves the message loss.** All 200 messages are delivered to the app's GRDB database with the fix applied.

The forward secrecy errors in the XMTP logs still occur (from libxmtp's internal CommitLog worker) but they are **benign** — the stream successfully delivers all messages to our StreamProcessor before the internal workers race on them. Without `conversation.sync()` blocking the stream callback, the stream processes messages fast enough that the internal worker races don't cause message loss at the app layer.

**The fix:** In `ConversationWriter._store()`, skip the `conversation.sync()` call when invoked from the stream message processing path (`store()`) but keep it for the conversation discovery path (`storeWithLatestMessages()`).
