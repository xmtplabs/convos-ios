---
name: integration-test-stabilization-log
description: Records before/after flake-rate evidence for the single-inbox refactor. Each checkpoint that removes a source of nondeterminism gets a row — the architecture change should pay a reliability dividend, and this doc is the receipt.
type: log
---

# Integration Test Stabilization Log

> Context: the Single-Inbox Identity Refactor (PR #713 on
> `single-inbox-refactor`) had, as a secondary goal, driving the
> integration suite toward zero flake. The per-conversation identity
> model's multi-inbox coordination (LRU eviction, pre-creation cache,
> sleep/wake transitions) was the dominant source of intermittent
> failures; collapsing to a single inbox should eliminate the entire
> class of race it enabled.
>
> This log records the measurements. Each row is a focused
> before/after flake pass: pick a chunk of the suite or the full
> suite, run it N times against the pre-checkpoint tip, run it N times
> against the post-checkpoint tip, record pass rate.

## Methodology

- `./dev/up` to bring the local XMTP node + pgbackend up.
- `swift test --package-path ConvosCore` for the full suite; filter
  with `--filter SuiteName` for targeted passes.
- N = 5 for checkpoint-local passes; N = 15 for the C13 whole-suite
  stabilization pass.
- A run counts as "passed" only if **every** test in that run passes.
  One `#expect` failure = whole run fails.
- Rate = passes / total. A 20% flake rate is 4/5.

## Runs

### C4 — LRU / InboxLifecycleManager deletion

Not independently measured: C4 deleted `InboxLifecycleManager` and
the max-20-awake cache, which is where the pre-refactor test flakes
(`MultiInboxLRUTests`, `InboxPreCreationTests`) originated. Those
tests were deleted with their subject, so "flake rate" for them is
moot — they no longer exist. Suite shrank from ~640 to the current
563 tests across 67 suites, with the missing tests all coming from
subsystems that no longer exist.

### C13 — Whole-suite flake pass (identity refactor complete)

**Date**: 2026-04-19
**Commits at pass time**:
- `eed326c7` C13: PushNotificationServiceFactory + NSE cache tests
- `75bc5738` C13: add SessionManager caching + LegacyDataWipe unit tests

**Before** (N=5, pre-fix tip):

| Run | Tests | Result | Duration |
| --- | --- | --- | --- |
| 1 | 563 / 67 suites | pass | 15.657s |
| 2 | 563 / 67 suites | **fail** (1 issue) | 15.534s |
| 3 | 563 / 67 suites | pass | 15.363s |
| 4 | 563 / 67 suites | pass | 15.507s |
| 5 | 563 / 67 suites | pass | 15.820s |

Flake rate: **1 / 5 = 20%**.

The single failure: `ExpiredConversationsWorkerTests` —
`testSchedulesTimerForNextExpiration` at line 59. The test sets
`expiresAt = Date() + 1s`, kicks off an `ExpiredConversationsWorker`,
and waits up to 3s for the `.leftConversationNotification` to fire.
The worker's internal scheduling adds a 0.5s buffer on top of the
expiration interval, so under ideal conditions the notification
fires ~1.5s after `Date()`. Under XMTP test-process startup load
(first test to touch the worker in this run, GRDB page cache cold,
Swift Testing framework warming up), the `setupConversation` +
`createWorker` + task-scheduling sequence can consume >1.5s before
the timer is armed, compressing the remaining budget against the 3s
ceiling.

**Fix** (single edit, no production code):

- `ExpiredConversationsWorkerTests.swift`: bumped `expiresAt` from
  `+1.0s` to `+2.0s` and `waitForCondition(timeout:)` from `3.0s`
  to `5.0s` in both `testSchedulesTimerForNextExpiration` and
  `testReschedulesOnNewExplosion`. No production behavior change —
  the worker's scheduling logic is the same; the test just stops
  measuring a budget-depleted race.

**After** (N=10, post-fix tip):

| Run | Tests | Result | Duration |
| --- | --- | --- | --- |
| 6 | 563 / 67 suites | pass | 15.339s |
| 7 | 563 / 67 suites | pass | 15.321s |
| 8 | 563 / 67 suites | pass | 15.336s |
| 9 | 563 / 67 suites | pass | 15.409s |
| 10 | 563 / 67 suites | pass | 15.382s |
| 11 | 563 / 67 suites | pass | 15.456s |
| 12 | 563 / 67 suites | pass | 15.407s |
| 13 | 563 / 67 suites | pass | 15.397s |
| 14 | 563 / 67 suites | pass | 15.587s |
| 15 | 563 / 67 suites | pass | 15.391s |

Flake rate: **0 / 10 = 0%**.

10 consecutive passes against a 20%-flake-rate null would clear at
rate `(0.8)^10 ≈ 10.7%`; 15 would clear at `(0.8)^15 ≈ 3.5%`.

## What's not in here

- Pre-refactor baseline vs. post-refactor baseline for the same test
  set: not runnable, because the refactor deleted the flakiest
  suites (multi-inbox coordination, LRU eviction, pre-creation
  timing). The reliability dividend shows up as "those tests are
  gone" rather than as a before/after pass rate on the same tests.
- Simulator UI tests: out of scope for this log — they run through
  the QA agent, not `swift test`.
