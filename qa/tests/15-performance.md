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
[Convos] [PERF] NewConversation.ready: <ms>ms (origin: <created|joined|existing>)
```

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

8. Create a conversation specifically for this test:
   a. Create a conversation via CLI with a profile name.
   b. Generate an invite and join from the app (process join request in background, tap the quickname pill per ephemeral UI rules).
   c. Send **100+ messages** from the CLI with mixed content — short messages, longer messages (2-3 sentences), messages with emoji, and some repeated patterns to simulate real conversation:
      ```bash
      for i in $(seq 1 40); do
        convos conversations send-message --conversation <id> --text "Message number $i - a short one"
      done
      for i in $(seq 1 30); do
        convos conversations send-message --conversation <id> --text "This is a longer message number $i. It has multiple sentences to simulate real conversation content. People often write paragraphs like this in group chats."
      done
      for i in $(seq 1 20); do
        convos conversations send-message --conversation <id> --text "🎉🔥👀 Emoji blast $i! 🚀✨💯"
      done
      for i in $(seq 1 10); do
        convos conversations send-message --conversation <id> --text "Final batch $i - wrapping up the conversation with some more messages to push well past the page boundary"
      done
      ```
   d. Wait 10-15 seconds for all messages to sync to the app. Open the conversation and scroll to verify messages loaded.
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

20. Create a conversation via CLI with a profile name.
21. Generate an invite.
22. Get a log marker.
23. Open the invite deep link in the app. Wait 2-3 seconds.
24. Process the join request in the background and tap the quickname pill (per ephemeral UI rules).
25. Read logs and extract `[PERF] NewConversation.*` lines. The `ready` line should show `origin: joined`.
26. Record the timing values.

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
| `join_convo_ready` | NewConversation.ready (origin: joined) | < 5000ms |

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
| join_convo_ready | Xms | - | - | Xms | - | ✅/⚠️/❌ |

Status: ✅ = within target, ⚠️ = 1-2x target, ❌ = > 2x target

### XMTP Errors Observed
(list any XMTP errors per RULES.md, noting whether they affected results)
```
