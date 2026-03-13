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

## Prerequisites

The `prerequisites` block declares what must be true before a test starts.
Boolean flags (`app_running`, `cli_initialized`, `shared_conversation`) are
checked or established by the agent. The `screen` key is special — it tells
the agent which app screen must be visible before step 1 begins.

### `screen` prerequisite

If the app is on the wrong screen (e.g., stuck in a conversation from a prior
test), the agent must navigate to the required screen before proceeding. This
prevents flaky test starts caused by leftover navigation state.

| Screen ID | How the agent verifies it | How the agent navigates to it |
|-----------|--------------------------|-------------------------------|
| `conversations_list` | `compose-button` is visible | Tap `BackButton` or `close-new-conversation` repeatedly until `compose-button` appears |
| `conversation_detail` | `message-text-field` is visible and `BackButton` exists | Navigate from `conversations_list`, then tap the target conversation |
| `settings` | `settings-view` is visible | Tap settings tab or gear icon from `conversations_list` |
| `profile_editor` | `profile-display-name-field` is visible | Open from settings or conversation toolbar |

If `screen` is omitted, the agent checks current state and navigates as
needed based on the first step's actions (legacy behavior).

**Example:**
```yaml
prerequisites:
  app_running: true
  screen: conversations_list
```

The agent would do something like:
```
1. sim_find_elements(pattern: "compose-button")
2. If not found → tap BackButton / close-new-conversation until it appears
3. If still not found after 3 attempts → fail prerequisite
```

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
| `long_press: { label_contains: "X", duration: N }` | `sim_ui_tap(x, y, duration: N)` | Long press on element (find center first) |
| `tap_reaction_picker: { emoji: "X" }` | Find picker emoji center, `sim_ui_tap(x, y)` | Tap an emoji in the reaction picker bar |
| `tap_outside_drawer: { y: N }` | `sim_ui_tap(200, N)` | Tap outside a drawer/sheet to dismiss |
| `launch_app` | `sim_launch_app(bundle_id: ...)` | Launch app |
| `read_clipboard` | `xcrun simctl pbpaste $UDID` | Read clipboard |
| `clear_clipboard` | `echo -n "" \| xcrun simctl pbcopy $UDID` | Clear clipboard before copy |

### No sleep — wait for elements

Never use `wait: N` or `sleep` in YAML steps. Instead, use `wait_for_element`
targeting the element you expect to appear next. This is both faster (returns
as soon as the element appears) and more reliable (fails with a clear timeout
instead of silently proceeding too early or waiting too long).

After CLI actions (send-text, send-reaction), immediately poll for the
expected result in the app using `wait_for_element` with a timeout. After
navigation actions (tap, dismiss), wait for the destination screen's key
element. See `qa/RULES.md` "No Sleep Calls" for the full rationale.

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

### Event verification

| Check | How |
|-------|-----|
| `expect_event: "message.sent"` | After the step, check `sim_log_events` for this event |
| `expect_events: ["message.sent", "sync.completed"]` | Multiple events expected |
| `expect_event_with: { name: "message.sent", conversation: "$conversation_id" }` | Event with specific params |

Events provide a positive verification channel — they confirm the app performed an action
internally, not just that the UI updated. Use alongside `verify` checks for stronger assertions.

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
| `expect_event: "event.name"` | Verify the app emitted this [EVENT] after the step |
| `expect_events: [...]` | Verify multiple [EVENT]s after the step |

## Validated Tests

Tests that have been run against the live iOS app in the simulator and
had their YAMLs corrected to match actual UI behavior.

| Test | Status | Key Findings |
|------|--------|-------------|
| 01 | ✅ | Fresh onboarding flow |
| 02 | ✅ | Send/receive text messages |
| 05 | ✅ | Reactions via long-press picker |
| 06 | ✅ | Replies (streaming issue: CLI reply may need app re-entry) |
| 09 | ✅ | Explode uses 3s tap-and-hold, not confirm dialog |
| 10 | ✅ | Pin/unpin; pinned tile is large circular avatar |
| 11 | ✅ | Mute/unmute; bell.slash.fill / bell.fill icons |
| 12 | ✅ | Create conversation from app |
| 16 | ✅ | 4 filters: All, Unread, Exploding, Pending invites |
| 17 | ✅ | Swipe actions: full labels "Mark as read" / "Mark as unread" |
| 18 | ✅ | Delete all data: hold-to-delete 3.5s, returns to onboarding |
| 21 | ✅ | Context menu: 6 quick emojis + Reply + Copy; swipe-to-reply |
| 22 | ✅ | Rejoin via deep link navigates to existing conversation |
| 23b | ✅ | Scheduled explode: red countdown in title, auto-cleanup |

| 14 | ✅ | Quickname not auto-applied; needs banner tap; name changes retroactive |
| 07 | ✅ | Profile edit via quick-edit; group_updated messages sent to participants |
| 08 | ✅ | Lock/unlock at XMTP level; lock icon in toolbar; no info page indicator |
| 20 | ❌ | BUG: sender sees "Failed to load" for own sent photo; receive/reveal works |
| 23 | ✅ | Pending shows "verifying" with draft-UUID id; restricted actions; filter works |
| 19 | ✅ | Profile photo via quick-edit; group photo via Edit info; both display in list |
| 24 | ✅ | Navigate away safe; discovery sync detects recovery within 10s; fully functional |
| 03 | ✅ | Online flow validated via CLI; offline inviter scenario needs two app instances |
| 04 | ✅ | Paste join via scan view works; paste-invite-button; system paste permission dialog |
| 13 | ⏭️ | No schema changes on branch; main=dev same commit; not applicable |
| 15 | ✅ | ConversationViewModel.init: 2-5ms; new convo: 128ms (reuse) / 1068ms (create) |

All 25 tests validated. 23 pass, 1 fail (test 20), 1 skip (test 13).

### Bugs Found
| Test | Severity | Description |
|------|----------|-------------|
| 20 | Medium | Sender sees "Failed to load" for own sent photo (transient — resolves on re-entry) |

### Performance Baselines
| Metric | Value | Target |
|--------|-------|--------|
| ConversationViewModel.init (100+ msgs) | 5ms median | < 50ms |
| ConversationViewModel.init (1 msg) | 2ms median | < 50ms |
| New conversation (inbox reuse) | 128ms | < 1000ms |
| New conversation (XMTP creation) | 1068ms | < 1000ms |
| New conversation inboxAcquired | 52-107ms | < 500ms |

## File Naming

Files match the test ID: `01-onboarding.yaml`, `02-send-receive-messages.yaml`, etc.
The corresponding `.md` file in `qa/tests/` remains as human-readable documentation.
