---
description: Build and launch the Convos iOS app in this worktree's dedicated simulator.
---

# /run

Build and launch the app on the worktree's dedicated simulator. Idempotent — re-running rebuilds and relaunches.

## Usage

```
/run                      # default scheme "Convos (Dev)"
/run "Convos (Local)"     # different scheme
/run "Convos (Prod)"
```

Bundle IDs by scheme:
| Scheme | Bundle id |
|--------|-----------|
| `Convos (Dev)` | `org.convos.ios-preview` |
| `Convos (Local)` | `org.convos.ios-local` |
| `Convos (Prod)` | `org.convos.ios` |

## Instructions

### Step 1: Resolve the simulator

Look up in this order:

1. `.claude/.simulator_id` — if it exists, use that UUID.
2. `.convos-task` — if it exists, read `SIMULATOR_NAME` and resolve its UUID:
   ```bash
   xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((dev['udid'] for rt in d['devices'].values() for dev in rt if dev['name']=='$SIMULATOR_NAME'), ''))"
   ```
3. Otherwise derive from the git branch: `git branch --show-current`, sanitize (replace `/` and other special chars with `-`, lowercase), prefix with `convos-`. Special case: `main` or `master` → `convos-main`.

If no simulator with that name exists, clone one from an available iPhone base:

```bash
SIMULATOR_NAME=<resolved name>
BASE=$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((dev['name'] for rt in d['devices'].values() for dev in rt if 'iPhone' in dev['name'] and dev['isAvailable']), ''))")
xcrun simctl clone "$BASE" "$SIMULATOR_NAME"
SIM_UUID=$(xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((dev['udid'] for rt in d['devices'].values() for dev in rt if dev['name']=='$SIMULATOR_NAME'), ''))")
echo -n "$SIM_UUID" > .claude/.simulator_id
```

Boot it (no-op if already booted):

```bash
xcrun simctl boot "$SIM_UUID" 2>/dev/null || true
```

### Step 2: Build

Use `xcodebuild` via Bash. Do **not** use `mcp__XcodeBuildMCP__build_sim` — it mis-sequences SPM extension dependencies (`ConvosCore`, `ConvosCoreiOS`, `XMTPiOS`) on fresh worktrees. See `CLAUDE.md`.

```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,id=$SIM_UUID" \
  -derivedDataPath .derivedData 2>&1 | tail -100
```

Replace the scheme string if the user passed one. Set a 300s timeout on the command.

If the build fails:
- Surface the compilation errors from the tail.
- For `module not found` errors, `rm -rf .derivedData` and rebuild once.
- Stop if it still fails.

### Step 3: Install and launch

```bash
APP_PATH=$(find .derivedData/Build/Products -name 'Convos.app' -type d | head -1)
xcrun simctl install "$SIM_UUID" "$APP_PATH"
xcrun simctl launch "$SIM_UUID" <bundle-id-for-scheme>
open -a Simulator
```

### Step 4: Report

One line:

```
✅ App running on <SIMULATOR_NAME>
```

**Do not** capture screenshots, probe the UI, tail logs, or test anything after launch — the user will ask explicitly if they want that.

## DerivedData isolation

`.derivedData/` is gitignored and local per worktree. That prevents module-resolution conflicts when multiple worktrees build at once. Safe to `rm -rf .derivedData` any time to force a clean rebuild.
