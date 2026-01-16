# Firebase Token

Check the simulator logs for a Firebase App Check debug token.

## Usage

```
/firebase-token
```

## When to Use

Run this command when:
- You've launched the app on a new simulator
- You're seeing Firebase App Check errors
- The app can't connect to Firebase services

## Instructions

### Step 1: Verify App is Running

Check that the app is running in a simulator. If not, inform the user to run `/build --run` first.

### Step 2: Capture Logs

1. Get the bundle ID from the current scheme (default: org.convos.ios-preview for Dev)

2. Start log capture with console output:
   ```
   mcp__XcodeBuildMCP__start_sim_log_cap with bundleId and captureConsole: true
   ```

3. Wait 3-5 seconds for logs to accumulate

4. Stop log capture and retrieve logs:
   ```
   mcp__XcodeBuildMCP__stop_sim_log_cap with logSessionId
   ```

### Step 3: Search for Token

Search the logs for Firebase App Check debug token pattern:
- Pattern: `[AppCheckCore][I-GAC004001] App Check debug token: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'`
- The token is a UUID inside single quotes

### Step 4: Report Result

**If token found:**
```
🔥 Firebase App Check Debug Token

Token: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

Add it here: https://console.firebase.google.com/u/1/project/convos-otr/appcheck/apps

Steps:
1. Click the link above
2. Select the iOS app matching your scheme:
   - Dev: org.convos.ios-preview
   - Local: org.convos.ios-local
   - Prod: org.convos.ios
3. Click the overflow menu (⋮) → "Manage debug tokens"
4. Click "Add debug token" and paste the token
```

**If no token found:**
```
No Firebase App Check debug token found in logs.

This could mean:
- The simulator is already registered with Firebase
- The app hasn't initialized Firebase yet (try interacting with the app)
- Logs were captured too early (try running /firebase-token again)
```

## Bundle IDs

| Scheme | Bundle ID |
|--------|-----------|
| Convos (Dev) | org.convos.ios-preview |
| Convos (Local) | org.convos.ios-local |
| Convos (Prod) | org.convos.ios |
