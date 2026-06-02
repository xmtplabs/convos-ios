---
description: Sync (or rotate) the shared Firebase App Check debug token. Source of truth is the team "Convos" 1Password vault; each checkout's .env is a cache the build reads.
---

# /firebase-token

The Firebase App Check debug token is a single shared team secret. Its source of
truth is the **"Convos" 1Password vault** (`op://Convos/Firebase App Check Debug
Token/credential`), registered once in the Firebase Console for both the Dev and
Local apps. Every checkout's `.env` is just a **cache** of that value, which the
build phase reads (`Scripts/secrets-utils.sh` -> `resolve_firebase_debug_token`).

This command has two jobs:
- **Sync** this checkout to the latest token in 1Password (the common case).
- **Rotate** the token (when it expired / Firebase removed it): mint a new one,
  push it to 1Password, register it in the Console.

## When to use
- App Check rejections after the token rotated (they expire ~monthly).
- A fresh checkout/simulator whose `.env` cache is stale or missing.
- First-time setup of the shared token.

## Prerequisite: 1Password CLI

`op` must be installed and signed in (`op signin`, account `xmtpinc`). For the
token to also resolve inside Xcode **build phases** (not just shell), enable
1Password **desktop-app CLI integration** (Settings -> Developer -> "Integrate
with 1Password CLI") so the session is visible across processes. Without it,
builds fall back to the cached `.env`, and this command refreshes that cache.

## Instructions

### Step 1: Resolve the shared `.env` cache and the op reference

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Shared convos-ios DEV .env cache: prefer the local-stack workspace (CONVOS_REPOS_DIR env,
# or the .convos-stack pointer at the repo root) -> <workspace>/convos-ios.env. Fall back to
# the legacy parent (<dirname repo>/.env) when no workspace is configured.
WS="${CONVOS_REPOS_DIR:-}"
[ -z "$WS" ] && [ -f "$REPO_ROOT/.convos-stack" ] && WS="$(tr -d '\n' < "$REPO_ROOT/.convos-stack")"
if [ -n "$WS" ] && [ -d "$WS" ]; then SHARED_ENV="$WS/convos-ios.env"; else SHARED_ENV="$(dirname "$REPO_ROOT")/.env"; fi
LOCAL_ENV="$REPO_ROOT/.env"
OP_REF="op://Convos/Firebase App Check Debug Token/credential"
```

### Step 2: Ensure the `.env` cache symlink exists

Ensure `$SHARED_ENV` exists first — if missing, `touch "$SHARED_ENV"`.

Four cases for `$LOCAL_ENV`:

| State | Action |
|-------|--------|
| Missing | `ln -s "$SHARED_ENV" "$LOCAL_ENV"` and report "Linked .env → $SHARED_ENV" |
| Symlink → `$SHARED_ENV` | No-op |
| Symlink pointing elsewhere | Warn, stop. Don't clobber. (A `Convos (Local)` checkout intentionally has a *standalone* `.env` written by `ios-config` — leave it.) |
| Regular file | Warn, stop. Print the migration recipe: `cat .env >> "$SHARED_ENV" && rm .env && ln -s "$SHARED_ENV" .env` (after confirming the user wants the contents moved). |

### Step 3: Sync — pull the canonical token from 1Password into the cache

This is the common path. No app or logs needed.

```bash
TOKEN="$(op read "$OP_REF" --no-newline)" || { echo "op read failed — run 'op signin' (account xmtpinc) and retry"; exit 1; }
if grep -q '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' "$SHARED_ENV"; then
  sed -i '' "s|^FIREBASE_APP_CHECK_DEBUG_TOKEN=.*|FIREBASE_APP_CHECK_DEBUG_TOKEN=${TOKEN}|" "$SHARED_ENV"
else
  echo "FIREBASE_APP_CHECK_DEBUG_TOKEN=${TOKEN}" >> "$SHARED_ENV"
fi
```

If the sync succeeds, skip to Step 6. Only continue to Steps 4-5 if you are
**rotating** (the token in 1Password is dead) or the vault item does not exist yet.

### Step 4: Rotate — capture a fresh token from the running app

Verify the app is running: take a screenshot or `xcrun simctl listapps $UDID | grep -q org.convos.ios-preview`. If it isn't, tell the user to `/run` first and stop — no live app, no token.

Capture logs and extract the UUID. Preferred (MCP):
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
Find: `[AppCheckCore][I-GAC004001] App Check debug token: 'XXXXXXXX-...'` — a UUID
in single quotes. (You can also mint one yourself with `uuidgen` and register it.)

### Step 5: Rotate — push the new token to 1Password, then cache it

```bash
TOKEN="<extracted-uuid>"
# Update the existing vault item, or create it the first time.
if op item get "Firebase App Check Debug Token" --vault Convos >/dev/null 2>&1; then
  op item edit "Firebase App Check Debug Token" --vault Convos "credential=${TOKEN}"
else
  op item create --category "API Credential" --vault Convos \
    --title "Firebase App Check Debug Token" "credential=${TOKEN}"
fi
# Then refresh the .env cache (Step 3's write block) with the same TOKEN.
```

### Step 6: Report

```
🔥 Firebase App Check Debug Token

Token: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

✓ Source of truth: op://Convos/Firebase App Check Debug Token/credential
✓ Cached in <SHARED_ENV>
✓ .env → <SHARED_ENV> symlink in place at <LOCAL_ENV>
  (every convos-ios checkout/worktree resolves the same token)

If you ROTATED, register the new UUID in Firebase Console:
https://console.firebase.google.com/u/1/project/convos-otr/appcheck/apps
  → pick the app (Dev: org.convos.ios-preview, Local: org.convos.ios-local)
    → ⋮ → Manage debug tokens → Add debug token → paste the UUID.
  (Register in BOTH the Dev and Local apps — they share one token.)

Relaunch the app (/run) to pick it up.
```

If `op read` failed and there is no cached token, report that and the `op signin`
fix. Always report the symlink status.

## Bundle IDs per scheme
| Scheme | Bundle id |
|--------|-----------|
| Convos (Dev) | `org.convos.ios-preview` |
| Convos (Local) | `org.convos.ios-local` |
| Convos (Prod) | `org.convos.ios` |

## Why 1Password is the source of truth
A debug token is a low-sensitivity shared team secret. Storing it in the "Convos"
vault gives one authoritative value the whole team resolves — across machines and
worktrees — instead of each person scraping logs and self-registering.

Builds are **cache-first**: they read the token cached in `.env` and only call
`op read` when that cache is empty (a fresh worktree), so a normal build makes no
network call and triggers no 1Password prompt. Routine refresh and rotation happen
deliberately in shell context — run `/firebase-token` (this command) or `/setup`,
which pull the latest from the vault and rewrite the cache. After a rotation, run
this command per machine (or set `FIREBASE_TOKEN_REFRESH=1` on one build) to pull
the new value; worktrees with a stale cached token keep using it until then.

CI never reads this token: archive builds attest with App Attest, and
`resolve_firebase_debug_token` returns empty under `CI` / `GITHUB_ACTIONS`.
