---
description: Build and launch the Convos iOS app in this worktree's dedicated simulator. `/run local` also brings up the shared local backend+agents stack.
---

# /run

Build and launch the app on the worktree's dedicated simulator. Idempotent — re-running rebuilds and relaunches.

## Usage

```
/run                      # default scheme "Convos (Dev)" — talks to the Dev cloud
/run local                # FULL LOCAL: bring up the shared stack + run "Convos (Local)" against it
/run "Convos (Local)"     # same as `/run local`
/run "Convos (Prod)"
```

Bundle IDs by scheme:
| Scheme | Bundle id |
|--------|-----------|
| `Convos (Dev)` | `org.convos.ios-preview` |
| `Convos (Local)` | `org.convos.ios-local` |
| `Convos (Prod)` | `org.convos.ios` |

**Local mode** (`local` / `Convos (Local)`) runs the app entirely against services on this machine (backend :4000, herald :5050, assistants worker :8787 + Hermes, MinIO, Postgres) over the hosted DEV xmtp network. That stack runs **once** and is shared by every convos-ios checkout/worktree.

## Instructions

### Step 0: (LOCAL MODE ONLY) ensure the shared stack is up + configure this checkout

Skip this whole step for Dev/Prod schemes. The orchestration is committed in this repo at `dev/local-stack/` and resolves its external workspace itself (via the gitignored `.convos-stack` pointer or `$CONVOS_REPOS_DIR`).

1. `LS="$(git rev-parse --show-toplevel)/dev/local-stack"`.
2. **First-run:** `make -C "$LS" status` (30s). If it errors *"no workspace configured — run: make init"*, the machine isn't set up: run `make -C "$LS" init` (defaults the workspace to a sibling of this repo and clones the service repos; ~600000ms timeout), then **pause** and tell the user to set the `OP_*` 1Password refs in `<workspace>/stack.env` and run `make -C "$LS" bootstrap` once.
3. **Bring it up if needed:** if `status` shows backend/worker down, run `make -C "$LS" up` with a **1200000ms (20 min)** timeout (first run builds the Hermes image — capped; later runs are fast). Relay any Docker-cap warning from `make -C "$LS" doctor`.
4. **Configure this checkout as a thin client:** `make -C "$LS" ios-config IOS="$(pwd)"` — sets `config.local.json` `xmtpNetwork→dev` and writes `./.env` (shared Firebase Local token; `CONVOS_API_BASE_URL` left empty so Local auto-detects the Mac LAN IP and a Dev build on the same checkout isn't redirected to localhost).

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

**Dev / Prod schemes** (team signing):
```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,id=$SIM_UUID" \
  -derivedDataPath .derivedData 2>&1 | tail -100
```

**Local scheme** — `org.convos.ios-local` is **not** in convos-certificates, so CLI automatic signing drops the app-group entitlement and the app crashes at launch (`Failed getting container URL for group identifier`). Build **ad-hoc** so the simulated entitlements are applied:
```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Local)" -configuration Local \
  -destination "platform=iOS Simulator,id=$SIM_UUID" \
  -derivedDataPath .derivedData -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  PROVISIONING_PROFILE_SPECIFIER="" DEVELOPMENT_TEAM="" 2>&1 | tail -100
```

Set a 600s timeout. If the build fails:
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

```
✅ App running on <SIMULATOR_NAME>
```
For **local mode**, also one line on stack health (from `make -C "$LS" status`) and note: auth + "Make an agent" now run against the local backend/agents.

**Do not** capture screenshots, probe the UI, tail logs, or test anything after launch — the user will ask explicitly if they want that.

## Local-mode failure notes
- Crash on app-group container at launch → you built Local without the ad-hoc flags (Step 2). Rebuild with them.
- Firebase 403 / auth never completes → `./.env` is missing the shared `FIREBASE_APP_CHECK_DEBUG_TOKEN`; re-run `make -C "$LS" ios-config IOS="$(pwd)"`.
- Backend 500 on `/auth/*` → backend lost Postgres (Docker bounced); `make -C "$LS" up` re-brings infra and re-disables App Check.

## DerivedData isolation

`.derivedData/` is gitignored and local per worktree. That prevents module-resolution conflicts when multiple worktrees build at once. Safe to `rm -rf .derivedData` any time to force a clean rebuild.
