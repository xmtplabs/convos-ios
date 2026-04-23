# QA Tools — Claude Code mapping

`qa/RULES.md` and the structured YAMLs in `qa/tests/structured/` describe actions using pi's `sim_*` vocabulary (`sim_tap_id`, `sim_wait_for_element`, `sim_log_tail`, etc.). When the QA agent runs under **Claude Code**, those vocabulary terms are the *plan* — the agent translates each one into the tools it actually has.

## Tool landscape

Three layers are available; prefer them in this order:

1. **Bash + `idb` + `xcrun simctl`** (primary). `idb ui` subcommands (`tap`, `describe-all`, `describe-point`, `text`, `key`, `swipe`, `button`) provide the closest match to pi's `sim_*` vocabulary. `xcrun simctl` covers app lifecycle, pasteboard, URL opening, and log access. This is what the validated smoke run used end-to-end.
2. **MCP tools** — `XcodeBuildMCP` (`mcp__XcodeBuildMCP__tap`, `snapshot_ui`, `long_press`, `swipe`, `type_text`, `key_press`, `gesture`, `screenshot`, `launch_app_sim`, `install_app_sim`, `boot_sim`, `erase_sims`, `list_sims`) and `ios-simulator` (`mcp__ios-simulator__ui_find_element`, `ui_describe_all`, `ui_tap`, `ui_describe_point`). These are available in the top-level session but **may not be exposed to every subagent context**; if a runner finds MCP tools absent, it should fall through to the Bash primary path without reporting the gap as a blocker.
3. **Build** — always via `xcodebuild` directly (the `build_sim` MCP tool has a known SPM-extension bug for this project; see `CLAUDE.md`).

## UDID & paths resolved once per session

```bash
UDID=$(cat .claude/.simulator_id)
IDB=/Users/jarod/Library/Python/3.9/bin/idb   # not on PATH by default
BUNDLE_ID=org.convos.ios-preview

# App group log file — the authoritative source for [EVENT] and [error] lines
APP_GROUP=$(find ~/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Shared/AppGroup -name "convos.log" -type f 2>/dev/null | head -1)
# APP_GROUP ends in .../AppGroup/<uuid>/Logs/convos.log
```

Pass `$UDID` to every `idb` and `xcrun simctl` command.

## Action vocabulary → Claude

### Tapping

| pi action | Primary (Bash+idb) | MCP fallback |
|-----------|---------------------|--------------|
| `sim_tap_id(identifier="X")` | `$IDB ui describe-all --udid $UDID \| jq -r 'recurse \| objects \| select(.AXUniqueId == "X") \| .frame' \| ...` → compute center → `$IDB ui tap <cx> <cy> --udid $UDID`. Full recipe under "Known action → recipe map" below. | `mcp__XcodeBuildMCP__tap({ accessibilityId: "X", simulatorUuid: UDID })` |
| `sim_tap_id(label="X")` — exact | Same, filter on `AXLabel == "X"` | `mcp__XcodeBuildMCP__tap({ accessibilityLabel: "X", simulatorUuid: UDID })` |
| substring/label-contains | filter `(.AXLabel // "") \| contains("X")` | `mcp__ios-simulator__ui_find_element({ search: ["X"], udid: UDID })` → frame center → idb tap |
| `sim_ui_tap(x, y)` | `$IDB ui tap <x> <y> --udid $UDID` | `mcp__XcodeBuildMCP__tap({ x, y, simulatorUuid: UDID })` |
| long press at (x,y) | `$IDB ui tap <x> <y> --duration <s> --udid $UDID` | `mcp__XcodeBuildMCP__long_press({ x, y, duration, simulatorUuid: UDID })` |
| double-tap | Two parallel idb taps within ~300ms: `$IDB ui tap <x> <y> --udid $UDID & $IDB ui tap <x> <y> --udid $UDID & wait` | `mcp__XcodeBuildMCP__gesture({ preset: "double_tap", x, y, simulatorUuid: UDID })` |

### Bottom-toolbar caveat (`compose-button`, `scan-button`)

These buttons are *not* enumerated by `idb ui describe-all` — they live in a SwiftUI `ToolbarItem(placement: .bottomBar)`. MCP's `snapshot_ui` finds them; idb misses them. Options:
- If MCP is available in your context, `mcp__XcodeBuildMCP__tap({ accessibilityId: "compose-button" })` works.
- Otherwise, tap the known screen region. **Validated coords for iPhone 16 Pro in portrait:**
  - `compose-button`: `(354, 823)`
  - `scan-button`: `(292, 823)`
- Values shift with device size/orientation; coord-tap is fragile. Prefer opening the flow via a known-good deep link (`xcrun simctl openurl`) when possible.

### System dialog buttons

