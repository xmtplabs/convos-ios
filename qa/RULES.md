# QA Rules

General rules and conventions that apply to all QA test scenarios. Read this document fully before executing any test.

## Tools

You have two categories of tools for QA testing:

### iOS Simulator Tools

You have direct access to simulator tools for interacting with the Convos iOS app.

**Prefer the high-level tools** — they are faster and more reliable because they handle element lookup, coordinate calculation, and interaction in a single call:

- `sim_tap_id` — tap an element by accessibility identifier or label (searches id, then label, then substring). Supports retries for elements that may take time to appear.
- `sim_type_in_field` — find a text field by id/label, tap to focus, then type text. Optionally clears existing text first. Much more reliable than separate tap + type.
- `sim_wait_for_element` — poll until an element appears (useful after navigation or network actions). Configurable timeout and interval.
- `sim_find_elements` — search for elements matching a pattern, or list all elements with identifiers. Good for checking what's on screen.

**Low-level tools** — use these when the high-level tools don't fit (e.g., tapping at a specific coordinate, swiping):

- `sim_screenshot` — take a screenshot to see the current state of the app
- `sim_ui_describe_all` — get the full accessibility tree as JSON
- `sim_ui_tap` — tap at specific x,y coordinates
- `sim_ui_swipe` — swipe between two points
- `sim_ui_type` — type text into the currently focused field
- `sim_ui_key` — press a key (40 = Return, 42 = Backspace, 41 = Escape)
- `sim_open_url` — open a URL in the simulator (for deep links)
- `sim_launch_app` — launch the app by bundle ID

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

## General Testing Rules

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
- After an action, take a screenshot to visually confirm the result when the accessibility tree alone is insufficient.
- If a UI element is not immediately visible, try scrolling or use `sim_wait_for_element` with a timeout. Network-dependent actions (like messages arriving from the CLI) may take several seconds.

### Waiting and Timing

- After sending a message via CLI, wait at least 3-5 seconds before checking the app UI.
- After opening a deep link, wait 2-3 seconds for the app to process it.
- If something hasn't appeared after a reasonable wait, retry once or twice with increasing delays before marking as failed.
- Use screenshots as the primary way to verify visual state.

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

When using the CLI as the creator, always run `process-join-requests` after the app has opened the invite. Use `--watch` with a timeout if the timing is uncertain.

### Test Results

After completing a test, report results clearly:

- List each pass/fail criterion with its status.
- Include relevant screenshots for any failures.
- Note any unexpected behavior even if the test passed.
- If the test failed due to infrastructure issues (simulator crash, network timeout), note that separately from app bugs.

## Message Content Types

The app supports these message content types:
- **text** — plain text messages
- **emoji** — single emoji messages (displayed larger)
- **attachments** — images and files
- **reply** — messages that reference another message
- **reaction** — emoji reactions on existing messages

When a test requires reacting to "all content types," this means reacting to text messages, emoji messages, and attachment messages at minimum.
