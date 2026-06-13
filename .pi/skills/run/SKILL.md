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

Pass an explicit `-configuration` matching the scheme (`Convos (Dev)` -> `Dev`, `Convos (Local)` -> `Local`, `Convos (Prod)` -> `Prod`). Without it the scheme builds targets under mismatched configurations: the SPM packages land in one config dir while the NotificationService extension looks in another (`unable to resolve module dependency: ConvosCore`), and the app's entitlements/identifiers stop matching `config.json`, surfacing at runtime as a nil app-group container crash (`Failed getting container URL`) or `-34018` (`errSecMissingEntitlement`) on first identity read. Those are one configuration signature, not simulator limitations (issue #843, #1019); `rm -rf .derivedData` does not fix them, an explicit `-configuration` does.

```bash
set -o pipefail
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" -configuration Dev \
  -destination "platform=iOS Simulator,name=<SIMULATOR_NAME>" \
  -derivedDataPath .derivedData 2>&1 | tail -100
```

`set -o pipefail` is load-bearing: without it `| tail` makes a failed build exit 0, so check for `** BUILD FAILED **` in the tail rather than trusting the exit code alone.

Use a timeout of 300 seconds for the build.

If the build fails:
- Show the compilation errors.
- `unable to resolve module dependency` in the NotificationService extension means `-configuration` was omitted (config split, see above) — set it; `rm -rf .derivedData` does not fix this one. For other `module not found` errors, `rm -rf .derivedData` and rebuild once.
- A `took NNNms to type-check` failure on a *trivial* expression that *moves between files* across builds is CPU contention, not a code problem — rebuild with `-jobs 2` (and close heavy apps); do not edit the flagged code or raise the threshold.

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
