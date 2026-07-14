# Test: Reinstall Message Continuity

Verify that deleting and reinstalling the app does not break an actively chatting identity: the device keychain outlives the app, so a reinstall resumes the same inbox with a new XMTP installation. After the reinstall, messages must flow in both directions in every conversation the identity was in, the same inboxId must resume, and the previous (dead) installation must be auto-revoked.

## Prerequisites

- One simulator: the branch primary (used only as a clone source; its app state is never touched).
- The convos CLI initialized against the dev network (User B).
- A built non-production Convos.app.

## Setup

1. Shut down the primary (`simctl clone` requires it), clone it as `convos-qa-reinstall`, **erase the clone** (a fresh account is the point of this test), boot both, relaunch the app on the primary. Install the built app on the clone.
2. Every launch on the clone needs the App Check debug token for registration: `source .env` and pass `SIMCTL_CHILD_FIRAAppCheckDebugToken="$FIREBASE_APP_CHECK_DEBUG_TOKEN"` on each `simctl launch`.
3. Launch the app (fresh identity registers). Create two conversations shared with the CLI: for each, the CLI creates the conversation and generates an invite, the app joins via the invite deep link, and the CLI processes the join request (per invite ordering rules in RULES.md). Record the app's inboxId from the authorization log line as `inbox_id_before`.

## Steps

### Baseline

1. In conversation 1: CLI sends "pre-reinstall from B (1)" and it appears in the app; the app sends "pre-reinstall from A (1)" and the CLI reads it.
2. In conversation 2: same exchange with the "(2)" texts. This is the baseline the reinstall must preserve.

### Reinstall

3. Terminate the app, `xcrun simctl uninstall $clone org.convos.ios-preview` (deletes app and app-group containers; the keychain survives), reinstall the same built app, launch with the App Check token.
4. The app resumes the same identity from the keychain and mints a new installation; on reaching ready it revokes the previous one - `pairing.stale_own_installations_revoked count=1` in the app log. Note the group-container path changed with the reinstall; re-resolve it before grepping. Confirm the authorization log line carries the same inboxId (`inbox_id_after`).

### Post-reinstall delivery

5. CLI sends "post-reinstall from B (1)" and "(2)" into both conversations. The reinstalled app starts with an empty local database; the conversations must reappear once the new installation is welcomed back into the groups - give the first appearance a generous timeout (the CLI's send is also what prompts B's client to commit A's new installation). If nothing appears, foreground-cycle the app once before failing. Both messages must appear in the app.
6. The app sends "post-reinstall from A (1)" and "(2)" in the respective conversations; the CLI must read both.
7. Observational: note whether the pre-reinstall messages are visible again and record it as `history_visible_after_reinstall` - either outcome passes; the finding informs the reinstall-history product decision.

## Teardown

CLI explodes both conversations. Shut down and delete the `convos-qa-reinstall` clone; the primary simulator was never modified.

## Pass/Fail Criteria

- [ ] Baseline: both directions deliver in both conversations before the reinstall
- [ ] The reinstall launch emits `pairing.stale_own_installations_revoked` with count >= 1
- [ ] The inboxId after the reinstall equals the inboxId before (resumed, not re-registered)
- [ ] CLI messages sent after the reinstall appear in the app, in both conversations
- [ ] App messages sent after the reinstall are readable via CLI, in both conversations
- [ ] `history_visible_after_reinstall` recorded (observational, either outcome passes)

## Accessibility Improvements Needed

None known - the test reuses message-field and send-button identifiers from test 02 and log events end-to-end.
