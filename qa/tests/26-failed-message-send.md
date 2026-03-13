# Test: Failed Message Send

Verify that when a message fails to send, the app shows a "Not Delivered" error state with retry and delete options.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- At least one conversation exists where the app has successfully sent messages before.

## Setup

Use the CLI to create a conversation and generate an invite. Open the invite in the app via deep link so both the CLI and the app are participants in the same conversation.

After the app joins, process the join request from the CLI side so the app is admitted.

Wait for the app to load into the conversation view.

Send a test message from the app ("Connection test") and verify it shows "Sent" to confirm the conversation is working normally.

## Steps

### Simulate network failure

1. Enable the network conditioner to block all network traffic. Use the QA network conditioner approach: from the simulator, enable airplane mode or use `xcrun simctl` status bar overrides, and use `pfctl` or Network Link Conditioner to drop packets. Alternatively, simply disconnect the Mac's network (Wi-Fi off / Ethernet unplugged) since the simulator shares the host network.

### Send a message while offline

2. Tap the message input field in the app.
3. Type a message like "This should fail".
4. Tap the send button.
5. Wait up to 15 seconds for the message send attempt to time out or fail.
6. Verify the message appears in the conversation view with a red "Not Delivered" label below it (using `.colorCaution` color).
7. Verify a red exclamation mark icon (`exclamationmark.circle.fill`) appears to the right of the message bubble.

### Verify retry flow

8. Restore network connectivity (re-enable Wi-Fi / reconnect Ethernet).
9. Wait a few seconds for the network to stabilize.
10. Tap the exclamation mark icon next to the failed message.
11. Verify a context menu appears with "Try Again" and "Delete" options.
12. Tap "Try Again".
13. Wait for the message to be sent successfully.
14. Verify the "Not Delivered" label and exclamation icon disappear.
15. Verify the message now shows "Sent" status (if it's the last message by the current user).

### Verify delete flow

16. Disconnect the network again.
17. Send another message ("Delete me") from the app.
18. Wait for it to fail (red "Not Delivered" label appears).
19. Tap the exclamation mark icon.
20. Tap "Delete" from the context menu.
21. Verify the failed message is removed from the conversation view entirely.

### Restore network

22. Restore network connectivity.

## Teardown

Explode the conversation via CLI to clean up.

## Pass/Fail Criteria

- [ ] Failed message shows "Not Delivered" label in red below the message bubble
- [ ] Red exclamation mark icon appears to the right of the failed message bubble
- [ ] Tapping the exclamation icon shows a context menu with "Try Again" and "Delete"
- [ ] "Try Again" re-sends the message successfully after network is restored
- [ ] After successful retry, "Not Delivered" and icon disappear, "Sent" shows
- [ ] "Delete" removes the failed message from the conversation entirely
- [ ] Successfully sent messages still show "Sent" status normally

## Accessibility Improvements Needed

- The exclamation icon has `accessibilityIdentifier("failed-message-button")` and `accessibilityLabel("Message failed to send")`
- The "Not Delivered" text has `accessibilityLabel("Message not delivered")`
