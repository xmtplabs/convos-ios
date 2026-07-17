# Test: iCloud Pairing Prompt (Two Simulators)

Verify the first-install "Pair <device>?" prompt: a fresh install that finds another device's identity in the iCloud-synced keychain backup slot offers to pair with it, Skip declines persistently, and Pair runs the standard joiner pairing handshake with the found inbox id as the main device - no QR scan on either side.

## Prerequisites

- Two simulators. Device A is the branch primary, fully onboarded (its app mirrors its identity into the synced-backup keychain slot automatically on registration). Device B is created in setup as a clone of Device A.
- The app build used on Device A is also installed on Device B (non-production build - the QA launch hook is runtime-gated off in production).

## Setup

Simulators don't sync iCloud Keychain, so the "new device on the same iCloud account" state is seeded by cloning, then wiping only the device-local identity:

1. Shut down Device A (`simctl clone` requires it), clone it as `convos-qa-icloud-b`, boot both, relaunch the app on A. The clone's keychain contains both A's primary identity item and A's synced-backup item.
2. On Device B: uninstall the app (clears app + group containers; the keychain survives), reinstall the built `Convos.app`, then launch with `SIMCTL_CHILD_CONVOS_QA_WIPE_PRIMARY_IDENTITY=1`. The `QALaunchHooks` hook deletes the device-local identity slot before session bootstrap and emits `app.qa_wiped_primary_identity`; the synced-backup item survives. The app registers a fresh placeholder identity and discovers A's backup.

> Single-sim debugging shortcut: launching the app once normally and relaunching with the same env var on the *primary* simulator reproduces the prompt without cloning (the prior identity's backup is still in the slot). Only the handshake portion needs the second simulator.

## Steps

### Seed verification and prompt

1. Check Device B's logs for the `app.qa_wiped_primary_identity` event with `status=0`. A `-25300` status means the slot was already empty - almost always a sign Device B was not cloned from Device A.
2. Wait for the prompt sheet (anchor: `pair-found-device-button`) on Device B. It reads "Pair <name>?" / "Your <name> was found in iCloud, if you have it nearby, you can pair it now", with a "Pair <name>" primary button and a "Skip" text button. The `pairing.found_device_prompt_shown` event fires with the found inboxId and deviceName (a `pairing.found_device_check` event with `pairableCount=<n>` fires on every launch's check and is the first thing to look at when the prompt doesn't show).

### Skip path

3. Tap Skip (`skip-found-device-pairing-button`). The sheet dismisses to the chats list and `pairing.found_device_prompt_skipped` fires.
4. Terminate and relaunch the app (without the wipe env var). The prompt must not reappear - the decline persists in UserDefaults. This is a negative check: settle on `compose-button`, then poll for the sheet over ~8 seconds and require zero matches.
5. Terminate the app and delete the flag from the app container's preferences - the domain must be the container plist path, not the bundle id (`PREFS="$(xcrun simctl get_app_container $B org.convos.ios-preview data)/Library/Preferences/org.convos.ios-preview"; xcrun simctl spawn $B defaults delete "$PREFS" hasDeclinedFoundDevicePairing`). Relaunch: the prompt reappears - the decline flag is the only suppressor while the backup is present.

### Seed pre-pairing history

5b. On Device A, compose a new conversation and send "History probe 44" (`compose-button`, `message-text-field`, `send-message-button`), then return to the chats list. This message must exist before the pair handshake: Device B's installation registers during pairing, and forward secrecy hides everything earlier from it - only the post-pair history sync can deliver it.

### Pair path

6. Tap "Pair <name>" (`pair-found-device-button`). The prompt dismisses and the joiner sheet ("Request to pair") presents with instruction copy: 'Open Convos on "<name>" to continue pairing.' The `pairing.found_device_invite_minted` event fires. The joiner immediately sends a join request and re-sends every 5 seconds while connecting (5-minute window).
   - Conditional: if the "This device already has a Convos account" erase guard appears instead of the connecting state, hold "Hold to erase and pair" through (3s) and the flow continues. The relaunches in steps 4-5 commit Device B's auto-created inline-builder draft to a visible conversation, which trips the joiner flow's existing-data check (same guard as test 38).
7. Device A (foregrounded, no navigation) auto-presents the initiator sheet directly in the PIN state (`pairing-pin-display`) within ~10-15 seconds - its StreamProcessor verified the join request's slug against A's own identity key and the app surfaced it (`pairing.incoming_request_surfaced` event). If A's app is backgrounded instead, a local notification ("<device>" is requesting to pair) posts and the sheet presents on next activation. Save the PIN. Manual fallback for debugging: Settings > Devices > Add new device still works (test 38 path).
8. On Device B, enter the PIN in `pin-entry-field` and submit.
9. Both devices show the 3-emoji fingerprint - verify the emojis match visually (per the multi-simulator rules in RULES.md).
10. Device A taps Confirm. Both devices reach the completed state ("Device added" on A, "Device paired" on B); dismiss with Got it.

### Post-pair checks (optional)

10b. Device B fires `pairing.backend_reauth_after_pairing` within ~30s of pairing completion, and its `accountId` equals Device A's (from A's "Successfully authenticated with backend (SIWE, ...)" log line). This proves the joiner rebound backend auth to the adopted identity instead of riding its placeholder account's still-valid JWT.
11. Device B's conversation list mirrors Device A's history with no "Add your name and pic" CTA - proof the found inbox id became this device's identity.
11b. Device B fires `pairing.history_sync_requested` right after adoption and the "History probe 44" conversation (with its message body) appears within ~3 minutes - the joiner asked Device A for a history archive through the device-sync group and libxmtp imported it. Device A must stay foregrounded (it is the only peer that can answer). If nothing arrives by ~90s, background/foreground both apps once and keep polling.
12. Relaunch Device B once more: the prompt must not return even though the decline flag was cleared in step 5 - B's identity now matches the backup, so it is excluded from the pairable list.
13. (Manual, timing-sensitive) Background Device A's app, start a fresh pair attempt on a reset Device B within ~10s: Device A posts a local notification "<device>" is requesting to pair; foregrounding A presents the PIN sheet from the stashed request. For a killed app, the NSE detects the join request in the welcome/message push, shows the same banner, and stashes via `PendingPairRequestStore` - real devices only (simulators receive no remote APNS).

