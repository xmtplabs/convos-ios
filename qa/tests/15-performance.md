# Test: Performance Baselines

Measure and record performance metrics for critical user-facing operations. This test establishes baseline timings and detects regressions.

## Prerequisites

- The app is running with the instrumented build (contains `[PERF]` log lines).
- The convos CLI is initialized for the dev environment.
- At least one existing conversation with messages is visible in the conversations list.

## How Metrics Are Captured

The app emits `[PERF]` log lines at key checkpoints. After each action, use `sim_log_tail` with `level: "all"` and grep for `[PERF]` to extract timing data.

**Performance log format:**
```
[Convos] [PERF] ConversationViewModel.init: <ms>ms, <count> messages loaded
[Convos] [PERF] NewConversation.inboxAcquired: <ms>ms
[Convos] [PERF] NewConversation.creating: <ms>ms
[Convos] [PERF] NewConversation.joinRequestSent
[Convos] [PERF] NewConversation.ready: <ms>ms (origin: <created|joined|existing>)
```

**Note:** `joinRequestSent` has no duration — it's a timestamp marker. Compute `join_approval_to_ready` as the wall-clock delta between `joinRequestSent` and `ready (origin: joined)`.

## Steps

### Part 1: Open existing conversation (few messages)

Measures time to open a conversation with a small number of messages (< 50). If no existing conversation has enough messages, create one first:

1. Ensure a conversation exists with **at least 20 messages** of mixed content types. If not, create one:
   a. Create a conversation via CLI with a profile name.
   b. Generate an invite and join from the app (process join request in background, tap the quickname pill per ephemeral UI rules).
   c. Send a mix of messages from the CLI — short texts, longer paragraphs, and emoji-heavy messages:
      ```bash
      for i in $(seq 1 20); do
        convos conversations send-message --conversation <id> --text "Short message $i"
      done
      ```
   d. Wait a few seconds for messages to sync to the app.
2. Start from the conversations list. Get a log marker with `sim_log_tail`.
3. Tap on the conversation.
4. Wait for the conversation to load (message-text-field appears).
5. Read logs since the marker and extract the `[PERF] ConversationViewModel.init` line. Record the time in ms and message count.
6. Navigate back to the conversations list.
7. Repeat steps 3-6 two more times (3 total runs) to get a stable measurement. Record all 3 values.

### Part 2: Open existing conversation (many messages)

Measures time to open a conversation with enough messages to exceed the first paginated request (page size is 50). The conversation must have **at least 75 messages** with a variety of content types to be realistic.

**Important:** Messages sent before the app joins a conversation are intentionally hidden ("Earlier messages are hidden for privacy") and are never synced to the local database. All messages for this test must be sent **after** the app has joined the conversation.

8. Create a conversation specifically for this test:
   a. Create a conversation via CLI with a profile name.
   b. Generate an invite.
   c. Start `process-join-requests --watch` in the background, then open the invite in the app. Wait for the conversation to be joined (2 members visible).
   d. **After the app has joined**, send **100+ messages** from the CLI with mixed content — short messages, longer messages (2-3 sentences), messages with emoji, and some repeated patterns to simulate real conversation:
      ```bash
      for i in $(seq 1 40); do
        convos conversation send-text <id> "Message number $i - a short one" --env dev
      done
      for i in $(seq 1 30); do
        convos conversation send-text <id> "This is a longer message number $i. It has multiple sentences to simulate real conversation content. People often write paragraphs like this in group chats." --env dev
      done
      for i in $(seq 1 20); do
        convos conversation send-text <id> "🎉🔥👀 Emoji blast $i! 🚀✨💯" --env dev
      done
      for i in $(seq 1 10); do
        convos conversation send-text <id> "Final batch $i - wrapping up the conversation with some more messages to push well past the page boundary" --env dev
      done
      ```
   e. Wait 15-20 seconds for all messages to sync to the app's local database. Verify by scrolling the conversation to confirm messages are visible.
   f. Optionally verify the message count in GRDB directly:
      ```bash
      sqlite3 <path-to-convos.sqlite> "SELECT count(*) FROM message WHERE conversationId = '<id>' AND messageType != 'reaction';"
      ```
      Expect 50+ (the page size limit will cap `fetchInitial()` at 50, but the DB should have 100+).
