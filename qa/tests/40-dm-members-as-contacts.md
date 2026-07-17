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
  its per-conversation profile name to `quick-edit-display-name-field` - Device A =
  "Alice", Device B = "Bob". Both open that field via `setup-profile-button`
  ("Add your name and pic"): the creator from the new-conversation screen, the
  joiner from the same button surfaced under the message composer while the
  conversation profile is still unset. The in-composer avatar button was removed
  in the composer redesign.
- **Compose goes through the picker.** `compose-button` opens the ContactsPicker in
  "compose" mode first (existing contacts, empty on a fresh device); tap
  `contacts-picker-confirm` (label "Skip") to reach the invite/new-conversation screen.
- **Both must send.** The contact-sync gate is the local user's first message, so the
  test has each device send once; then each mirrors the other as a contact.
- **Local invites need the custom scheme.** Device A's `invite.url_displayed` event is
  the https universal link (`https://local.convos.org/v2?i=<slug>`). On the simulator
  the local host serves no apple-app-site-association, so opening that https URL lands
  in **Safari**, not the app. For the Local scheme, route the invite into the app via
  the registered custom scheme: build `convos-local://invite/<slug>` from the `?i=`
  slug and `sim_open_url` that (`DeepLinkHandler` accepts host `invite`). If the open
  is routed through Safari, tap the "Open in Convos?" -> Open prompt. (Dev/Prod
  universal links deep link directly because those domains serve AASA - see test 03.)

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

Validated green end-to-end on two simulators against the local stack. Device A
("Alice") created the conversation; Device B joined via the `convos-local://invite/`
deeplink (the https universal link fell through to Safari, as expected on the local
host) and named itself "Bob"; both exchanged a message. Result:

- **Device A Contacts**: "Bob" renders as a plain contact row (label "Bob", no Agent
  pill). On a freshly erased Device A this is the only contact, so the
  `element_not_exists "Agent"` assertion holds; if A already has agent contacts they
  carry the pill and Bob still does not.
- **Device B Contacts**: "Alice" renders as a plain contact (count 1, no Agent pill).

Confirms `isVisibleInContactsList` (human branch), `RoleLabelPill` only for verified
agents, and the bidirectional `ContactSyncCoordinator.syncContactsOnFirstMessage`
gate. Leaves the A<->B conversation in place for test 40b.
