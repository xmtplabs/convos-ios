# Test: Pairing Prompt Ordering (Newer Backups Suppressed)

Verify the pairable-backup ordering rule: the first-install "Pair <device>?" prompt only offers iCloud-synced backups created *before* this install's own key. A backup written after this install's key (i.e. a second device set up later) must never be offered - the first device must not offer to demote itself to the newer identity.

## Prerequisites

- One simulator: the branch primary, fully onboarded (its app mirrors its identity into the synced-backup keychain slot automatically on registration).
- A non-production build - both QA launch hooks used here are runtime-gated off in production.

## Setup

All steps run on a disposable clone so the primary simulator's account state is never touched:

1. Shut down the primary (`simctl clone` requires it), clone it as `convos-qa-ordering`, boot both, relaunch the app on the primary. The clone's keychain contains the primary identity item and its synced-backup mirror.
2. Every app launch on the clone needs the App Check debug token for placeholder registration: `source .env` and pass `SIMCTL_CHILD_FIRAAppCheckDebugToken="$FIREBASE_APP_CHECK_DEBUG_TOKEN"` on each `simctl launch`.

## Steps

### Establish a newer own key with an older foreign backup

1. Launch the app on the clone with `SIMCTL_CHILD_CONVOS_QA_WIPE_PRIMARY_IDENTITY=1`. The hook deletes the device-local identity (`app.qa_wiped_primary_identity` with `status=0`) and the app registers a fresh placeholder whose backup mirror is stamped now; the prior identity's older backup is discovered and the "Pair <name>?" sheet appears (`pairing.found_device_prompt_shown`). Do not tap Skip - it sets the `hasDeclinedFoundDevicePairing` flag and would suppress the prompt for the rest of the test. Terminate the app to move on.

### Newer foreign backup is suppressed

2. Relaunch with `SIMCTL_CHILD_CONVOS_QA_RESTAMP_FOREIGN_BACKUPS=3600`. The hook rewrites every non-own backup's `backedUpAt` to now+3600s (`app.qa_restamped_foreign_backups` with `count=<n>`; `count=0` means no foreign backup was present and the setup failed - do not treat it as a pass).
3. The launch's `pairing.found_device_check` must report `pairableCount=0` and the prompt must not appear. This is a negative check: after the check event fires, poll for `pair-found-device-button` over ~8 seconds and require zero matches.

### Older foreign backup is offered again

4. Relaunch with `SIMCTL_CHILD_CONVOS_QA_RESTAMP_FOREIGN_BACKUPS=-86400`. The same backup is restamped a day into the past; `pairing.found_device_check` reports `pairableCount>=1` and the "Pair <name>?" sheet appears again (`pairing.found_device_prompt_shown`). This proves step 3's suppression was the ordering rule and not a decline flag, keychain miss, or hook side effect - the only thing that changed between the launches is the timestamp.

## Teardown

Shut down and delete the `convos-qa-ordering` clone. It holds only a throwaway placeholder identity; the primary simulator was never modified.

## Pass/Fail Criteria

- [ ] On the wiped launch, `app.qa_wiped_primary_identity` fires with `status=0` and the Pair prompt appears for the prior identity's backup
- [ ] With the foreign backup restamped to now+3600s, `pairing.found_device_check` reports `pairableCount=0` and the prompt does not appear (`qa_restamped_foreign_backups count >= 1`)
- [ ] With the foreign backup restamped to now-86400s, `pairing.found_device_check` reports `pairableCount>=1` and the prompt appears again

## Accessibility Improvements Needed

None known - the test reuses test 44's identifiers (`pair-found-device-button`) and log events end-to-end.