`Allow`, `Allow Paste`, `Don't Allow`, and similar system dialogs sometimes report the wrong frame center when tapped via the accessibility tree. Validated coord fallbacks for iPhone 16 Pro:
- Paste-permission `Allow Paste`: `(201, 526)`
- Notification-permission `Allow`: `(275, 518)`

If the accessibility-tree tap fails, fall through to these coords. Re-verify per device if the layout changes.

### Typing & keys

| pi action | Primary (Bash+idb) | MCP fallback |
|-----------|---------------------|--------------|
| `sim_type_in_field(id="X", text="Y")` | tap field (see above) → `$IDB ui text "Y" --udid $UDID` | `mcp__XcodeBuildMCP__tap` + `type_text` |
| clear first | after tap: `$IDB ui key 42 --udid $UDID` (backspace) in a loop, or long-press to select-all then backspace | MCP `key_sequence` with `[226, 4]` (cmd+A) + `key_press(42)` |
| `sim_ui_type(text)` | `$IDB ui text "text" --udid $UDID` | `mcp__XcodeBuildMCP__type_text({ text })` |
| `sim_ui_key(40)` — Return | `$IDB ui key 40 --udid $UDID` | `mcp__XcodeBuildMCP__key_press({ keycode: 40 })` |
| `sim_ui_key(42)` — Backspace | `$IDB ui key 42 --udid $UDID` | `key_press({ keycode: 42 })` |
| `sim_ui_key(41)` — Escape | `$IDB ui key 41 --udid $UDID` | `key_press({ keycode: 41 })` |

### Gestures

| pi action | Primary | MCP fallback |
|-----------|---------|--------------|
| swipe | `$IDB ui swipe <x1> <y1> <x2> <y2> --duration <s> --udid $UDID` | `mcp__XcodeBuildMCP__swipe({ xStart, yStart, xEnd, yEnd, duration, simulatorUuid: UDID })` |

### Observation & waiting

| pi action | Primary | MCP fallback |
|-----------|---------|--------------|
| `sim_ui_describe_all()` | `$IDB ui describe-all --udid $UDID` | `mcp__XcodeBuildMCP__snapshot_ui({ simulatorUuid: UDID })` |
| `sim_find_elements(pattern="X")` | `$IDB ui describe-all --udid $UDID \| jq -r 'recurse \| objects \| select((.AXLabel // "") \| contains("X")) \| .frame'` | `mcp__ios-simulator__ui_find_element({ search: ["X"], udid: UDID })` |
| `sim_wait_for_element` | Compose a loop — see pattern below | Same loop, calling the MCP variant |
| `sim_screenshot()` | `xcrun simctl io $UDID screenshot <path>` | `mcp__XcodeBuildMCP__screenshot({ simulatorUuid: UDID })` |

**Wait-for-element pattern** (no sleep — the polling interval is just the natural latency of `describe-all`):

```bash
# Poll up to ~10s (roughly 20 probes at ~500ms each).
deadline=$(($(date +%s) + 10))
found=""
while [ $(date +%s) -lt $deadline ]; do
  if $IDB ui describe-all --udid $UDID 2>/dev/null | grep -q '"AXUniqueId"[^,]*"message-text-field"'; then
    found=1; break
  fi
done
[ -n "$found" ] || { echo "timeout waiting for message-text-field"; exit 1; }
```

For label-contains searches, pipe through `jq` rather than `grep` to avoid escaping headaches.

### App lifecycle

| pi action | Primary | MCP fallback |
|-----------|---------|--------------|
| Launch | `xcrun simctl launch $UDID $BUNDLE_ID` | `mcp__XcodeBuildMCP__launch_app_sim({ simulatorUuid: UDID, bundleId: $BUNDLE_ID })` |
| Launch with terminate | `xcrun simctl terminate $UDID $BUNDLE_ID; xcrun simctl launch $UDID $BUNDLE_ID` | `launch_app_sim({ ..., terminateRunning: true })` |
| Install | `xcrun simctl install $UDID <app_path>` | `install_app_sim({ simulatorUuid: UDID, appPath: "..." })` |
| Terminate | `xcrun simctl terminate $UDID $BUNDLE_ID` | `stop_app_sim` |
| Erase | `xcrun simctl erase $UDID` | `erase_sims({ simulatorUuids: [UDID] })` |
| Boot | `xcrun simctl boot $UDID` | `boot_sim({ simulatorUuid: UDID })` |
| Open URL | `xcrun simctl openurl $UDID "$URL"` | (no direct MCP equivalent — use Bash) |

### Build

```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath .derivedData 2>&1 | tail -100
APP_PATH=$(find .derivedData/Build/Products -name 'Convos.app' -type d | head -1)
```

### Logs — use the app group log file

The app writes its own log to `.../AppGroup/<uuid>/Logs/convos.log` with `[EVENT]` lines at key milestones. This is the **authoritative** source for events and errors — more reliable than `log show` (which has timestamp parsing quirks with ISO-8601 UTC strings passed to `--start`).

