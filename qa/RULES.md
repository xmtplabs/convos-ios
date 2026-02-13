# QA Rules

General rules and conventions that apply to all QA test scenarios. Read this document fully before executing any test.

## Read-Only Policy

**The QA agent must never modify source code, project files, or configuration during testing.** The agent may read source files to gain context about what a test is exercising (e.g., understanding how a view is structured, what accessibility identifiers exist), but must not edit, create, or delete any project files.

The only files the agent may create or modify are:
- Test result reports (in `qa/reports/` or as directed by the user)
- QA process files (`qa/RULES.md`, `qa/tests/*.md`, `qa/tests/structured/*.yaml`) — see **Continuous Improvement** below
- CXDB database (`qa/cxdb/qa.sqlite`) — test execution state, results, and findings

If a test reveals a bug, the agent should document it with detailed repro steps, screenshots, and log excerpts — not attempt to fix it.

## Continuous Improvement

**The QA agent should actively improve the QA process as it learns.** If the agent discovers a more reliable or efficient way to perform a test step, it should update the relevant rules or test file so future runs benefit. This includes:

- **Fixing flaky steps.** If a step repeatedly fails due to timing, element lookup strategy, or ordering issues — and the agent finds a workaround that works — update the test instructions with the working approach (e.g., switching from identifier to label search, using `sim_tap_id` with retries instead of wait-then-tap, running commands in the background).
- **Adding missing context.** If a test step is ambiguous or missing detail that caused the agent to get stuck, clarify it. Add the accessibility identifier, label text, or exact UI flow that the step requires.
- **Documenting gotchas.** If something non-obvious is required for a step to succeed (e.g., a specific element only appears during an async operation, or a search must use label instead of identifier), add a note so the agent doesn't rediscover it next time.
- **Breaking out of loops.** If the agent catches itself retrying the same failing approach more than twice, it should stop, investigate the root cause (check source code for accessibility identifiers, read logs, try alternative lookup strategies), and update the test or rules with what it learns.

When updating QA files, keep changes focused and minimal — fix the specific issue encountered, don't rewrite entire sections speculatively.

- **Flagging hard-to-find UI elements.** If `sim_tap_id` cannot find an element by its expected identifier or label — requiring fallback to coordinate tapping, `sim_ui_describe_all`, or source code inspection — note it in the test report under a dedicated "Accessibility Improvements Needed" section. Include the element's purpose, what was tried, what worked, and a recommendation (e.g., "add `accessibilityIdentifier("compose-button")` to the bottom toolbar compose icon"). These reports drive accessibility improvements that make future QA runs more reliable and also improve VoiceOver support.

## Tools

You have two categories of tools for QA testing:

### iOS Simulator Tools

You have direct access to simulator tools for interacting with the Convos iOS app.

**Prefer the high-level tools** — they are faster and more reliable because they handle element lookup, coordinate calculation, and interaction in a single call:

- `sim_tap_id` — tap an element by accessibility identifier or label (searches id, then label, then substring). Supports retries for elements that may take time to appear.
- `sim_type_in_field` — find a text field by id/label, tap to focus, then type text. Optionally clears existing text first. Much more reliable than separate tap + type.
- `sim_wait_for_element` — poll until an element appears (useful after navigation or network actions). Configurable timeout and interval.
- `sim_find_elements` — search for elements matching a pattern, or list all elements with identifiers. Good for checking what's on screen.

**Log monitoring tools** — use these to detect app errors during testing:

- `sim_log_tail` — read recent app log lines, filtered by level (default: warning+error). Returns a `marker` timestamp for incremental reads.
- `sim_log_check_errors` — quick check for new errors since a marker. Returns errors if any, or confirms clean.

**Low-level tools** — use these when the high-level tools don't fit (e.g., tapping at a specific coordinate, swiping):

