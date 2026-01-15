#!/bin/bash
# Session initialization hook for convos-task worktrees
# This runs when a Claude Code session starts and outputs context about the task

CONVOS_TASK_FILE="$CLAUDE_PROJECT_DIR/.convos-task"

# Check if this is a convos-task worktree
if [ -f "$CONVOS_TASK_FILE" ]; then
    # Read task configuration
    source "$CONVOS_TASK_FILE"

    # Output context for Claude about the task setup
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "This is a convos-task worktree for task '$TASK_NAME' with dedicated simulator '$SIMULATOR_NAME'. Run /setup to configure the session (create simulator if needed and set XcodeBuildMCP defaults)."
  }
}
EOF
fi

exit 0
