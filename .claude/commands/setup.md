# Setup

Initialize the Claude Code session for any branch or worktree — creates a dedicated simulator and configures build defaults.

## Purpose

This command sets up an iOS simulator and XcodeBuildMCP session defaults so `/build` and `/build --run` work correctly. It works in any context:
- **convos-task worktrees**: Uses the task config from `.convos-task`
- **Regular branches**: Derives the simulator name from the current git branch
- **Main repo**: Works on any branch, no special setup required

## When to Run

- At the start of any new session when working on a feature branch
- Automatically suggested at session start when `.convos-task` file exists
- Can be run manually anytime to reset or verify the setup

## Instructions

### Step 1: Determine Simulator Name

Check for configuration in this order:

1. **`.convos-task` file exists**: Read `TASK_NAME` and `SIMULATOR_NAME` from it
2. **No `.convos-task` file**: Derive from the current git branch:
   - Run `git branch --show-current` to get the branch name
   - Sanitize the branch name: replace `/` and special characters with `-`, lowercase it
   - Simulator name: `convos-<sanitized-branch-name>`
   - Example: branch `jarod/push-notifications` → simulator `convos-jarod-push-notifications`
   - Special case: if on `main` or `master`, use `convos-main`

### Step 2: Run Project Setup

Run `Scripts/setup.sh` with `CI=true CLAUDE_SETUP=1` — `CI` skips one-time machine setup (git hooks, Xcode defaults, brew installs of the GitHub CLI) and `CLAUDE_SETUP=1` re-enables the `.env` / Firebase debug token check so missing `.env` symlinks in worktrees surface as warnings:

```bash
CI=true CLAUDE_SETUP=1 Scripts/setup.sh
```

This ensures SwiftLint, SwiftFormat, and other dependencies are installed, and surfaces any `.env` gap that would otherwise cause Firebase App Check failures at runtime.

### Step 3: Create Simulator if Needed

1. Use `mcp__XcodeBuildMCP__list_sims` to check if the simulator already exists
2. If the simulator doesn't exist:
   - Find a base iPhone simulator to clone from (prefer iPhone 17 Pro, iPhone 17 Pro Max, or latest available)
   - Use bash to clone it: `xcrun simctl clone "BASE_SIM_NAME" "SIMULATOR_NAME"`
3. Get the simulator's UUID from the list

### Step 4: Set XcodeBuildMCP Session Defaults

Call `mcp__XcodeBuildMCP__session-set-defaults` with:
- `simulatorName`: The simulator name (e.g., "convos-push-notifications")
- `projectPath`: Path to `Convos.xcodeproj`
- `scheme`: "Convos (Dev)" (default scheme)
- `useLatestOS`: true

### Step 5: Save Simulator ID for Session

Write the simulator UUID to `.claude/.simulator_id` for use by `/build` command.

### Step 6: Report Setup Complete

Inform the user:
```
✅ Session setup complete

📱 Simulator: SIMULATOR_NAME (UUID)
🔧 XcodeBuildMCP defaults configured
📁 Project: Convos.xcodeproj
🎯 Scheme: Convos (Dev)

Ready to build! Use /build or /build --run
```

## Example Flows

**In a convos-task worktree:**
```
User: /setup
Claude: Found .convos-task: TASK_NAME=push-notifications, SIMULATOR_NAME=convos-push-notifications
        Running Scripts/setup.sh...
        ✅ All dependencies installed
        Simulator convos-push-notifications exists (A1B2C3D4-...)
        Setting XcodeBuildMCP defaults...

        ✅ Session setup complete

        📱 Simulator: convos-push-notifications (A1B2C3D4-...)
        🔧 XcodeBuildMCP defaults configured
        📁 Project: Convos.xcodeproj
        🎯 Scheme: Convos (Dev)
```

**On a regular branch (no .convos-task):**
```
User: /setup
Claude: No .convos-task found. Deriving from branch name...
        Branch: jarod/retry-errors → Simulator: convos-jarod-retry-errors
        Running Scripts/setup.sh...
        ✅ All dependencies installed
        Cloning iPhone 17 Pro → convos-jarod-retry-errors...
        Created simulator: convos-jarod-retry-errors (E5F6G7H8-...)
        Setting XcodeBuildMCP defaults...

        ✅ Session setup complete

        📱 Simulator: convos-jarod-retry-errors (E5F6G7H8-...)
        🔧 XcodeBuildMCP defaults configured
        📁 Project: Convos.xcodeproj
        🎯 Scheme: Convos (Dev)
```

## Error Handling

- If simulator creation fails: Show the error and suggest checking available simulators with `xcrun simctl list devices`
- If no base simulator found: "No iPhone simulator found to clone. Install iOS Simulator runtimes in Xcode."
- If `Scripts/setup.sh` fails: Show the error output and suggest running it manually