**Marker:**
```bash
LOG_MARKER_BYTES=$(wc -c < "$APP_GROUP")    # byte offset into the log
```

**Tail new lines since the marker:**
```bash
tail -c +$((LOG_MARKER_BYTES + 1)) "$APP_GROUP"
```

**Check for errors only:**
```bash
tail -c +$((LOG_MARKER_BYTES + 1)) "$APP_GROUP" | grep -E '^\[[^]]+\] \[error\]'
```

**Read `[EVENT]` lines:**
```bash
tail -c +$((LOG_MARKER_BYTES + 1)) "$APP_GROUP" | grep -F '[EVENT]'
```

**Filter a specific event:**
```bash
tail -c +$((LOG_MARKER_BYTES + 1)) "$APP_GROUP" | grep -F '[EVENT] message.sent'
```

If the app is relaunched mid-test, the log file resets — re-read `APP_GROUP` and reset `LOG_MARKER_BYTES` to 0.

**`xcrun simctl spawn <udid> log show` is a fallback only** and is unreliable with ISO timestamps — if you use it, pass a relative time like `--last 2m`.

### Clipboard

```bash
# Clear before a Copy action (pbpaste may return stale content otherwise)
echo -n "" | xcrun simctl pbcopy $UDID

# Read after a Copy action
TEXT=$(xcrun simctl pbpaste $UDID)

# Write for a paste-invite flow
xcrun simctl pbcopy $UDID <<< "$TEXT"
```

## Known action → recipe map

From the structured YAMLs. Translate `action:` keys into these chains.

**`tap: { id: "X" }`** — primary:
```bash
# find frame — note `floor` on coords: idb ui tap rejects floating-point
F=$($IDB ui describe-all --udid $UDID | jq -c '.. | objects? | select(.AXUniqueId == "X") | .frame' | head -1)
X=$(echo "$F" | jq '(.x + .width/2) | floor'); Y=$(echo "$F" | jq '(.y + .height/2) | floor')
$IDB ui tap $X $Y --udid $UDID
```

**`wait_for_element: { id: "X", timeout: 15 }`** — loop `describe-all | grep` until match or deadline.

**`long_press: { label_contains: "X", duration: 1.5 }`** — find center → `$IDB ui tap <x> <y> --duration 1.5 --udid $UDID`.

**`double_tap_element: { label_contains: "X" }`** — find center → two parallel idb taps.

**`type_in_field: { id: "X", text: "Y" }`** — tap field → `$IDB ui text "Y" --udid $UDID`.

**`pbcopy_to_simulator: { text: "..." }`** — `xcrun simctl pbcopy $UDID <<< "..."`

**`cli_*` actions** — map one-to-one to the `convos` CLI (see `.pi/skills/convos-cli/SKILL.md`). The CLI behaves identically under both harnesses; always pass `--env dev` (or initialize once) and `--json` for machine output.

## Gotchas (validated)

- **Bottom-toolbar buttons invisible to idb.** `compose-button`, `scan-button` etc. are present in SwiftUI's accessibility tree but idb's `describe-all` skips `ToolbarItem(placement: .bottomBar)`. MCP's `snapshot_ui` does find them. When relying on idb, fall back to coordinate tap using known screen regions — or reach the flow via deep link.
- **`log show --start "<ISO UTC>"` silently returns no rows.** Use the app group `convos.log` file with byte-offset markers. If you must use `log show`, use `--last <duration>` instead.
- **CLI `explode` may return `[GroupError::Sync]`.** Transient; the conversation is still gone once the error clears on retry. Teardown explodes are marked `optional: true` in most YAMLs for this reason.
- **`cxdb.sh log-error`'s 6th arg is `is_xmtp`** (1=XMTP, 0=app), despite RULES historically phrasing it as `is_app_error`. The script is authoritative; RULES has been reconciled.
- **`idb` not on PATH.** Full path: `/Users/jarod/Library/Python/3.9/bin/idb`. Set `IDB=` once at session start.
- **`idb ui tap` rejects float coordinates.** Always `| floor` the x/y in jq, or use `$(( ))` in Bash to coerce.
- **`xcrun simctl erase` fails on a booted simulator.** Shutdown first: `xcrun simctl shutdown $UDID; xcrun simctl erase $UDID; xcrun simctl boot $UDID`.
- **Reaction picker emoji frames are sometimes null on first read.** Re-run `describe-all` once (~200ms later) and they populate.
- **Ephemeral onboarding banners can occlude targets.** The "Notify me of new messages" banner overlaps the bottom of the conversation list; scroll up before long-pressing the newest message.
- **`simulator_uuid` is always `.claude/.simulator_id`.** Never rely on `booted` — there can be multiple running simulators.

## When writing new YAMLs

Keep writing against pi vocabulary — it's the stable source of truth across both harnesses. This document is how the Claude-side runner translates.
