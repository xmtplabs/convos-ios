---
description: Fetch the Firebase App Check debug token from simulator logs and pin it in the shared parent .env so every worktree reuses one token.
---

# /firebase-token

Retrieve a Firebase App Check debug token from the running app, pin it in the **shared parent `.env`**, and make sure the current repo/worktree's `.env` is symlinked to that shared file. One token, one place to rotate it, every worktree picks it up.

## When to use

- You've launched the app on a fresh simulator and are seeing App Check rejections.
- You want to set up the shared-token pattern for the first time.
- The token rotated (e.g. token expired / Firebase removed it) and you need a new one.

## Instructions

### Step 1: Resolve paths for the shared `.env`

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PARENT_DIR=$(dirname "$REPO_ROOT")
PARENT_ENV="$PARENT_DIR/.env"
LOCAL_ENV="$REPO_ROOT/.env"
```

For the standard layout (`~/Code/xmtplabs/convos-ios/`, `~/Code/xmtplabs/convos-ios-task-*/`), `$PARENT_DIR` is `~/Code/xmtplabs/` and the shared file is `~/Code/xmtplabs/.env`. Both the main clone and every worktree's `.env` symlinks to it via `../.env`.

### Step 2: Ensure the symlink exists

Four cases for `$LOCAL_ENV`:

| State | Action |
|-------|--------|
| Missing | `ln -s ../.env "$LOCAL_ENV"` and report "Linked .env → ../.env" |
| Symlink → `../.env` (resolves to `$PARENT_ENV`) | No-op |
| Symlink pointing elsewhere | Warn, stop. Don't clobber. |
| Regular file | Warn, stop. Don't destroy local env vars. Print the migration recipe: `mv .env ../.env && ln -s ../.env .env` (after verifying the user actually wants the contents moved to the shared file). |

Ensure `$PARENT_ENV` exists — if missing, `touch "$PARENT_ENV"`.

### Step 3: Verify the app is running

Take a screenshot or call `xcrun simctl listapps $UDID | grep -q org.convos.ios-preview`. If the app isn't running, tell the user to run `/run` first and stop — we can't extract a token without a live app.

### Step 4: Capture logs and extract the token

Preferred path (MCP available in the main session):

```
mcp__XcodeBuildMCP__start_sim_log_cap with bundleId and captureConsole: true
wait 3-5 seconds
mcp__XcodeBuildMCP__stop_sim_log_cap with logSessionId
```

Bash fallback when MCP isn't available:

```bash
UDID=$(cat .claude/.simulator_id)
xcrun simctl spawn "$UDID" log show \
  --predicate 'eventMessage CONTAINS "App Check debug token"' \
  --last 5m --style compact 2>/dev/null | tail -50
```

Search the output for:

```
[AppCheckCore][I-GAC004001] App Check debug token: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'
```

The token is a UUID inside single quotes.

### Step 5: Write the token to the shared `.env`

Update `$PARENT_ENV` in place. Replace any existing line, otherwise append:

```bash
TOKEN="<extracted-uuid>"
if grep -q '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' "$PARENT_ENV"; then
  # macOS sed requires '' after -i
  sed -i '' "s|^FIREBASE_APP_CHECK_DEBUG_TOKEN=.*|FIREBASE_APP_CHECK_DEBUG_TOKEN=${TOKEN}|" "$PARENT_ENV"
else
  echo "FIREBASE_APP_CHECK_DEBUG_TOKEN=${TOKEN}" >> "$PARENT_ENV"
fi
```

### Step 6: Report

**If token extracted and pinned:**

```
🔥 Firebase App Check Debug Token

Token: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

✓ Pinned in <PARENT_ENV>
✓ .env → ../.env symlink in place at <LOCAL_ENV>
  (all convos-ios worktrees under <PARENT_DIR> share this token)

Register it in Firebase Console if you haven't already:
https://console.firebase.google.com/u/1/project/convos-otr/appcheck/apps

1. Click the link
2. Pick the iOS app for your scheme:
   - Dev:   org.convos.ios-preview
   - Local: org.convos.ios-local
   - Prod:  org.convos.ios
3. Overflow menu (⋮) → Manage debug tokens → Add debug token
4. Paste the UUID above

Relaunch the app (/run) to pick up the new token.
```

**If no token found in logs:**

```
No Firebase App Check debug token found in logs.

Could mean:
- The simulator is already registered with this token (check <PARENT_ENV>)
- The app hasn't initialized Firebase yet (try interacting with the app, then rerun)
- Logs were captured too early (rerun /firebase-token)
```

Still report the symlink status from step 2 so the user knows `.env` plumbing is in place.

**If local `.env` blocked the symlink (step 2 warning case):**

Stop before step 3 and print clear instructions:

```
⚠️  <LOCAL_ENV> is a regular file, not a symlink.

The shared-token pattern requires each worktree's .env to be a symlink to
../.env so one token rotation updates every workspace.

To migrate (preserves your existing contents):
  cat .env >> ../.env     # merge into shared
  rm .env                 # remove the local
  ln -s ../.env .env      # symlink it

Review ../.env afterwards to dedupe any keys.
```

## Bundle IDs per scheme

| Scheme | Bundle id |
|--------|-----------|
| Convos (Dev) | `org.convos.ios-preview` |
| Convos (Local) | `org.convos.ios-local` |
| Convos (Prod) | `org.convos.ios` |

## Why the shared-parent pattern

Engineers working across multiple convos-ios worktrees want one Firebase debug token:
- One place to rotate when the token expires or gets removed from the Firebase Console
- No per-worktree duplication or drift
- New worktrees created via `convos-task new` pick it up automatically (the script symlinks `.env` → `../.env` when the parent exists)

`/setup`'s `.env` warning also leads with the symlink recipe to keep every worktree on the same token.
