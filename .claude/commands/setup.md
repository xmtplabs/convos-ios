# Setup

Initialize the Claude Code session for a convos-task worktree.

## Purpose

This command sets up the iOS simulator and XcodeBuildMCP session defaults when working in a `convos-task` worktree. It ensures the session has a dedicated simulator for builds and testing.

## When to Run

- Automatically suggested at session start when `.convos-task` file exists
- Can be run manually anytime to reset or verify the setup

## Instructions

### Step 1: Check for Task Configuration

1. Read the `.convos-task` file in the project root
2. If it doesn't exist, inform the user this isn't a convos-task worktree and exit
3. Extract `TASK_NAME` and `SIMULATOR_NAME` from the file

### Step 2: Create Simulator if Needed

1. Use `mcp__XcodeBuildMCP__list_sims` to check if the simulator already exists
2. If the simulator doesn't exist:
   - Find a base iPhone simulator to clone from (prefer iPhone 17 Pro, iPhone 17 Pro Max, or latest available)
   - Use bash to clone it: `xcrun simctl clone "BASE_SIM_NAME" "SIMULATOR_NAME"`
3. Get the simulator's UUID from the list

### Step 3: Set XcodeBuildMCP Session Defaults

Call `mcp__XcodeBuildMCP__session-set-defaults` with:
- `simulatorName`: The task's simulator name (e.g., "convos-my-feature")
- `projectPath`: Path to `Convos.xcodeproj`
- `scheme`: "Convos (Dev)" (default scheme)
- `useLatestOS`: true

### Step 4: Save Simulator ID for Session

Write the simulator UUID to `.claude/.simulator_id` for use by `/build` command.

### Step 5: Report Setup Complete

Inform the user:
```
✅ Session setup complete for task: TASK_NAME

📱 Simulator: SIMULATOR_NAME (UUID)
🔧 XcodeBuildMCP defaults configured
📁 Project: Convos.xcodeproj
🎯 Scheme: Convos (Dev)

Ready to build! Use /build or /build --run
```

## Example Flow

```
User: /setup
Claude: Checking for task configuration...
        Found .convos-task: TASK_NAME=push-notifications, SIMULATOR_NAME=convos-push-notifications

        Checking if simulator exists...
        Simulator not found, creating from iPhone 17 Pro...
        Created simulator: convos-push-notifications (A1B2C3D4-...)

        Setting XcodeBuildMCP session defaults...

        ✅ Session setup complete for task: push-notifications

        📱 Simulator: convos-push-notifications
        🔧 XcodeBuildMCP defaults configured
        📁 Project: Convos.xcodeproj
        🎯 Scheme: Convos (Dev)

        Ready to build! Use /build or /build --run
```

## Error Handling

- If `.convos-task` doesn't exist: "This directory doesn't have a task configuration. Run `convos-task new <name>` to create a task."
- If simulator creation fails: Show the error and suggest checking available simulators with `xcrun simctl list devices`
- If no base simulator found: "No iPhone simulator found to clone. Install iOS Simulator runtimes in Xcode."