9. Navigate back to conversations list. Get a log marker.
10. Tap on the heavy conversation.
11. Wait for the conversation to load.
12. Read logs and extract the `[PERF] ConversationViewModel.init` line. Confirm the message count is 50 (the page size limit — the DB has 100+ but the init only loads one page).
13. Navigate back and repeat 2 more times. Record all 3 values.

### Part 3: Create new conversation

Measures end-to-end time from tapping "compose" to the conversation being ready.

14. Start from the conversations list. Get a log marker.
15. Tap the compose button (`compose-button`).
16. Wait for the new conversation to appear (the QR code / invite view loads).
17. Read logs and extract all `[PERF] NewConversation.*` lines:
    - `inboxAcquired`: time to acquire an inbox identity
    - `creating`: time to enter the creating state (only if no pre-created conversation)
    - `ready`: total time from init to conversation ready
18. Dismiss the new conversation.
19. Repeat steps 15-18 two more times. Record all values.

### Part 4: Join conversation via invite

Measures time from opening a deep link invite to the conversation becoming ready.

**Important:** The `join_convo_ready` metric includes time waiting for the conversation creator to approve the join request, which is an external dependency. To minimize QA agent latency inflating this metric:
- Start `process-join-requests --watch` in a background process **before** opening the deep link, so approval happens as fast as the network allows.
- The logs emit `[PERF] NewConversation.joinRequestSent` when the app publishes the join request. Use the delta between `joinRequestSent` and `ready` as the `join_approval_to_ready` metric — this isolates the external wait + app processing from the initial setup time.

20. Create a conversation via CLI with a profile name.
21. Generate an invite.
22. Start `process-join-requests --watch` in a background process:
    ```bash
    convos conversations process-join-requests --watch --env dev &
    WATCH_PID=$!
    ```
23. Get a log marker.
24. Open the invite deep link in the app.
25. Wait for the conversation to become ready (the message input field appears and member count updates).
26. Stop the background watcher: `kill $WATCH_PID`
27. Read logs and extract `[PERF] NewConversation.*` lines. The `ready` line should show `origin: joined`. Also extract `joinRequestSent` to compute the approval-to-ready delta.
28. Record the timing values.

## Teardown

- Explode any conversations created during this test.
- Delete any test data from the CLI.

## Pass/Fail Criteria

This is a baseline measurement test — there are no hard pass/fail thresholds on the first run. Instead, record the results and compare to previous runs.

**Performance metrics to report:**

| Metric | Description | Target |
|--------|-------------|--------|
| `open_few_msgs` | ConversationViewModel.init with < 50 messages | < 50ms |
| `open_many_msgs` | ConversationViewModel.init with 100+ messages | < 100ms |
| `new_convo_inbox` | NewConversation.inboxAcquired | < 500ms |
| `new_convo_ready` | NewConversation.ready (origin: created or existing) | < 1000ms |
| `join_convo_ready` | NewConversation.ready (origin: joined), total time | informational* |
| `join_approval_to_ready` | Delta from joinRequestSent to ready (origin: joined) | < 5000ms |

*`join_convo_ready` includes external wait for the creator to approve the join request. The actual app performance metric is `join_approval_to_ready`, which measures from when the join request is published to when the conversation is ready. Use `--watch` on `process-join-requests` to minimize approval delay.

**Regression detection:** If any metric is more than 2x the target, flag it as a potential regression. If it's more than 5x, flag as a critical regression.

## Results Format

Report results as a table:

```
### Performance Results

| Metric | Run 1 | Run 2 | Run 3 | Median | Msgs | Status |
|--------|-------|-------|-------|--------|------|--------|
| open_few_msgs | Xms | Xms | Xms | Xms | N | ✅/⚠️/❌ |
| open_many_msgs | Xms | Xms | Xms | Xms | N | ✅/⚠️/❌ |
| new_convo_inbox | Xms | Xms | Xms | Xms | - | ✅/⚠️/❌ |
| new_convo_ready | Xms | Xms | Xms | Xms | - | ✅/⚠️/❌ |
| join_convo_ready | Xms | - | - | Xms | - | info only |
| join_approval_to_ready | Xms | - | - | Xms | - | ✅/⚠️/❌ |

Status: ✅ = within target, ⚠️ = 1-2x target, ❌ = > 2x target

### XMTP Errors Observed
(list any XMTP errors per RULES.md, noting whether they affected results)
```
