# Test: Join Conversation via Paste in Scan View (Two Simulators)

Verify that a conversation created on one device can be joined from a second device by pasting the invite URL in the scan view.

## Requirements

- **Two simulators required.** This test uses Device A (inviter) and Device B (joiner) — both running the Convos app. The CLI must not be used as a substitute for either device.
- The `invite.url_displayed` QA event is used to extract the invite URL from Device A's logs.

## Prerequisites

- Both simulators are booted with the app installed and launched.
- Device A has at least one conversation (if running after test 03, this is already satisfied).

## Setup

Resolve both simulator UDIDs. Throughout this test:
- **Device A** = the inviter/creator simulator
- **Device B** = the joiner simulator

Initialize log markers for both devices.

## Steps

### Create a conversation on Device A

1. On Device A, tap the compose button to create a new conversation.
2. Wait for the QR code to appear.
3. Name the conversation "Paste Invite Test" via the Customize flow.
4. Extract the invite URL from Device A's logs:
   ```bash
   LOG=$(find ~/Library/Developer/CoreSimulator/Devices/$DEVICE_A_UDID/data/Containers/Shared/AppGroup -name "convos.log" -print -quit)
   INVITE_URL=$(grep "invite.url_displayed" "$LOG" | tail -1 | grep -o 'url=https://[^ ]*' | sed 's/url=//')
   ```

### Copy the invite URL to Device B's clipboard

5. Write the invite URL to Device B's pasteboard:
   ```bash
   echo -n "$INVITE_URL" | xcrun simctl pbcopy $DEVICE_B_UDID
   ```

### Open the scan view on Device B and paste

6. On Device B, navigate to the home screen (conversations list).
7. Tap the scan button in the bottom toolbar (accessibility identifier: `scan-button`).
8. The scan/join view should appear.
9. Tap the paste button (accessibility identifier: `paste-invite-button`).
10. The app should process the pasted invite and begin the join flow.

### Verify Device B joins the conversation

11. Wait for Device B to show either:
    - The "Verifying" state, followed by transition to the conversation view, or
    - The conversation view directly (if Device A processes the join request quickly).
12. Verify the conversation toolbar shows "Paste Invite Test" and "2 members".
13. Verify "You joined as Somebody" or similar join message appears.

### Exchange messages between devices

14. On Device B, send "Hello via paste!".
15. On Device A, verify the message appears.
16. On Device A, reply with "Paste reply!".
17. On Device B, verify the reply appears.

## Teardown

Navigate both devices back to the home screen.

## Pass/Fail Criteria

- [ ] Scan view opens from the conversations list
- [ ] Paste button is present and tappable
- [ ] Pasting a valid invite URL triggers the join flow
- [ ] Device A auto-processes the join request (no CLI needed)
- [ ] Device B enters the conversation with correct name and member count
- [ ] Two-way messaging works between Device A and Device B