- `sim_screenshot` — take a screenshot to see the current state of the app
- `sim_ui_describe_all` — get the full accessibility tree as JSON
- `sim_ui_tap` — tap at specific x,y coordinates. Use `duration` param for long-press (e.g., `duration: 0.5` for message context menus, which require ≥0.3s)
- `sim_ui_swipe` — swipe between two points
- `sim_ui_type` — type text into the currently focused field
- `sim_ui_key` — press a key (40 = Return, 42 = Backspace, 41 = Escape)
- `sim_open_url` — open a URL in the simulator (for deep links)
- `sim_launch_app` — launch the app by bundle ID

**Gesture shortcuts via bash** — for gestures the sim tools can't express directly:

- **Double-tap** (e.g., to react to a message with ❤️): Run two `idb` taps in parallel. First find the element's center coordinates, then:
  ```bash
  IDB=/Users/jarod/Library/Python/3.9/bin/idb
  UDID=<simulator-udid>
  $IDB ui tap <x> <y> --udid $UDID & $IDB ui tap <x> <y> --udid $UDID & wait
  ```
  Both taps land within the UIKit double-tap time window (~300ms).
- **Long-press** (e.g., to open a message context menu): Use `sim_ui_tap` with `duration: 0.5`.

### Convos CLI

The `convos` CLI lets you act as another participant in conversations. It communicates over the same XMTP network the app uses. For full documentation on all available commands, read the convos-cli skill file at:

```
.pi/skills/convos-cli/SKILL.md
```

Always use `--json` when you need to extract data from CLI output programmatically. Always use `--env dev` when initializing (or ensure it has already been initialized for dev).

The CLI is the primary way to simulate "the other side" of a conversation — sending messages to the app, generating invites for the app to join, reacting to messages, and verifying what the app sent.

## App Details

- **Bundle ID:** `org.convos.ios-preview`
- **Scheme:** `Convos (Dev)`
- **Environment:** dev
- **Deep link domains:** `dev.convos.org`, `app-dev.convos.org`
- **Deep link format:** `https://dev.convos.org/v2?i=<invite-slug>`
- **Custom URL scheme:** `convos-dev://`

## Simulator Selection

All QA tests must run on the simulator for the current branch. To determine the correct simulator:

1. Read `.claude/.simulator_id` — if it exists, use that UDID.
2. Otherwise, read `.convos-task` — if it exists, use the `SIMULATOR_NAME` value to look up the UDID via `xcrun simctl list devices -j`.
3. Otherwise, derive the simulator name from the git branch (replace `/` and special chars with `-`, prefix with `convos-`), then look up the UDID.

Pass the resolved UDID to every simulator tool call (the `udid` parameter). Also pass it to any `xcrun simctl` commands (use the UDID instead of `booted`).

At the start of a QA session, resolve the UDID once and reuse it for all subsequent operations.

## CXDB — Persistent Test State

CXDB (`qa/cxdb/qa.sqlite`) stores test results, state, and findings across context windows. Use `qa/cxdb/cxdb.sh` to interact with it.

### Session Start

At the start of every QA session:

```bash
CXDB=qa/cxdb/cxdb.sh

# Check for an incomplete run to resume
ACTIVE=$($CXDB active-run)
if [ -n "$ACTIVE" ]; then
    echo "Resuming run $ACTIVE"
    $CXDB all-state "$ACTIVE"          # Load conversation IDs, etc.
    $CXDB pending-tests "$ACTIVE" "01,12,03,..."  # See what's left
else
    # Start a new run
    RUN=$($CXDB new-run "$UDID" "$(git rev-parse --short HEAD)" "iPhone")
fi
```

### During Each Test

