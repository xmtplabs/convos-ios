# Test: Join Conversation via Deep Link (Two Simulators)

Verify that a conversation created on one device can be joined from a second device via invite deep link, including when the inviter is offline.

> **Single-inbox model (C10).** Joining no longer creates a per-conversation inbox on the joiner's device — the join reuses the singleton `MessagingService`. The user-facing flow is unchanged. There should be **no** "creating new inbox" UI indicator, no spinner explicitly tied to inbox provisioning, and no copy referencing a freshly-created identity. Flag any element that still announces inbox creation as an accessibility-text bug.

## Requirements

- **Two simulators required.** This test uses Device A (inviter) and Device B (joiner) — both running the Convos app. The CLI must not be used as a substitute for either device.
- Both simulators must be erased before this test to ensure clean state.
- The `invite.url_displayed` QA event is used to extract the invite URL from Device A's logs (since `simctl pbpaste` cannot read URL-type pasteboard items from the iOS share sheet).

## Prerequisites

- Both simulators are booted with the app installed and launched.
- Both simulators are on fresh (erased) state — no prior conversations.

## Setup

Resolve both simulator UDIDs. Throughout this test:
- **Device A** = the inviter/creator simulator
- **Device B** = the joiner simulator

Initialize log markers for both devices.

## Steps

### Part 1: Create conversation and join while inviter is online

#### Create a conversation on Device A

1. On Device A, tap the compose button to create a new conversation.
2. Wait for the QR code to appear (accessibility identifier: `invite-qr-code`).
3. Tap "Customize" to open the name editor.
4. Enter a conversation name like "Deep Link Test" in the `quick-edit-display-name-field`.
5. Tap the done button (`quick-edit-done-button`).
6. Verify the conversation name appears in the toolbar.

#### Extract the invite URL from Device A's logs

7. Read the `invite.url_displayed` event from Device A's logs using `sim_log_events` with `event_filter="invite.url_displayed"`.
8. Extract the URL from the event line. The format is: `url=https://dev.convos.org/v2?i=<slug>`.
9. Alternatively, read the app's log file directly:
   ```bash
   LOG=$(find ~/Library/Developer/CoreSimulator/Devices/$DEVICE_A_UDID/data/Containers/Shared/AppGroup -name "convos.log" -print -quit)
   INVITE_URL=$(grep "invite.url_displayed" "$LOG" | tail -1 | grep -o 'url=https://[^ ]*' | sed 's/url=//')
   ```

#### Open the invite on Device B via deep link

10. On Device B, open the invite URL using `sim_open_url`.
11. Wait for Device B to show either:
    - The "Verifying" state (`invite-accepted-view` with label containing "Verifying"), or
    - The conversation view directly (if Device A processes the join request very quickly).
12. If "Verifying" appears, wait up to 30 seconds for Device A to auto-process the join request and for Device B to transition to the conversation view.

#### Verify Device B joined the conversation

13. On Device B, verify the conversation toolbar shows the conversation name ("Deep Link Test") and "2 members".
14. Verify "You joined as Somebody" or similar join message appears.
15. Check `sim_log_events` on Device B for `conversation.joined` event.

#### Exchange messages between devices

16. On Device B, type "Hello from Device B!" in the message field and tap send.
17. On Device A, verify the message appears (search for label containing "Hello from Device B!").
18. On Device A, type "Reply from Device A!" and tap send.
19. On Device B, verify the message appears (search for label containing "Reply from Device A!").

### Part 2: Join while inviter is offline

This tests that the invite system works even when the inviter's device is completely offline — the joiner should see the "Verifying" state, and once the inviter comes back online, the joiner should be admitted automatically.

**Important:** Both simulators must be erased before Part 2 to avoid residual XMTP state from Part 1. If Device B has any prior relationship with Device A's XMTP identity (e.g., from joining a conversation in Part 1), the XMTP sync may resolve the invite as `.existing` and skip the "Verifying" state entirely.

#### Erase both simulators

20. Terminate the app and shut down both simulators.
21. Erase both simulators: `xcrun simctl erase $DEVICE_A_UDID && xcrun simctl erase $DEVICE_B_UDID`
22. Boot Device A, install the app, and launch it.

#### Create a conversation on Device A

23. Tap compose to create a new conversation.
24. Name it "Offline Invite Test".
25. Extract the invite URL from Device A's logs (use the latest `invite.url_displayed` event).

#### Shut down Device A completely

26. Terminate the app on Device A: `xcrun simctl terminate $DEVICE_A_UDID org.convos.ios-preview`
27. Shut down Device A's simulator: `xcrun simctl shutdown $DEVICE_A_UDID`
28. Verify Device A is fully shut down (no background processing, no push notifications).

#### Boot Device B and open the invite while Device A is offline

29. Boot Device B, install the app, and launch it.
30. Open the invite URL on Device B using `sim_open_url`.
31. Wait for the "Verifying" state to appear on Device B (`invite-accepted-view` with label containing "Verifying").
32. Verify Device B shows "Verifying" — the join request was sent but cannot be processed because Device A is offline.
33. Wait 5 seconds and verify Device B is still in the "Verifying" state (it should not resolve while Device A is offline).

#### Bring Device A back online

34. Boot Device A's simulator: `xcrun simctl boot $DEVICE_A_UDID`
35. Launch the app on Device A: `xcrun simctl launch $DEVICE_A_UDID org.convos.ios-preview`

#### Verify Device B gets admitted

36. On Device B, wait up to 60 seconds for the conversation to transition out of "Verifying" state.
37. Verify Device B's conversation toolbar shows "Offline Invite Test" and "2 members".
38. Verify two-way messaging works:
    - Device B sends "Hello after offline!"
    - Device A receives the message
    - Device A replies
    - Device B receives the reply

## Teardown

Navigate both devices back to the home screen. The conversations can be left in place for subsequent tests or exploded from Device A.

## Pass/Fail Criteria

### Part 1: Online invite flow
- [ ] Device A creates a conversation and shows QR code
- [ ] Invite URL is extractable from Device A's QA event logs
- [ ] Deep link opens Device B and triggers the join flow
- [ ] Device A auto-processes the join request (no CLI needed)
- [ ] Device B enters the conversation with correct name and member count
- [ ] Two-way messaging works between Device A and Device B

### Part 2: Offline invite flow
- [ ] Device B shows "Verifying" state when inviter is offline
- [ ] Device B remains in "Verifying" while Device A is shut down
- [ ] After Device A comes back online, Device B transitions out of "Verifying"
- [ ] Device B is admitted to the conversation with correct name and member count
- [ ] Two-way messaging works after offline invite resolution
