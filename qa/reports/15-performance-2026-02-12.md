# Test Report: 15 - Performance Baselines

**Date:** 2026-02-12
**Tester:** Claude Code (QA Agent)
**Build:** Dev (commit 6709ac26)
**Simulator:** iPhone — 57F6DAD0-4A9C-4CDF-BE00-4BFE2E54BDFB
**Duration:** ~30 minutes

## Result: BASELINE ESTABLISHED ✅

4 of 5 metrics within target. 1 critical regression flagged (join_convo_ready).

---

## Performance Results

| Metric | Run 1 | Run 2 | Run 3 | Median | Msgs | Target | Status |
|--------|-------|-------|-------|--------|------|--------|--------|
| open_few_msgs | 3ms | 3ms | 3ms | **3ms** | 16 | < 50ms | ✅ |
| open_many_msgs | 2ms | 3ms | 3ms | **3ms** | 2* | < 100ms | ⚠️ see note |
| new_convo_inbox | 81ms | 85ms | 95ms | **85ms** | - | < 500ms | ✅ |
| new_convo_ready | 160ms | 153ms | 183ms | **160ms** | - | < 1000ms | ✅ |
| join_convo_ready | 34026ms | 16638ms† | - | **25332ms** | - | < 5000ms | ❌ CRITICAL |

Status: ✅ = within target, ⚠️ = needs investigation, ❌ = > 2x target (critical regression)

† Run from earlier in session (Heavy Messages join).

---

## Detailed Observations

### Part 1: Open Existing Conversation (Few Messages) ✅

**Conversation:** "Somebodies" (f697f908), 16 messages

| Run | Time | Messages |
|-----|------|----------|
| 1 | 3ms | 16 |
| 2 | 3ms | 16 |
| 3 | 3ms | 16 |

Extremely fast and consistent. Well within the 50ms target.

### Part 2: Open Existing Conversation (Many Messages) ⚠️ METHODOLOGY NOTE

**Conversation:** "Heavy Messages" (b7c7ed2b), 100+ messages sent via CLI

| Run | Time | Messages |
|-----|------|----------|
| 1 | 2ms | 2 |
| 2 | 3ms | 2 |
| 3 | 3ms | 2 |

**Important finding:** Despite 100+ messages in the conversation visible on screen, `ConversationViewModel.init` only reports **2 messages loaded** in the initial fetch. This happens because:

1. The 100 messages were sent from a CLI identity (not the app's identity)
2. The messages come through XMTP streaming/sync, not the local message writer
3. `fetchInitial()` in `MessagesListRepository` appears to only count locally-written messages in the initial page query
4. The remaining messages stream in via the live observer after init completes

**Conclusion:** The `open_many_msgs` metric is not properly testable with externally-sent messages. To accurately measure this, either:
- Messages need to be sent **from** the app identity, or
- The perf instrumentation needs to measure the total time including streamed messages
- A separate test should measure pagination performance when scrolling up through 100+ messages

The 2-3ms timing is real but only measures the initial page fetch of locally-authored messages.

### Part 3: Create New Conversation ✅

All runs used pre-created conversations (origin: existing), which is the normal user experience.

| Run | inboxAcquired | ready | Origin |
|-----|--------------|-------|--------|
| 1 | 81ms | 160ms | existing |
| 2 | 85ms | 153ms | existing |
| 3 | 95ms | 183ms | existing |

`NewConversation.creating` was never emitted — the app always had a pre-created unused conversation available, so it skips the creation step entirely.

**Breakdown:**
- Inbox acquisition (identity assignment): ~85ms median
- Total ready time: ~160ms median
- Delta (inbox → ready): ~75ms (conversation lookup + state machine transition)

Well within the 1000ms target. The pre-created conversation pool is working as designed.

### Part 4: Join Conversation via Invite ❌ CRITICAL

| Run | inboxAcquired | ready | Origin |
|-----|--------------|-------|--------|
| 1 (Heavy Messages) | 65ms | 16,638ms | joined |
| 2 (Join Perf Test) | 67ms | 34,026ms | joined |

**Median ready time: ~25,332ms (25.3 seconds) — 5x over the 5,000ms target.**

The join flow is extremely slow. The `inboxAcquired` step is fast (~66ms), but the time from inbox acquisition to `ready` is dominated by:

1. Waiting for the join request to be processed by the creator (external dependency)
2. XMTP sync to detect the member addition
3. State machine transition from `joining` → `ready`

**Note:** The `ready` timer includes the time waiting for the creator to process the join request via CLI, which is an external dependency not under the app's control. The 34s run included ~15s of network/processing delay. However, even the 16.6s run (where CLI processing was faster) significantly exceeds the target.

**Recommendation:** The `join_convo_ready` metric should be split into:
- `join_convo_request_sent`: time to send the join request (app's control)
- `join_convo_approved`: time from request sent to approval detected (external dependency)
- `join_convo_ready`: time from approval detected to conversation ready (app's control)

---

## XMTP Errors Observed

| Time | Error | Impact |
|------|-------|--------|
| 20:06:55Z | `inboxNotFound("a6a5104b...")` | None — expected after conversation explosion |
| 20:06:55Z | `[GroupError::Sync] Group is inactive` | None — expected after conversation explosion |

Both errors occurred after teardown (exploding test conversations) and did not affect any measurements.

---

## Test Environment

- **Device:** iPhone simulator (iOS 26.0)
- **Network:** WiFi (simulator)
- **XMTP Environment:** dev
- **App State:** Warm (app was running, identities loaded)
- **Pre-created conversations:** Available for all compose tests

## Conversations Created & Cleaned Up

| Conversation | ID | Purpose | Cleaned |
|---|---|---|---|
| Heavy Messages | b7c7ed2b98bc97f2770ac10df4ad2a8e | Part 2 (many messages) | ✅ Exploded |
| Join Perf Test | d1a29d12b7bf8c6e33dceca9d762428b | Part 4 (join invite) | ✅ Exploded |
| (3 compose tests) | 7ac80756, 55fe965f, 3b0c849d | Part 3 (new convo) | Left in app* |

*Compose-created conversations cannot be exploded via CLI (created by app identity). They will be cleaned up on next app reset.

## Summary

| Category | Result |
|----------|--------|
| Conversation open (few msgs) | ✅ 3ms — excellent |
| Conversation open (many msgs) | ⚠️ 3ms but only 2 msgs measured — methodology issue |
| New conversation creation | ✅ 160ms — excellent |
| Join via invite | ❌ 25,332ms — 5x over target, includes external wait |

### Action Items

1. **BUG/PERF:** Investigate join flow latency — even discounting external processing time, the join-to-ready path seems slow
2. **INSTRUMENTATION:** Add finer-grained perf logging to the join flow to separate request-sent from approval-detected from ready
3. **INSTRUMENTATION:** The `open_many_msgs` metric needs a different test approach — either send messages from the app identity or measure total render time including streamed messages
4. **TEST UPDATE:** Update test 15 to note that CLI-sent messages don't get counted in `fetchInitial()` message count