```bash
TR=$($CXDB start-test "$RUN" "05" "Reactions")

# After each criterion check:
$CXDB record-criterion "$TR" "cli_reaction_text_visible" "pass" "CLI reaction on text appears" "👍 found near message"

# Persist state for future tests or session resume:
$CXDB set-state "$RUN" "05" "conversation_id" "$CONV_ID"
$CXDB set-state "$RUN" "_run" "shared_conversation_id" "$CONV_ID"  # run-level state

# Log errors and findings:
$CXDB log-error "$RUN" "05" "$TIMESTAMP" "ConvosCore" "$ERROR_MSG" "0"
$CXDB log-bug "$RUN" "05" "major" "Title" "Description"
$CXDB log-a11y "$RUN" "05" "element purpose" "recommendation"

# When done:
$CXDB finish-test "$TR" "pass"
```

### After All Tests

```bash
$CXDB finish-run "$RUN"                    # Derives status from test results
$CXDB report-md "$RUN" > qa/reports/run-$RUN.md  # Generate markdown report
$CXDB summary "$RUN"                       # Quick console summary
```

### Structured Tests

When a structured YAML test exists in `qa/tests/structured/`, prefer it over the markdown version. The YAML defines explicit actions, verifications, and criteria that reduce interpretation overhead. The agent still adapts and recovers from errors — the YAML is a plan, not a script.

## General Testing Rules

### Simulator Preparation

At the start of a QA session (before any tests), disable animations on the simulator to speed up test execution and eliminate timing issues caused by transitions:

```bash
UDID=<simulator-udid>
xcrun simctl spawn $UDID defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
xcrun simctl spawn $UDID defaults write -g UIAnimationDragCoefficient -int 0
```

Then relaunch the app so it picks up the Reduce Motion setting. These persist across app launches until the simulator is erased.

### Before Each Test

1. Resolve the simulator UDID as described above.
2. Take a screenshot to understand the current state of the app.
3. If the test has prerequisites, verify them before proceeding.
4. If the test requires a fresh app state, follow the reset procedure described in the test.

### Interacting with the App

- **Use `sim_tap_id` to tap elements** — pass the accessibility identifier or label text. Do not manually look up coordinates and call `sim_ui_tap` unless there is no identifier available.
- **Use `sim_type_in_field` to enter text** — pass the text field's accessibility identifier and the text to type. Do not manually tap then type.
- **Use `sim_wait_for_element` after navigation or network actions** — it polls until the element appears, avoiding manual sleep + screenshot loops.
- **Use `sim_find_elements` to check what's on screen** — search by pattern or list all identifiable elements. More targeted than `sim_ui_describe_all`.
- If a UI element is not immediately visible, try scrolling or use `sim_wait_for_element` with a timeout.
- **Never sleep — wait for elements instead.** If you know the accessibility identifier or label of the next element you need, use `sim_wait_for_element` to poll for it. This is faster (returns as soon as the element appears) and more reliable (fails with a clear timeout instead of silently proceeding too early). Only use `sleep` as a last resort when there is genuinely no element to wait for (e.g., after a dismiss gesture where you need the UI to settle). Even then, keep it under 1 second.
- **SwiftUI toolbar items are hidden from tree traversal.** Buttons inside `.toolbar { }` (e.g., `compose-button`, `scan-button`) exist and have correct accessibility identifiers, but `sim_find_elements`, `sim_tap_id`, and `sim_wait_and_tap` cannot find them because `idb ui describe-all` does not enumerate children of the system `Toolbar` group. Use `sim_ui_describe_point` to confirm they exist at specific coordinates, then tap with `sim_ui_tap`. Known toolbar buttons and their approximate centers:
  - `compose-button` ("Start a new conversation"): **(386, 904)**
  - `scan-button` ("Scan to join a conversation"): **(338, 904)**

### Verifying Results: Accessibility Tree vs Screenshots

**Prefer the accessibility tree** — it's structured, fast, and deterministic. Use `sim_find_elements`, `sim_wait_for_element`, or `sim_ui_describe_all` to verify:
- An element exists or appeared (e.g., message bubble with expected label)
- Text content, labels, and values are correct
- Element state (enabled/disabled, checked/unchecked)
- Navigation completed (expected screen identifiers present)
- List contents (conversation names, message text)
- Custom actions available on an element (e.g., "React", "Reply", "Mute")

