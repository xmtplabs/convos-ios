# Structured QA Tests

YAML test definitions that the QA agent executes. Each file defines steps,
verifications, and criteria in a structured format that reduces interpretation
overhead and enables persistent state via CXDB.

## How the Agent Uses These

The agent is still agentic — it reads the YAML, translates actions into tool
calls, handles errors, and adapts when the UI doesn't match expectations. The
YAML is a **plan**, not a script.

### Execution flow

```
1. Read the YAML file
2. Check prerequisites (from CXDB run_state or by inspecting the app)
3. Run setup actions (create conversations, send messages, etc.)
4. For each step:
   a. Execute actions → translate to sim_* tool calls + CLI commands
   b. Run verify checks → translate to sim_find_elements / sim_wait_for_element
   c. Record criterion result to CXDB (pass/fail + evidence)
   d. Save state keys to CXDB
5. Run teardown
6. Update test_result in CXDB
```

### State and resumability

Each `save:` directive persists a value to CXDB. If the context window fills
and a new session picks up, it reads state from CXDB and knows:
- Which tests have completed
- Conversation IDs, message IDs, invite URLs still in play
- Where to resume

## Action Vocabulary

Actions map to simulator tools and CLI commands. The agent interprets these
and makes the appropriate tool calls.

### Simulator actions

| Action | Tool | Example |
|--------|------|---------|
| `tap: { id: "X" }` | `sim_tap_id(identifier: "X")` | Tap by accessibility ID |
| `tap: { label: "X" }` | `sim_tap_id(identifier: "X")` | Tap by label text |
| `tap: { x, y }` | `sim_ui_tap(x, y)` | Tap by coordinates |
| `tap: { id: "X", duration: N }` | `sim_ui_tap(..., duration: N)` | Long press |
| `double_tap_element: { label_contains: "X" }` | Find center via `sim_find_elements`, then parallel `idb ui tap` | Double-tap gesture |
| `wait_for_element: { id: "X", timeout: N }` | `sim_wait_for_element(identifier: "X", timeout: N)` | Wait for element |
| `find_elements: { pattern: "X" }` | `sim_find_elements(pattern: "X")` | Search elements |
| `type_in_field: { id: "X", text: "Y" }` | `sim_type_in_field(identifier: "X", text: "Y")` | Type in field |
| `screenshot: {}` | `sim_screenshot()` | Visual verification only |
| `swipe: { ... }` | `sim_ui_swipe(...)` | Swipe gesture |
| `key: { code: N }` | `sim_ui_key(keycode: N)` | Key press (41=Esc, 40=Return) |
| `wait: N` | `sleep N` | Pause N seconds |
| `launch_app` | `sim_launch_app(bundle_id: ...)` | Launch app |
| `read_clipboard` | `xcrun simctl pbpaste $UDID` | Read clipboard |

### CLI actions

| Action | Command |
|--------|---------|
| `cli_send_text: { conversation, text }` | `convos conversation send-text $id "$text" --env dev` |
| `cli_send_attachment: { conversation, path }` | `convos conversation send-attachment $id $path --env dev` |
| `cli_send_reaction: { conversation, message, action, emoji }` | `convos conversation send-reaction $id $msg $action "$emoji" --env dev` |
| `cli_read_messages: { conversation, sync, grep }` | `convos conversation messages $id --sync --env dev \| grep "$grep"` |
| `cli_join_conversation: { invite_url, profile_name }` | `convos conversations join "$url" --profile-name "$name" --env dev` |
| `cli_create_conversation: { name, profile_name }` | `convos conversations create --name "$name" --profile-name "$pn" --env dev` |
| `cli_generate_invite: { conversation }` | `convos conversation invite $id --env dev --json` |
| `cli_process_joins: { conversation, watch }` | `convos conversations process-join-requests --conversation $id [--watch] --env dev` |
| `explode_conversation: { id }` | `convos conversation explode $id --env dev` |
| `download_test_photo: { url, path }` | `curl -sL "$url" -o "$path"` |

### Verify checks

| Check | How |
|-------|-----|
| `element_exists: { id: "X" }` | `sim_find_elements(pattern: "X")` returns ≥1 result |
| `element_exists: { label_contains: "X" }` | `sim_find_elements(pattern: "X")` returns ≥1 result |
| `element_not_exists: { id: "X" }` | `sim_find_elements(pattern: "X")` returns 0 results |
| `element_enabled: { id: "X" }` | Element found and `enabled: true` |
| `element_count_gte: { pattern, min }` | Count of matching elements ≥ min |
| `element_near: { label, near_label }` | Both elements exist with close Y coordinates |
| `cli_output_contains: "X"` | CLI command output includes "X" |
| `clipboard_contains: "X"` | Clipboard text includes "X" |
| `visual_check: "description"` | Screenshot required — agent judges visually |

### Special fields

| Field | Purpose |
|-------|---------|
| `save: { key: value }` | Persist to CXDB test_state for this test |
| `criteria: key` | Links step to a pass/fail criterion |
| `known_issue: "description"` | Step may fail due to known bug — don't mark as regression |
| `note: "text"` | Hint for the agent on how to handle the step |
| `optional: true` | Step failure doesn't fail the test |
| `gesture: "description"` | Documents which gesture pattern to use |
| `on_system_dialog: "action"` | How to handle system dialogs (notifications, photos, etc.) |

## File Naming

Files match the test ID: `01-onboarding.yaml`, `02-send-receive-messages.yaml`, etc.
The corresponding `.md` file in `qa/tests/` remains as human-readable documentation.
