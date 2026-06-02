---
description: Fetch the Firebase App Check debug token from simulator logs and pin it in the shared workspace convos-ios.env so every worktree reuses one token.
---

# /firebase-token

Retrieve a Firebase App Check debug token from the running app, pin it in the **shared `convos-ios.env`** (in the local-stack workspace), and make sure this checkout's `.env` symlinks to that shared file. One token, one place to rotate it, every worktree picks it up.

## When to use
- You've launched the app on a fresh simulator and are seeing App Check rejections.
- You want to set up the shared-token pattern for the first time.
- The token rotated (expired / Firebase removed it) and you need a new one.

## Instructions

### Step 1: Resolve the shared `.env`

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Shared convos-ios DEV .env: prefer the local-stack workspace (CONVOS_REPOS_DIR env, or the
# .convos-stack pointer at the repo root) -> <workspace>/convos-ios.env. Fall back to the legacy
# parent (<dirname repo>/.env) when no workspace is configured.
WS="${CONVOS_REPOS_DIR:-}"
[ -z "$WS" ] && [ -f "$REPO_ROOT/.convos-stack" ] && WS="$(tr -d '\n' < "$REPO_ROOT/.convos-stack")"
if [ -n "$WS" ] && [ -d "$WS" ]; then SHARED_ENV="$WS/convos-ios.env"; else SHARED_ENV="$(dirname "$REPO_ROOT")/.env"; fi
LOCAL_ENV="$REPO_ROOT/.env"
```
With the local stack set up (`make -C dev/local-stack init`), `$SHARED_ENV` is `<workspace>/convos-ios.env`. Without it, it's the legacy `<parent>/.env`. Every checkout's `.env` symlinks to `$SHARED_ENV`.

### Step 2: Ensure the symlink exists

Ensure `$SHARED_ENV` exists first — if missing, `touch "$SHARED_ENV"`.

Four cases for `$LOCAL_ENV`:

| State | Action |
|-------|--------|
| Missing | `ln -s "$SHARED_ENV" "$LOCAL_ENV"` and report "Linked .env → $SHARED_ENV" |
| Symlink → `$SHARED_ENV` | No-op |
| Symlink pointing elsewhere | Warn, stop. Don't clobber. (A `Convos (Local)` checkout intentionally has a *standalone* `.env` written by `ios-config` — leave it.) |
| Regular file | Warn, stop. Print the migration recipe: `cat .env >> "$SHARED_ENV" && rm .env && ln -s "$SHARED_ENV" .env` (after confirming the user wants the contents moved). |

### Step 3: Verify the app is running

Take a screenshot or `xcrun simctl listapps $UDID | grep -q org.convos.ios-preview`. If the app isn't running, tell the user to `/run` first and stop — no live app, no token.

### Step 4: Capture logs and extract the token

Preferred (MCP):
```
mcp__XcodeBuildMCP__start_sim_log_cap with bundleId and captureConsole: true
wait 3-5 seconds
mcp__XcodeBuildMCP__stop_sim_log_cap with logSessionId
```
Bash fallback:
```bash
UDID=$(cat .claude/.simulator_id)
xcrun simctl spawn "$UDID" log show \
  --predicate 'eventMessage CONTAINS "App Check debug token"' \
  --last 5m --style compact 2>/dev/null | tail -50
```
Find: `[AppCheckCore][I-GAC004001] App Check debug token: 'XXXXXXXX-...'` — a UUID in single quotes.

### Step 5: Write the token to the shared `.env`

```bash
TOKEN="<extracted-uuid>"
if grep -q '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' "$SHARED_ENV"; then
  sed -i '' "s|^FIREBASE_APP_CHECK_DEBUG_TOKEN=.*|FIREBASE_APP_CHECK_DEBUG_TOKEN=${TOKEN}|" "$SHARED_ENV"
else
  echo "FIREBASE_APP_CHECK_DEBUG_TOKEN=${TOKEN}" >> "$SHARED_ENV"
fi
```

### Step 6: Report

```
🔥 Firebase App Check Debug Token

Token: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

✓ Pinned in <SHARED_ENV>
✓ .env → <SHARED_ENV> symlink in place at <LOCAL_ENV>
  (every convos-ios checkout/worktree sharing this workspace reuses this token)

Register it in Firebase Console if you haven't already:
https://console.firebase.google.com/u/1/project/convos-otr/appcheck/apps
  → pick the app for your scheme (Dev: org.convos.ios-preview, Local: org.convos.ios-local,
    Prod: org.convos.ios) → ⋮ → Manage debug tokens → Add debug token → paste the UUID.
  (Register in BOTH the Dev and Local apps if you build both schemes against this token.)

Relaunch the app (/run) to pick it up.
```

If no token found, or the local `.env` blocked the symlink, report that and the migration recipe (Step 2), and still report the symlink status.

## Bundle IDs per scheme
| Scheme | Bundle id |
|--------|-----------|
| Convos (Dev) | `org.convos.ios-preview` |
| Convos (Local) | `org.convos.ios-local` |
| Convos (Prod) | `org.convos.ios` |

## Why the shared-workspace pattern
One Firebase debug token across all your convos-ios worktrees: one place to rotate it, no per-worktree drift. It lives in the **local-stack workspace** (`<workspace>/convos-ios.env`) alongside the rest of the shared local-dev state, resolved via the `.convos-stack` pointer. `/setup` and `convos-task` create the same symlink for new checkouts/worktrees. (Falls back to the legacy `<parent>/.env` when no workspace is configured.) A `Convos (Local)` checkout keeps a *standalone* `.env` (written by `ios-config` / `/run local`) instead of the symlink, since Local needs a localhost backend URL.
