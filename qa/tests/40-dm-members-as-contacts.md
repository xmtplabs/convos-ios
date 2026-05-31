# 40 - DM Members As Contacts (two simulators)

The HUMAN counterpart to the agents-as-contacts tests: a non-agent member you share
a conversation with shows up as a contact (named, **no** Agent pill). Requires two
simulators (Device A + Device B) - two real people DMing - following the multi-device
convention from test 03.

## What this guards

| Behavior | Code | Step |
|---|---|---|
| A named human member is a visible contact | `Contact+BrowseVisibility.isVisibleInContactsList` human branch (not an agent -> needs a non-empty `displayName`) | `device_a_sees_bob_as_contact` / `device_b_sees_alice_as_contact` |
| No Agent pill for a human | `ContactRowView` shows `RoleLabelPill` only for `isVerifiedAgent` | both contact-assertion steps |
| Contact created after the local user acts | `ContactSyncCoordinator.syncContactsOnFirstMessage` (both directions) | `exchange_messages` |

## Key facts

- **Two simulators.** `resolve_two_simulators` saves `device_a_udid` / `device_b_udid`;
  steps are scoped with `device: A` / `device: B`, and cross-device actions use
  `device_a_*` / `device_b_*` (per test 03). Both must be erased, booted, have the
  **Local** app installed, and be **authorized** (App Check token - see the
  `36-agents-as-contacts.md` runbook; humans need no agent/credits provisioning, so
  the agent-templates backend gap does not affect this test).
- **Names are required.** A human contact is only visible when it has a `displayName`
  (an unnamed member renders as "Somebody" and is filtered out). So each device sets
  its per-conversation profile name (`setup-profile-button` ->
  `quick-edit-display-name-field`) - Device A = "Alice", Device B = "Bob".
- **Both must send.** The contact-sync gate is the local user's first message, so the
  test has each device send once; then each mirrors the other as a contact.
- The invite is extracted from Device A's `invite.url_displayed` event and opened on
  Device B with `sim_open_url` (the clean device-to-device join path on fresh sims,
  per test 03 - unlike the CLI/agent invite path which is unreliable here).

## Runbook (two simulators)

```bash
cd <this convos-ios checkout>
LS="$(git rev-parse --show-toplevel)/dev/local-stack"
make -C "$LS" status                       # backend/herald/worker/minio = 200
make -C "$LS" ios-config IOS="$(pwd)"

# Build the Local app once.
SIM_A=<device A udid>; SIM_B=<device B udid>   # clone a second iPhone sim if needed
APP=$(find .derivedData/Build/Products -path '*Local-iphonesimulator*' -name 'Convos.app' -type d | head -1)
for S in "$SIM_A" "$SIM_B"; do
  xcrun simctl erase "$S"; xcrun simctl boot "$S"
  xcrun simctl install "$S" "$APP"
  xcrun simctl launch "$S" org.convos.ios-local           # first launch wipes + makes ephemeral App Check token
  xcrun simctl terminate "$S" org.convos.ios-local
  xcrun simctl spawn "$S" defaults write org.convos.ios-local GACAppCheckDebugToken "<registered Local token>"
  xcrun simctl launch "$S" org.convos.ios-local           # now authorizes (no 403)
done
# Run via /qa 40, or drive the YAML with the two udids.
```

> Authorization gotcha (shared with 36): after an erase the app generates an
> unregistered App Check debug token and 403s on `exchangeDebugToken`. Force the
> registered Local token into `GACAppCheckDebugToken` (above) and relaunch so the inbox
> reaches `clientAuthorized`; otherwise the conversation list / contacts stay empty.

## Status

Authored to the test-03 multi-device convention + the validated contact rules. Not yet
run end-to-end here (needs a second simulator); the single-device contact mechanics
(local-send gate, `isVisibleInContactsList`, no-pill-for-human) are the same ones
validated in test 36 and the ConvosCore unit suite.
