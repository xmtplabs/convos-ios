---
name: run
description: Build and launch the Convos iOS app in this worktree's dedicated simulator. Use when the user wants to run, launch, or test the app.
---

# Run

Build and launch the Convos iOS app on the worktree's dedicated simulator.

## Instructions

### Step 1: Determine Simulator

1. If `.convos-task` exists in the project root, read `SIMULATOR_NAME` from it.
2. Otherwise, derive from the git branch: `git branch --show-current`, sanitize (replace `/` and special chars with `-`, lowercase), prefix with `convos-` (e.g., `jarod/replies` → `convos-jarod-replies`).
3. Verify the simulator exists: `xcrun simctl list devices | grep "<SIMULATOR_NAME>"`.
4. If it doesn't exist, find a base iPhone simulator and clone it:
   ```bash
   BASE=$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((dev['name'] for rt in d['devices'].values() for dev in rt if 'iPhone' in dev['name'] and dev['isAvailable']), ''))")
   xcrun simctl clone "$BASE" "<SIMULATOR_NAME>"
   ```
5. Get the simulator UUID:
   ```bash
   xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((dev['udid'] for rt in d['devices'].values() for dev in rt if dev['name']=='<SIMULATOR_NAME>'), ''))"
   ```

### Step 2: Build

Run xcodebuild directly via bash (**never** use MCP `build_sim` — it has a known bug with app extension SPM dependencies):

```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,name=<SIMULATOR_NAME>" \
  -derivedDataPath .derivedData 2>&1 | tail -100
```

Use a timeout of 300 seconds for the build.

If the build fails:
- Show the compilation errors
- Try `rm -rf .derivedData` and rebuild if module-not-found errors appear

### Step 3: Install and Launch

```bash
# Boot the simulator (ignore error if already booted)
xcrun simctl boot "<SIMULATOR_NAME>" 2>/dev/null || true

# Find the built app
APP_PATH=$(find .derivedData/Build/Products -name 'Convos.app' -type d | head -1)

# Install and launch
xcrun simctl install "<SIMULATOR_NAME>" "$APP_PATH"
xcrun simctl launch "<SIMULATOR_NAME>" org.convos.ios-preview

# Open Simulator.app
open -a Simulator
```

### Step 4: Report

Tell the user:
```
✅ App is running on <SIMULATOR_NAME>
```

Do NOT automatically capture screenshots, test the app, or check logs unless the user asks.