**Use screenshots only when visual verification is required:**
- Image/photo rendering (did an attachment actually display?)
- Layout verification (split view, positioning, spacing)
- Visual styling that accessibility doesn't capture (colors, emoji rendering size)
- Debugging when the accessibility tree doesn't match expectations
- First look at an unfamiliar screen to orient before interacting

**Do not use screenshots to:** check if a button exists, read text labels, verify navigation happened, or confirm a message appeared. The accessibility tree handles all of these faster and more reliably.

### Log Monitoring

App logs must be monitored throughout every test to catch errors early.

**Setup:** At the start of each test, call `sim_log_tail` to get the current marker timestamp. This establishes a baseline — any errors from before the test starts are ignored.

**During the test:** After each major step (e.g., joining a conversation, sending a message, navigating to a new screen), call `sim_log_check_errors` with the current marker. This checks for new error-level logs since the last check.

**If an error is detected:** Classify it before deciding whether to stop.

**XMTP / network-layer errors** — these originate from the XMTP SDK and often look like:
```
XMTPiOS.FfiError.Error(message: "[GroupError::Sync] Group error: synced N messages, ...")
Error updating profile display name: XMTPiOS.FfiError.Error(...)
[GroupError::Sync] ...
```
These errors are frequently transient — XMTP may log an error even when the operation partially succeeded or will succeed on retry. **Do not stop the test for XMTP-layer errors.** Instead:
1. Note the error in the test results (include the full log line).
2. Continue executing the test steps.
3. Judge pass/fail based on the **end result in the app** — did the UI show the correct state? Did the expected data appear? If the app behaves correctly despite the XMTP error, the test step passes. If the app shows incorrect state (e.g., profile name reverts, message not delivered, conversation stuck), then the step fails and the XMTP error is noted as the likely cause.

**App-level errors** — these are errors from Convos application code that indicate unexpected failures (crashes, unhandled exceptions, assertion failures, database errors). Stop the test and record the failure:
1. Take a screenshot of the current app state.
2. Call `sim_log_tail` with `level: "all"` and the marker to capture the full log context around the error.
3. Record the failure with:
   - The test step that was being executed when the error occurred.
   - The exact error log line(s).
   - The full log context (10-20 lines before and after the error).
   - A screenshot of the app at the time of failure.
   - The sequence of actions taken up to this point (repro steps).
4. Report the failure as described in the Test Results section.

**How to tell the difference:** XMTP errors contain `XMTPiOS`, `FfiError`, `GroupError`, `Sync`, or `libxmtp` in the message. App errors come from Convos namespaces (`[Convos]`, `[ConvosCore]`) without an XMTP error wrapper, or indicate logic failures (nil unwraps, missing data, database constraint violations).

**Database errors are always app-level errors.** SQLite errors (`SQLite error`, `FOREIGN KEY constraint failed`, `UNIQUE constraint failed`, `NOT NULL constraint failed`, etc.) indicate a real problem in the app's data layer — even when they occur after an XMTP operation or during teardown. These should always be reported with full context, including:
- The exact SQL operation that failed (the log usually includes the SQL statement).
- What the app was doing at the time (e.g., processing an incoming message, exploding a conversation).
- Whether the error had a visible effect on the UI.

Do not dismiss database errors as "expected after teardown" — a well-handled teardown should not produce constraint violations. If exploding a conversation causes FOREIGN KEY failures, that means the app is receiving and trying to store messages for a conversation that has already been deleted from the local database, which is a bug worth tracking.

**Warnings:** Warnings do not stop the test, but should be noted in the test results. Some warnings are expected (e.g., stream reconnection warnings). Use judgment about whether a warning pattern is concerning.