## Teardown

Shut down and delete the cloned `convos-qa-icloud-b` simulator. Do not delete Device A. Optionally revoke Device B's installation from A's Devices list (swipe row > Delete > hold) to leave A single-device for later tests.

## Pass/Fail Criteria

- [ ] The wipe hook fires on Device B with status=0
- [ ] The "Pair <name>?" sheet appears with the found-in-iCloud copy and Pair/Skip buttons
- [ ] Skip dismisses the sheet and emits `found_device_prompt_skipped`
- [ ] The prompt does not reappear after relaunch (decline persists)
- [ ] Deleting the decline flag re-prompts on the next launch
- [ ] Pair opens the joiner sheet with the open-Convos instruction copy and emits `found_device_invite_minted`
- [ ] (Conditional) The erase-and-pair guard is held through when Device B's auto-created draft has committed
- [ ] Device A auto-presents the PIN sheet from the verified join request - no navigation, no QR
- [ ] PIN entry, emoji match, and confirmation complete the handshake
- [ ] Both devices reach Device added / Device paired
- [ ] Device A commits the "History probe 44" conversation before the pair
- [ ] `pairing.history_sync_requested` fires on Device B and the probe message arrives via the history archive
- [ ] `pairing.backend_reauth_after_pairing` fires on Device B with Device A's accountId
- [ ] (Optional) Device B mirrors A's history with no onboarding CTA
- [ ] (Optional) No re-prompt after pairing despite the cleared decline flag

## Accessibility Improvements Needed

None known - the prompt sheet ships with `pair-found-device-button`, and `skip-found-device-pairing-button`; the handshake reuses test 38's identifiers (`pairing-pin-display`, `pin-entry-field`, `submit-pin-button`, `pairing-emoji-fingerprint`, `confirm-emoji-button`, `got-it-button`).
