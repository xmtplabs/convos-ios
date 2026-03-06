# Test: Pair Device

Verify that two devices can pair via the Vault pairing flow with pin + emoji verification, and that after pairing, conversations from both devices are synced across both devices.

## Prerequisites

- Two iOS Simulators are available, referred to as **Device A** and **Device B**.
- Both simulators have been erased (`xcrun simctl erase`) to ensure completely fresh state — no prior app data, keychain, or vault identity.
- The app is freshly installed on both simulators.
- Both simulators have Reduce Motion enabled and animations disabled (per RULES.md simulator preparation).

## Setup

### Prepare simulators

1. Erase both simulators, boot them, and install a fresh build of the app on each.
2. Launch the app on both simulators. Both should show the empty-state onboarding screen ("Pop-up private convos").

### Create a conversation on Device A

3. On **Device A**, tap the compose button to start a new conversation.
4. Complete onboarding if prompted (quickname setup, notification permission — dismiss or complete quickly).
5. Name the conversation something identifiable like "Device A Convo".
6. Send a message (e.g., "Hello from A") so the conversation is created on the network.
7. Navigate back to the conversations list. Verify "Device A Convo" appears.

### Create a conversation on Device B

8. On **Device B**, tap the compose button to start a new conversation.
9. Complete onboarding if prompted.
10. Name the conversation something identifiable like "Device B Convo".
11. Send a message (e.g., "Hello from B") so the conversation is created on the network.
12. Navigate back to the conversations list. Verify "Device B Convo" appears.

## Steps

### Initiate pairing on Device A

13. On **Device A**, tap the settings button (`app-settings-button`).
14. Tap the "Devices" row (`devices-row`).
15. The Devices screen should show only the current device (with "This device" label).
16. Tap "Add new device" (`add-device-button`).
17. The pairing sheet should appear with title "Pair new device" and a blurred QR code.
18. Long-press the "Hold to reveal" button (`hold-to-reveal-button`) to reveal the QR code.

### Extract the pairing URL

19. Read the pairing URL from the app event log using `sim_log_events(udid=DEVICE_A_UDID, event_filter="vault.pairing_url_created")`. The URL is in the `url=` parameter of the event line.
20. Verify the URL has the format `https://dev.convos.org/pair/<slug>?expires=<unix_timestamp>&name=<device_name>`.

### Open pairing URL on Device B

21. On **Device B**, open the pairing URL as a deep link using `sim_open_url`.
22. The joiner pairing sheet should appear with title "Request to pair".
23. The sheet should show a connecting/loading state briefly, then the text should read `"<Device A name>" is requesting to pair. Paired devices sync all conversations.`

### Device A shows generated pin

24. On **Device A**, the pairing sheet should transition from the QR code to a pin display state. Wait for `pairing-pin-display` to appear.
25. The sheet should show `Share this code with "<Device B name>" to continue pairing.` with a 6-digit pin displayed below.
26. Read the pin from the accessibility tree (`pairing-pin-display`).

### Device B enters pin

27. On **Device B**, the sheet should have transitioned to pin entry. Wait for `pin-entry-field` to appear.
28. The sheet should read `Enter the code shown on "<Device A name>" to finish pairing.`
29. Type the 6-digit pin (read from step 26) into the pin entry field.
30. The "Submit" button (`submit-pin-button`) should become enabled once all 6 digits are entered.
31. Tap "Submit".

### Verify emoji fingerprint on both devices

32. On **Device B**, the sheet should transition to show 3 emoji (`pairing-emoji-fingerprint`). Title changes to "Confirm pairing". Text reads `Make sure these emoji match on "<Device A name>".` with "Waiting for confirmation..." below.
33. On **Device A**, the sheet should also transition to show the same 3 emoji (`pairing-emoji-fingerprint`). Title changes to "Confirm pairing". Text reads `Make sure these emoji match on "<Device B name>" before confirming.`
34. Verify the emoji shown on both devices are identical.

### Confirm pairing on Device A

35. Tap "Confirm" (`confirm-emoji-button`) on **Device A**.
36. The sheet should transition to the "syncing" state showing "Pairing..." with a rotating sync icon.
37. After a few seconds, the sheet should transition to the "completed" state. The title should change to "Device added" and show a checkmark icon with Device B's name.
38. Tap "Got it" (`got-it-button`) to dismiss the pairing sheet.

### Verify Device A shows both devices

39. The Devices screen should now show two devices in the list.
40. One device should have the "This device" label (Device A).
41. The other device should show Device B's simulator name.

### Verify conversation sync on Device A

42. Navigate back to the conversations list on **Device A** (tap the back button from Devices → Settings, then dismiss settings).
43. The conversations list should contain **both** "Device A Convo" and "Device B Convo". Device B's conversation was synced to Device A as part of the pairing key share.

### Verify conversation sync on Device B

44. On **Device B**, dismiss the pairing sheet if it's still showing (tap "Got it" if available).
45. Navigate to the conversations list on **Device B**.
46. The conversations list should contain **both** "Device A Convo" and "Device B Convo". Device A's conversation was synced to Device B as part of the pairing key share.

## Teardown

No specific cleanup needed — the simulators were started fresh for this test and can be erased for the next test.

## Pass/Fail Criteria

- [ ] Device A shows single-device state before pairing
- [ ] Pairing sheet opens with blurred QR code and "Pair new device" title
- [ ] Pairing URL has correct format with `&name=` parameter
- [ ] Device B shows joiner sheet with Device A's name after opening URL
- [ ] Device A generates and displays a 6-digit pin after receiving join request
- [ ] Device B shows pin entry field to enter Device A's pin
- [ ] Both devices show matching 3-emoji fingerprint after pin submission
- [ ] Pairing completes after emoji confirmation — Device A shows "Device added"
- [ ] Devices list on Device A shows both devices (one marked "This device")
- [ ] Device A's conversations list contains both "Device A Convo" and "Device B Convo"
- [ ] Device B's conversations list contains both "Device A Convo" and "Device B Convo"

## Notes

- The pairing timeout is currently set to 120 seconds for dev testing. All steps from URL extraction through emoji confirmation must complete within this window.
- The pairing URL is extracted from the `vault.pairing_url_created` QA event in the app log. Do not use the share sheet "Copy" button — it is unreliable due to iOS share sheet accessibility limitations.
- The emoji fingerprint is derived from `SHA256(sorted(inboxA, inboxB) + pin)` — both devices compute it independently, so matching emoji proves both devices are talking to each other (not an attacker).
- Each simulator generates its own unique vault identity on first launch, so cloned simulators must be erased first to avoid "memberCannotBeSelf" errors from XMTP.
