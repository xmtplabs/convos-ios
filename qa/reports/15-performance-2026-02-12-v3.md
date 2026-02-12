# Test Report: 15 - Performance Baselines (v3)

**Date:** 2026-02-12 (third run)
**Tester:** Claude Code (QA Agent)
**Build:** Dev (commit 3c8d51e8 — fixed message counting, joinRequestSent marker)
**Simulator:** iPhone — 57F6DAD0-4A9C-4CDF-BE00-4BFE2E54BDFB
**Duration:** ~15 minutes

## Result: PASS ✅

All metrics within target. Part 2 (many messages) now working correctly.

---

## Performance Results

| Metric | Run 1 | Run 2 | Run 3 | Median | Msgs | Target | Status |
|--------|-------|-------|-------|--------|------|--------|--------|
| open_few_msgs | 4ms | 4ms | 3ms | **4ms** | 48 | < 50ms | ✅ |
| open_many_msgs | 3ms | 4ms | 3ms | **3ms** | 50 | < 100ms | ✅ |
| new_convo_inbox | 138ms | 99ms | 99ms | **99ms** | - | < 500ms | ✅ |
| new_convo_ready | 227ms | 184ms | 182ms | **184ms** | - | < 1000ms | ✅ |
| join_convo_ready | 2300ms | — | — | **2300ms** | - | info only | ✅ |
| join_approval_to_ready | ~1000ms | — | — | **~1000ms** | - | < 5000ms | ✅ |

Status: ✅ = within target

---

## Detailed Observations

### Part 1: Open Existing Conversation (Few Messages) ✅

**Conversation:** "Somebodies" (f697f908), 48 messages in first page

| Run | Time | Messages | List Items |
|-----|------|----------|------------|
| 1 | 4ms | 48 | 16 |
| 2 | 4ms | 48 | 16 |
| 3 | 3ms | 48 | 16 |

### Part 2: Open Existing Conversation (Many Messages) ✅

**Conversation:** "Heavy v2" (b179e40455d12f9cd716efae887041d1), 101 messages in DB, 50 loaded per page

| Run | Time | Messages | List Items |
|-----|------|----------|------------|
| 1 | 3ms | 50 | 2 |
| 2 | 4ms | 50 | 2 |
| 3 | 3ms | 50 | 2 |

**Key fix from v1/v2:** Messages must be sent **after** the app joins — pre-join messages are hidden by design ("Earlier messages are hidden for privacy"). The PERF log was also fixed to count individual messages inside groups, not just list items (date separators + groups).

The 2 list items = 1 date separator + 1 message group (all 50 from same sender within same hour). The DB has 101 messages but `fetchInitial()` correctly caps at page size (50).

### Part 3: Create New Conversation ✅

| Run | inboxAcquired | ready | Origin |
|-----|--------------|-------|--------|
| 1 | 138ms | 227ms | existing |
| 2 | 99ms | 184ms | existing |
| 3 | 99ms | 182ms | existing |

### Part 4: Join Conversation via Invite ✅

Used `process-join-requests --watch` in background.

| Metric | Value |
|--------|-------|
| inboxAcquired | 77ms |
| joinRequestSent | 20:53:59 |
| ready | 2300ms total (origin: joined) |
| **approval_to_ready** | **~1000ms** |

---

## XMTP Errors Observed

No XMTP errors during test execution. Post-teardown errors from exploded conversations are expected and not listed.

---

## App-Level Errors Observed

After exploding test conversations, SQLite FOREIGN KEY constraint failures may occur when the app tries to store messages for deleted conversations. These are documented per RULES.md as real app-level errors worth tracking — a well-handled teardown should not produce constraint violations.

---

## Conversations Created & Cleaned Up

| Conversation | ID | Purpose | Cleaned |
|---|---|---|---|
| Heavy v2 | b179e40455d12f9cd716efae887041d1 | Part 2 (many messages) | ✅ Exploded |
| Join v3 | eafa18b70eeac07d1c3eea44dca74d55 | Part 4 (join invite) | ✅ Exploded |
| (3 compose tests) | created by app | Part 3 (new convo) | Left in app |

## Summary

| Category | Median | Target | Status |
|----------|--------|--------|--------|
| Open conversation (48 msgs) | 4ms | < 50ms | ✅ |
| Open conversation (50 of 101 msgs) | 3ms | < 100ms | ✅ |
| New conversation creation | 184ms | < 1000ms | ✅ |
| Join via invite (total) | 2300ms | info | ✅ |
| Join via invite (approval→ready) | ~1000ms | < 5000ms | ✅ |
