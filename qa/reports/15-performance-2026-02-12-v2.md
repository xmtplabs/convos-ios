# Test Report: 15 - Performance Baselines (v2)

**Date:** 2026-02-12 (second run)
**Tester:** Claude Code (QA Agent)
**Build:** Dev (commit 591e1d23 — includes joinRequestSent marker)
**Simulator:** iPhone — 57F6DAD0-4A9C-4CDF-BE00-4BFE2E54BDFB
**Duration:** ~10 minutes

## Result: PASS ✅

All measurable metrics within target. Join flow validated with `--watch` methodology.

---

## Performance Results

| Metric | Run 1 | Run 2 | Run 3 | Median | Msgs | Target | Status |
|--------|-------|-------|-------|--------|------|--------|--------|
| open_few_msgs | 21ms | 3ms | 3ms | **3ms** | 16 | < 50ms | ✅ |
| open_many_msgs | — | — | — | **N/A** | — | < 100ms | ⚠️ skipped* |
| new_convo_inbox | 132ms | 92ms | 91ms | **92ms** | - | < 500ms | ✅ |
| new_convo_ready | 225ms | 167ms | 160ms | **167ms** | - | < 1000ms | ✅ |
| join_convo_ready | 2081ms | — | — | **2081ms** | - | info only | ✅ |
| join_approval_to_ready | ~1000ms | — | — | **~1000ms** | - | < 5000ms | ✅ |

Status: ✅ = within target, ⚠️ = skipped (methodology issue)

*`open_many_msgs` skipped — CLI-sent messages are not counted by `fetchInitial()` page query. See v1 report for details.

---

## Detailed Observations

### Part 1: Open Existing Conversation (Few Messages) ✅

**Conversation:** "Somebodies" (f697f908), 16 messages

| Run | Time | Messages | Note |
|-----|------|----------|------|
| 1 | 21ms | 16 | Cold (first open after fresh app launch) |
| 2 | 3ms | 16 | Warm |
| 3 | 3ms | 16 | Warm |

Run 1 is higher due to cold start (first conversation open after app relaunch). Warm runs are consistently 3ms.

### Part 2: Open Existing Conversation (Many Messages) — SKIPPED

Same methodology limitation as v1: CLI-sent messages not counted in `fetchInitial()`. Skipped to avoid misleading data.

### Part 3: Create New Conversation ✅

| Run | inboxAcquired | ready | Origin |
|-----|--------------|-------|--------|
| 1 | 132ms | 225ms | existing |
| 2 | 92ms | 167ms | existing |
| 3 | 91ms | 160ms | existing |

Run 1 slightly higher (cold path for inbox pool after fresh launch). Runs 2-3 are consistent with v1 baselines.

### Part 4: Join Conversation via Invite ✅

**New methodology:** Used `process-join-requests --watch` running in background before opening the deep link.

| Metric | Value |
|--------|-------|
| inboxAcquired | 86ms |
| joinRequestSent | T+~1s (20:22:15) |
| ready | 2081ms total (origin: joined) |
| **approval_to_ready** | **~1000ms** (joinRequestSent 20:22:15 → ready 20:22:16) |

**Massive improvement over v1** (was 16-34s). The v1 measurements were entirely QA agent latency — time spent taking screenshots and running CLI commands between invite open and join processing.

With `--watch` running, the actual end-to-end join time is **2.08 seconds**, and the approval-to-ready delta is only **~1 second**. Both well within the 5s target.

**Timeline breakdown:**
- 0ms: Deep link opened
- 86ms: Inbox acquired
- ~1000ms: Join request published to XMTP (DM created + published)
- ~1000ms: Watcher detects request, adds member, app syncs and transitions to ready
- **Total: 2081ms**

---

## Comparison with v1

| Metric | v1 Median | v2 Median | Change |
|--------|-----------|-----------|--------|
| open_few_msgs | 3ms | 3ms | — |
| new_convo_inbox | 85ms | 92ms | +8% (within variance) |
| new_convo_ready | 160ms | 167ms | +4% (within variance) |
| join_convo_ready | 25,332ms | 2,081ms | **-92%** (methodology fix) |

The join improvement is entirely due to the `--watch` methodology — not an app code change. The v1 numbers were inflated by QA agent latency.

---

## XMTP Errors Observed

| Time | Error | Impact |
|------|-------|--------|
| 20:22:47Z | `FOREIGN KEY constraint failed` (x2) | None — expected after conversation explosion (message arrives for deleted conversation) |

---

## Conversations Created & Cleaned Up

| Conversation | ID | Purpose | Cleaned |
|---|---|---|---|
| Perf Join v2 | 8aa0b38ab407c8c0f49afa56f1977451 | Part 4 (join invite) | ✅ Exploded |
| (3 compose tests) | created by app | Part 3 (new convo) | Left in app |

## Summary

| Category | Result |
|----------|--------|
| Conversation open (few msgs) | ✅ 3ms (warm), 21ms (cold) |
| New conversation creation | ✅ 167ms median |
| Join via invite (total) | ✅ 2081ms |
| Join via invite (approval→ready) | ✅ ~1000ms |

All metrics within target. The v1 `join_convo_ready` "critical regression" was a false alarm caused by QA agent latency, not app performance. The `--watch` + `joinRequestSent` marker methodology now gives accurate measurements.
