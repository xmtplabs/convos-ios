# Test: Pair Device

Verify that two devices can pair via the Vault pairing flow, and that after pairing, conversations from both devices are synced across both devices.

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
15. The Devices screen should show only the current device (with "This device" label) or the empty state with "No other devices".
16. Tap "Add new device" (`add-new-device-button` or `add-device-button`).
17. The pairing sheet should appear with title "Pair new device" and a blurred QR code.
18. Long-press the "Hold to reveal" button (`hold-to-reveal-button`) to reveal the QR code. Keep holding for at least 1 second and observe the QR code becomes visible (blur removed, full opacity, full scale).

### Extract the pairing URL

19. While the QR code is visible, tap the "Share" button (`share-pairing-link`).
20. The system share sheet should appear. Tap "Copy" to copy the pairing URL to the pasteboard.
21. Read the pairing URL from Device A's pasteboard using `xcrun simctl pbpaste <DEVICE_A_UDID>`.
22. Verify the URL has the format `https://dev.convos.org/pair/<slug>?expires=<unix_timestamp>`.
23. Dismiss the share sheet (tap outside or press Escape).

### Open pairing URL on Device B

24. On **Device B**, open the pairing URL as a deep link using `sim_open_url`.
25. The joiner pairing sheet should appear with title "Request to pair".
26. A 6-digit pin should be displayed (`pairing-pin-display`). Read the pin text from the accessibility tree.
27. An expiry countdown should be visible.
28. Text should indicate "the other device is requesting to pair" and instruct to enter the code on the other device.

### Enter pin on Device A

29. On **Device A**, the pairing sheet should have transitioned from the QR code state to the pin entry state. Wait for the pin entry field (`pin-entry-field`) to appear (this may take several seconds as the join request travels over the network).
30. The sheet should show the name of Device B and "Enter the code shown on the new device".
31. Type the 6-digit pin (read from step 26) into the pin entry field.
32. The "Approve" button (`approve-button`) should become enabled once all 6 digits are entered.

### Approve pairing

33. Tap the "Approve" button on **Device A**.
34. The sheet should transition to the "syncing" state showing "Pairing..." with a rotating sync icon.
35. After a few seconds, the sheet should transition to the "completed" state. The title should change to "Device added" and show a checkmark icon with Device B's name.
36. Tap "Got it" (`got-it-button`) to dismiss the pairing sheet.

### Verify Device A shows both devices

37. The Devices screen should now show two devices in the list.
38. One device should have the "This device" label (Device A).
39. The other device should show Device B's simulator name.

### Verify conversation sync on Device A

40. Navigate back to the conversations list on **Device A** (tap the back button from Devices → Settings, then dismiss settings).
41. The conversations list should contain **both** "Device A Convo" and "Device B Convo". Device B's conversation was synced to Device A as part of the pairing key share.

### Verify conversation sync on Device B

42. On **Device B**, dismiss the pairing sheet if it's still showing (it may have transitioned to completed, or may still be on the pin screen — either dismiss or tap "Got it" if available).
43. Navigate to the conversations list on **Device B**.
44. The conversations list should contain **both** "Device A Convo" and "Device B Convo". Device A's conversation was synced to Device B as part of the pairing key share.

## Teardown

No specific cleanup needed — the simulators were started fresh for this test and can be erased for the next test.

## Pass/Fail Criteria

- [ ] Device A shows empty state or single-device state before pairing
- [ ] Pairing sheet opens with blurred QR code and "Pair new device" title
- [ ] QR code reveals when holding the "Hold to reveal" button
- [ ] Pairing URL has correct format (`https://dev.convos.org/pair/<slug>?expires=<timestamp>`)
- [ ] Device B shows joiner pairing sheet with 6-digit pin after opening pairing URL
- [ ] Device A transitions to pin entry state after Device B sends join request
- [ ] Pin can be entered on Device A and "Approve" button enables
- [ ] Pairing completes successfully — Device A shows "Device added" with checkmark
- [ ] Devices list on Device A shows both devices (one marked "This device")
- [ ] Device A's conversations list contains both "Device A Convo" and "Device B Convo"
- [ ] Device B's conversations list contains both "Device A Convo" and "Device B Convo"

## Notes

- The pairing timeout is currently set to 120 seconds for dev testing. All steps from URL extraction through approval must complete within this window.
- Device B's joiner sheet may not transition to "completed" automatically — this is a known limitation. The joiner currently stays on the pin screen until expiry or manual dismissal. Verify pairing success from Device A's perspective and by checking conversation sync on both devices.
- Both devices must have network connectivity to the XMTP dev network for the pairing flow to work.
- Each simulator generates its own unique vault identity on first launch, so cloned simulators must be erased first to avoid "memberCannotBeSelf" errors from XMTP.

## Accessibility Improvements Needed

- The "Hold to reveal" button uses a `DragGesture` which may not be triggerable via accessibility tools. A long-press via `sim_ui_tap` with `duration` may be needed as a workaround.
- The pin entry field uses a hidden `TextField` behind digit boxes — typing works via `sim_ui_type` after tapping the field, but the accessibility identifier is on the outer container, not the hidden text field.
- The joiner pairing sheet's pin display (`pairing-pin-display`) should expose the pin value as an `accessibilityValue` for easier programmatic reading, not just as label text.