**Log format:** Each log line looks like:
```
[2026-02-12T07:24:16Z] [error] [Logger.swift:32] [ConvosCore] Failed processing group message: ...
```
The fields are: `[timestamp] [level] [source file:line] [namespace] message`

### Waiting and Timing

- After sending a message via CLI, wait at least 3-5 seconds before checking the app UI.
- After opening a deep link, wait 2-3 seconds for the app to process it.
- If something hasn't appeared after a reasonable wait, retry once before marking as failed.
- Use screenshots as the primary way to verify visual state.

### Ephemeral / Auto-Dismissing UI

Some UI elements appear briefly and auto-dismiss after a few seconds (e.g., onboarding pills, quickname pills, success confirmations). These require fast detection:

- **Start polling BEFORE the trigger completes.** Many ephemeral elements appear during an async operation (e.g., the quickname pill appears while `process-join-requests` is still running). If you wait for the CLI command to finish before polling, the pill may already be gone. Run the CLI command **in the background** (append `&` in bash) and start tapping **immediately** — do not wait for the background command to complete.
- **Use `sim_tap_id` with `retries` to find-and-tap in one atomic operation.** Do not use `sim_wait_for_element` followed by a separate `sim_tap_id` — the element can auto-dismiss between the two calls. `sim_tap_id` with retries polls and taps the instant it finds the element.
- **Search by label text, not accessibility identifier.** Some elements' accessibility identifiers are not reliably found when nested inside overlay/drawer views. Use a substring of the label instead (e.g., `"Tap to chat"` for the quickname pill).
- **Use `sim_find_elements` as a fallback** if `sim_tap_id` exhausts retries — to check whether the element appeared and dismissed between polls.
- If a test step says "look for" an ephemeral element, the sequence should be: start the trigger in the background → immediately call `sim_tap_id` with retries → then screenshot to verify the result after tapping.

**Example pattern for invite + quickname pill:**
```
# 1. Open invite in app
sim_open_url ...
sleep 3

# 2. Start join processing in background AND tap simultaneously
# These two calls must be made in the SAME function_calls block so they run in parallel:
bash: convos conversations process-join-requests --conversation <id> &
sim_tap_id: identifier="Tap to chat", retries=30

# 3. Screenshot to verify the result
sim_screenshot
```

Known ephemeral elements:
- **Quickname pill**: appears above the composer when entering a new conversation with a quickname set. Search using label substring `"Tap to chat"` (full label is like `"UQ, Tap to chat as Updated QN"`). Accessibility identifier is `add-quickname-button` but may not be found reliably — prefer label search. Auto-dismisses after ~8 seconds.
- **Setup quickname prompt**: appears during first-conversation onboarding. Search using label `"Add your name for this convo"` or identifier `setup-quickname-button`. Does not auto-dismiss (requires interaction).
- **Saved/success confirmations**: brief confirmations that auto-dismiss after ~3 seconds.

### Verifying Results

Each test has explicit pass/fail criteria. For each criterion:

- **Use the accessibility tree** (`sim_ui_describe_all`) to verify text content, element presence, and values.
- **Use screenshots** to verify visual layout and state that the accessibility tree cannot capture.
- **Use CLI commands** (with `--json --sync`) to verify what the app sent over the network.

### Resetting the Simulator

When a test requires a completely fresh state (no prior app data):

1. Terminate the app: `xcrun simctl terminate <UDID> org.convos.ios-preview`
2. Erase the simulator: `xcrun simctl erase <UDID>`
3. Reinstall and relaunch the app using the build and install procedure from the run skill.

Use the resolved simulator UDID — never use `booted` as there may be multiple simulators running.

Note: erasing the simulator also clears notification permissions and other system-level state. The app will need to be reinstalled after erase.

### Resetting the CLI

When a test requires fresh CLI state:

1. Remove all CLI identities and databases: `rm -rf ~/.convos/identities ~/.convos/db`
2. Re-initialize if needed: `convos init --env dev --force`

### Handling Onboarding

When the app launches for the first time (or after a reset), the conversation creation flow includes an onboarding sequence:

1. After creating a conversation, a "setup quickname" prompt appears at the bottom of the conversation.
2. The onboarding also includes a notification permission request.

Unless the test is specifically about onboarding, complete or dismiss onboarding steps as quickly as possible to get to the feature being tested.

### Processing Invites

The invite flow is multi-step and requires coordination between the inviting side and the joining side:

1. The creator generates an invite (via CLI or app UI).
2. The joiner opens the invite (via deep link, QR scan, or paste).
3. The creator must process the join request for the joiner to be added.

**Critical ordering: The app must open the invite FIRST, before the CLI runs `process-join-requests`.** The join request does not exist until the app opens the invite link and sends a join request to the network. Running `process-join-requests` before the app has opened the invite will find nothing to process and silently succeed, leaving the joiner stuck.

**Correct sequence:**
1. Generate the invite via CLI.
2. Open the invite in the app (via `sim_open_url` deep link, QR scan, or paste).
3. Wait 2-3 seconds for the app to process the deep link and send the join request.
4. **Then** run `process-join-requests` from the CLI.

**Always use `--watch` with `--timeout`** when running `process-join-requests`. The join request may take a moment to arrive over the network. Example:
```bash
convos conversation process-join-requests <convo-id> --watch --timeout 30
```
Never run `process-join-requests` without `--timeout` — it can hang indefinitely with `--watch`, or miss the request without `--watch`. A 30-second timeout is a safe default.

### Test Results

After completing a test, report results clearly:

- List each pass/fail criterion with its status.
- Include relevant screenshots for any failures.
- Note any unexpected behavior even if the test passed.
- If the test failed due to infrastructure issues (simulator crash, network timeout), note that separately from app bugs.
- Include any warnings from the log monitoring, noting whether they seem expected or concerning.
- **Log every error to CXDB every time it appears** — even if you've seen the same error in previous runs. Use `$CXDB log-error` for each error line. Recurrence frequency is valuable data; dismissing repeat errors hides patterns. Mark XMTP-layer errors with `is_app_error=0` and app-level errors with `is_app_error=1`.
- **XMTP errors:** List all XMTP-layer errors observed during the test in a dedicated section, even if the test passed. Note whether each error appeared to affect the app's behavior or was transient/innocuous. This helps track XMTP SDK issues over time without conflating them with app bugs.

**When a test fails (either from pass/fail criteria or from a log error), include a failure report:**

```
### Failure: <brief description>

**Step:** <which test step was being executed>
**Type:** <log error | UI assertion | crash | timeout>

**Repro Steps:**
1. <step 1 that was taken>
2. <step 2>
3. ...
N. <step where failure occurred>

**Error Logs:**
<paste the relevant error log lines>

**Log Context:**
<paste ~10-20 lines of surrounding logs for context>

**Screenshot:** <include a screenshot if applicable>

**Notes:** <any additional observations about the failure>
```

This format ensures anyone reading the report can reproduce the issue without needing to re-run the test.

## Test Assets

### Photos / Images

When a test needs to send a photo or image attachment, download one from picsum:

```bash
curl -sL "https://picsum.photos/850/650" -o /tmp/test-photo.jpg
```

Do not try to generate images with ImageMagick, Pillow, or raw bytes — those tools may not be installed and produce corrupt files. Picsum always returns a valid JPEG.

## Message Content Types

The app supports these message content types:
- **text** — plain text messages
- **emoji** — single emoji messages (displayed larger)
- **attachments** — images and files
- **reply** — messages that reference another message
- **reaction** — emoji reactions on existing messages

When a test requires reacting to "all content types," this means reacting to text messages, emoji messages, and attachment messages at minimum.
