#!/bin/bash
# Session initialization hook for convos-task worktrees
# This hook is intentionally lightweight to avoid blocking session startup.
# The actual simulator setup is done lazily by /setup or /build.

CONVOS_TASK_FILE="$CLAUDE_PROJECT_DIR/.convos-task"
SIMULATOR_ID_FILE="$CLAUDE_PROJECT_DIR/.claude/.simulator_id"

# Check if this is a convos-task worktree
if [ -f "$CONVOS_TASK_FILE" ]; then
    # Read task configuration (fast - just reads a small file)
    source "$CONVOS_TASK_FILE"

    # Check if simulator ID is already cached (fast file check)
    if [ -f "$SIMULATOR_ID_FILE" ]; then
        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Task worktree '$TASK_NAME' ready. Simulator '$SIMULATOR_NAME' configured. Use /build or /build --run to build the app."
  }
}
EOF
    else
        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Task worktree '$TASK_NAME' detected. Run /setup to configure the simulator, or /build which will set it up automatically."
  }
}
EOF
    fi
fi

exit 0
