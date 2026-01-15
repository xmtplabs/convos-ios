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
   - If no, select a new simulator (see below)

2. Call `mcp__XcodeBuildMCP__list_sims` to get all available simulators

3. Select a simulator that is NOT already booted:
   - Look for iOS 26.0 simulators (latest OS)
   - Find simulators that do NOT have `[Booted]` next to them
   - Prefer iPhone models in this order: iPhone 17 Pro, iPhone 17 Pro Max, iPhone Air, iPhone 17
   - If all preferred models are booted, pick any non-booted iPhone
   - If all iPhones are booted, inform the user and use any available one

4. Save the selected simulator ID to `.claude/.simulator_id` for session persistence

### Step 2: Build with xcodebuild

Use xcodebuild directly for reliable builds:

```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,id=SIMULATOR_ID" \
  -configuration Dev \
  -derivedDataPath .derivedData
```

Replace:
- `SIMULATOR_ID` with the selected simulator UUID
- `"Convos (Dev)"` with the requested scheme if different
- `-configuration Dev` with the appropriate config (Dev, Local, Prod)

**Note:** The `-derivedDataPath .derivedData` flag stores build artifacts locally in each worktree, preventing conflicts when multiple worktrees build the same project simultaneously.

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

3. Install and launch the app with log capture:
   ```
   mcp__XcodeBuildMCP__session-set-defaults with simulatorId
   mcp__XcodeBuildMCP__install_app_sim with appPath
   mcp__XcodeBuildMCP__launch_app_logs_sim with bundleId (captures logs automatically)
   ```

   Bundle IDs by scheme:
   - "Convos (Dev)": org.convos.ios-preview
   - "Convos (Local)": org.convos.ios-local
   - "Convos (Prod)": org.convos.ios

### Step 4: Check for Firebase App Check Debug Token

After launching the app, monitor the first ~20 lines of logs for a Firebase App Check debug token:

1. Start log capture:
   ```
   mcp__XcodeBuildMCP__start_sim_log_cap with bundleId and captureConsole: true
   ```

2. Wait 3-5 seconds for logs to accumulate

3. Stop log capture and retrieve logs:
   ```
   mcp__XcodeBuildMCP__stop_sim_log_cap with logSessionId
   ```

4. Search the logs for Firebase App Check debug token pattern:
   - Look for: `[AppCheckCore][I-GAC004001] App Check debug token: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'`
   - The token is a UUID inside single quotes
   - This appears when a simulator hasn't been registered with Firebase App Check

5. If a debug token is found:
   - **Alert the user** with a prominent message
   - Display the token clearly
   - Provide the direct Firebase Console URL
   - Instruct them to add it to the Firebase Console:
     ```
     ⚠️ FIREBASE APP CHECK DEBUG TOKEN DETECTED

     This simulator needs to be registered with Firebase.
     Copy this debug token and add it to your Firebase Console:

     Token: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

     Add it here: https://console.firebase.google.com/u/1/project/convos-otr/appcheck/apps

     Steps:
     1. Click the link above (or go to Firebase Console → App Check)
     2. Select the iOS app matching your scheme
     3. Click the overflow menu (⋮) → "Manage debug tokens"
     4. Click "Add debug token" and paste the token above
     ```

### Step 5: Report Result

**Compile only mode:**
- Report whether the build succeeded or failed
- If failed, show the compilation errors

**Build and run mode:**
- Report the build status
- Confirm which simulator was used (e.g., "iPhone 17 Pro")
- If Firebase debug token was found, show the warning message (see Step 4)
- Notify the user: "The app is now running on [simulator name]. You can interact with it in the Simulator."

## On Failure

If the build fails:
1. Check for Swift compilation errors in the output
2. Run `swiftlint` to check for lint issues
3. Verify all dependencies are resolved in Package.resolved
4. Try cleaning: `xcodebuild clean -scheme "Convos (Dev)" -configuration Dev -derivedDataPath .derivedData`
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

**Build and launch for testing:**
```
User: /build --run
Claude: Reads simulator ID (or selects iPhone 17 Pro if not set),
        runs xcodebuild, opens simulator, installs and launches app,
        captures logs, checks for Firebase debug token,
        reports "App is now running on iPhone 17 Pro"
```

**Build and launch - new simulator needing Firebase registration:**
```
User: /build --run
Claude: Selects new simulator (iPhone 17 Pro Max), builds, launches,
        detects Firebase debug token in logs, displays:

        ⚠️ FIREBASE APP CHECK DEBUG TOKEN DETECTED

        This simulator needs to be registered with Firebase.
        Found in logs: [AppCheckCore][I-GAC004001] App Check debug token: '956151D9-EBD2-4390-B4CD-1C4114702EE2'

        Token: 956151D9-EBD2-4390-B4CD-1C4114702EE2

        Add it here: https://console.firebase.google.com/u/1/project/convos-otr/appcheck/apps

        Steps:
        1. Click the link above
        2. Select the iOS app (org.convos.ios-preview for Dev)
        3. Click ⋮ → "Manage debug tokens"
        4. Click "Add debug token" and paste the token

        App is now running on iPhone 17 Pro Max.
```
