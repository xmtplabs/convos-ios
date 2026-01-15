#!/bin/bash
# Session initialization hook for convos-task worktrees
# This runs when a Claude Code session starts and automatically sets up the simulator

CONVOS_TASK_FILE="$CLAUDE_PROJECT_DIR/.convos-task"
SIMULATOR_ID_FILE="$CLAUDE_PROJECT_DIR/.claude/.simulator_id"

# Check if this is a convos-task worktree
if [ -f "$CONVOS_TASK_FILE" ]; then
    # Read task configuration
    source "$CONVOS_TASK_FILE"

    # Ensure .claude directory exists
    mkdir -p "$CLAUDE_PROJECT_DIR/.claude"

    # Find or create the simulator
    SIMULATOR_UUID=""

    # Check if simulator exists
    SIMULATOR_UUID=$(xcrun simctl list devices -j 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
name = '$SIMULATOR_NAME'
for runtime, devices in data.get('devices', {}).items():
    for device in devices:
        if device.get('name') == name and device.get('isAvailable', False):
            print(device['udid'])
            sys.exit(0)
" 2>/dev/null)

    # If simulator doesn't exist, create it
    if [ -z "$SIMULATOR_UUID" ]; then
        # Find a base simulator to clone from
        BASE_SIM=$(xcrun simctl list devices available -j 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
preferred = ['iPhone 17 Pro Max', 'iPhone 17 Pro', 'iPhone 17', 'iPhone 16 Pro Max', 'iPhone 16 Pro', 'iPhone 16']
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime:
        continue
    for pref in preferred:
        for device in devices:
            if device.get('name') == pref and device.get('isAvailable', False):
                print(pref)
                sys.exit(0)
" 2>/dev/null)

        if [ -n "$BASE_SIM" ]; then
            # Clone the simulator
            xcrun simctl clone "$BASE_SIM" "$SIMULATOR_NAME" >/dev/null 2>&1

            # Get the new simulator's UUID
            SIMULATOR_UUID=$(xcrun simctl list devices -j 2>/dev/null | \
                python3 -c "
import sys, json
data = json.load(sys.stdin)
name = '$SIMULATOR_NAME'
for runtime, devices in data.get('devices', {}).items():
    for device in devices:
        if device.get('name') == name and device.get('isAvailable', False):
            print(device['udid'])
            sys.exit(0)
" 2>/dev/null)
        fi
    fi

    # Write simulator ID to file for /build command
    if [ -n "$SIMULATOR_UUID" ]; then
        echo "$SIMULATOR_UUID" > "$SIMULATOR_ID_FILE"

        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Task worktree '$TASK_NAME' initialized. Simulator '$SIMULATOR_NAME' (UUID: $SIMULATOR_UUID) is ready. Use /build or /build --run to build the app."
  }
}
EOF
    else
        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Task worktree '$TASK_NAME' detected but simulator '$SIMULATOR_NAME' could not be created. Run /setup manually to troubleshoot."
  }
}
EOF
    fi
fi

exit 0
