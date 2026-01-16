# Build

Build the Convos iOS app using the Dev scheme.

## Usage

```
/build [--run] [scheme]
```

- Default scheme: "Convos (Dev)"
- Other schemes: "Convos (Local)", "Convos (Prod)"
- Add `--run` to build AND launch the app in the simulator

## Modes

### Compile Only (default)
Just build and verify compilation without launching:
```
/build
/build "Convos (Local)"
```

### Build and Run
Build, launch in simulator, and notify when running:
```
/build --run
/build --run "Convos (Local)"
```

## Instructions

### Step 1: Select Simulator

1. Check if `.claude/.simulator_id` file exists in the project root
   - If yes, read the simulator ID from it (this is the session's dedicated simulator)
   - If no, check if `.convos-task` file exists:
     - If yes, read `SIMULATOR_NAME` from it and find its UUID in the simulator list
     - If the simulator doesn't exist yet, suggest running `/setup` first
   - If neither file exists, select a new simulator (see below)

2. Call `mcp__XcodeBuildMCP__list_sims` to get all available simulators

3. Select a simulator that is NOT already booted:
   - Look for iOS 26.0 simulators (latest OS)
   - Find simulators that do NOT have `[Booted]` next to them
   - Prefer iPhone models in this order: iPhone 17 Pro, iPhone 17 Pro Max, iPhone Air, iPhone 17
   - If all preferred models are booted, pick any non-booted iPhone
   - If all iPhones are booted, inform the user and use any available one

4. Save the selected simulator ID to `.claude/.simulator_id` for session persistence

### Step 2: Build with xcodebuild

**IMPORTANT:** Always use xcodebuild directly via Bash with `-derivedDataPath .derivedData`. The MCP `build_sim` tool has known issues with app extension targets (NotificationService) failing to find module dependencies.

```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,id=SIMULATOR_ID" \
  -derivedDataPath .derivedData
```

Replace:
- `SIMULATOR_ID` with the selected simulator UUID
- `"Convos (Dev)"` with the requested scheme if different

**Why xcodebuild via Bash:**
- MCP `build_sim` fails with extension targets (NotificationService can't find ConvosCore modules)
- Direct xcodebuild works reliably with local `.derivedData` path
- The `-derivedDataPath .derivedData` flag ensures worktree isolation

### Step 3: Launch App (for --run mode only)

If `--run` was specified and build succeeded:

1. Open the simulator UI:
   ```
   mcp__XcodeBuildMCP__open_sim
   ```

2. Get the app path from local DerivedData:
   - The app bundle is located at `.derivedData/Build/Products/{Configuration}-iphonesimulator/Convos.app`
   - For Dev scheme: `.derivedData/Build/Products/Dev-iphonesimulator/Convos.app`
   - For Local scheme: `.derivedData/Build/Products/Local-iphonesimulator/Convos.app`
   - For Prod scheme: `.derivedData/Build/Products/Prod-iphonesimulator/Convos.app`

3. Install and launch the app (WITHOUT log capture to save context):
   ```
   mcp__XcodeBuildMCP__session-set-defaults with simulatorId
   mcp__XcodeBuildMCP__install_app_sim with appPath
   mcp__XcodeBuildMCP__launch_app_sim with bundleId
   ```

   Bundle IDs by scheme:
   - "Convos (Dev)": org.convos.ios-preview
   - "Convos (Local)": org.convos.ios-local
   - "Convos (Prod)": org.convos.ios

**IMPORTANT: Do NOT automatically:**
- Capture device screenshots or UI hierarchy
- Test or interact with the app
- Check logs for Firebase debug tokens
- Perform any device capture operations

Only perform device capture/testing when the user explicitly requests it.

### Step 4: Report Result

**Compile only mode:**
- Report whether the build succeeded or failed
- If failed, show the compilation errors

**Build and run mode:**
- Report the build status
- Confirm which simulator was used (e.g., "iPhone 17 Pro")
- Notify the user: "The app is now running on [simulator name]. You can interact with it in the Simulator."

## On Failure

If the build fails:
1. Check for Swift compilation errors in the output
2. Run `swiftlint` to check for lint issues
3. Verify all dependencies are resolved in Package.resolved
4. Try cleaning: `xcodebuild clean -scheme "Convos (Dev)" -derivedDataPath .derivedData`
5. For persistent module issues, delete `.derivedData` folder entirely: `rm -rf .derivedData`

## Session Persistence

The `.claude/.simulator_id` file stores the selected simulator for this worktree/project:
- Each Claude Code session in a worktree uses the same simulator
- This prevents conflicts when running multiple Claude Code instances
- The file is gitignored and local to each worktree

## DerivedData Isolation

Build artifacts are stored in `.derivedData/` local to each worktree:
- Prevents "module not found" errors when multiple worktrees build simultaneously
- Each worktree has completely isolated build caches
- The folder is gitignored and can be safely deleted to force a clean build

## Examples

**Just verify compilation:**
```
User: /build
Claude: Reads simulator ID from .claude/.simulator_id (or selects one),
        runs xcodebuild, reports "Build succeeded" or shows errors
```

**Build and launch:**
```
User: /build --run
Claude: Reads simulator ID (or selects iPhone 17 Pro if not set),
        runs xcodebuild, opens simulator, installs and launches app,
        reports "App is now running on iPhone 17 Pro"
```
