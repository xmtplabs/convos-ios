# Test: Devices Screen iCloud Section

Verify the expanded Devices screen (Settings > Devices): the paired section's "Devices using this account" footer, the "Other devices in iCloud" section listing keys from the iCloud-synced keychain backup that aren't paired to the current account, the Main-device designation on the oldest key, the targeted initiator pairing sheet when an iCloud device is tapped, and the escalated delete-all copy on the main device.

## Prerequisites

- One simulator: the branch primary (used only as a clone source; its app state is never touched).
- A built non-production Convos.app (the wipe launch hook is runtime-gated off in production).

## Setup

1. Shut down the primary, clone it as `convos-qa-devices`, erase the clone, boot both, relaunch the app on the primary, install the built app on the clone.
2. Every clone launch needs `SIMCTL_CHILD_FIRAAppCheckDebugToken="$FIREBASE_APP_CHECK_DEBUG_TOKEN"` (source `.env`).

## Steps

### Main-device delete guard (single key)

1. Launch the app (fresh identity registers and mirrors into the backup slot; give it ~10s). Navigate Convos tab -> Convos logo -> app settings, tap `delete-all-data-button`. The confirmation subtitle must include "This is your main device" - the account's only key is trivially the oldest. Cancel.

### Seed a second identity

2. Terminate and relaunch with `SIMCTL_CHILD_CONVOS_QA_WIPE_PRIMARY_IDENTITY=1`. The hook wipes the device-local identity (`app.qa_wiped_primary_identity`), a fresh placeholder registers, and the original key remains in iCloud as a foreign device - older, hence the Main device. The found-device prompt appears (older keys are offered); tap Skip - test 44 covers the prompt, and the decline flag doesn't affect the Devices screen. Save the prompt's inboxId/deviceName as the main key's.

### Same-name filter

3. Navigate to Settings > Devices. The foreign key's device name equals this device's name at this point, so the "Other devices in iCloud" section must be absent - a listed device's abandoned old identity never shows the same device in both sections. Navigate back out.
4. Terminate and relaunch with `SIMCTL_CHILD_CONVOS_QA_RENAME_FOREIGN_BACKUPS="Old iPhone"` (`app.qa_renamed_foreign_backups` count>=1) to give the foreign key a distinct name.

### Devices screen

5. Navigate to Settings > Devices. Verify the paired section's footer "Devices using this account", the "Other devices in iCloud" footer, and `icloud-device-row-<inboxId>` for the foreign key.
6. Verify exactly one "Main device" designation, on the foreign iCloud row (the current-device row shows plain "This device").
7. Tap the iCloud row: `pairing.devices_icloud_pair_tapped` fires and the initiator pairing sheet presents with the scan instruction 'Open Convos on "<name>" and scan this code to pair'. The current account stays the main account - the join would happen from the other device. Dismiss without pairing.

## Teardown

Shut down and delete the `convos-qa-devices` clone; the primary simulator was never modified.

## Pass/Fail Criteria

- [ ] Delete-all confirmation on the sole-key device includes the escalated "This is your main device" sentence
- [ ] Wipe hook seeds the second identity (`qa_wiped_primary_identity status=0`)
- [ ] While the foreign key shares this device's name, no iCloud section is shown (same-name filter)
- [ ] Rename hook gives the foreign key a distinct name (`qa_renamed_foreign_backups` count>=1)
- [ ] Devices screen shows both sections with the exact footers, and the foreign key's row
- [ ] Exactly one Main-device designation, on the oldest key's row
- [ ] Tapping the iCloud row emits `pairing.devices_icloud_pair_tapped` and the sheet's scan instruction names the device

## Accessibility Improvements Needed

None known - rows expose `icloud-device-row-<inboxId>`, and the flow reuses `devices-row`, `devices-view`, `skip-found-device-pairing-button`, and `delete-all-data-button`.
