# Test: Read Receipts

Verify that read receipts are sent when viewing a conversation, received from other members, and displayed correctly as a scrolling avatar list replacing the "Sent" indicator.

## Prerequisites

- The app is built and installed.
- Two simulators are available (Device A and Device B), each running a separate Convos identity.
- The convos CLI is initialized for the dev environment.

## Setup

### Create a conversation with three members

1. Use the CLI to create a conversation named "Read Receipt Test" and generate an invite URL.
2. Open the invite URL on Device A via deep link. Wait for Device A to send the join request.
3. Process the join request from the CLI so Device A is admitted.
4. Generate a new invite URL from the CLI for the same conversation.
5. Open the new invite URL on Device B via deep link. Wait for Device B to send the join request.
6. Process the join request from the CLI so Device B is admitted.
7. Wait for both devices to show the conversation with all three members.

The conversation now has three participants: CLI member, Device A user, Device B user.

## Steps

### Verify "Sent" status shows by default

1. On Device A, send a text message like "Hello everyone".
2. Verify the message shows "Sent" with a checkmark icon below it (the existing behavior before anyone has read it).

### Verify read receipt is sent on conversation open

3. On Device B, open the conversation (it should already be open from setup, but navigate away and back if needed to trigger a fresh open).
4. Wait a few seconds for the read receipt to be sent and propagated.
5. On Device A, verify the "Sent" label on the last sent message changes to "Read".
6. Verify a profile avatar for Device B's member appears next to the "Read" label.

### Verify read receipt from CLI member

7. Use the CLI to send a text message to the conversation (e.g., "Message from CLI").
8. Wait for the message to appear on Device A.
9. The "Read" indicator on Device A's last sent message ("Hello everyone") should now show both Device B's avatar AND the CLI member's avatar (since the CLI sent a message after Device A's message, implying the CLI has seen it — though the CLI may not send read receipts, so this depends on whether the CLI supports read receipts).

Note: If the CLI does not send read receipts, only Device B's avatar will show. The key verification is that at least one avatar appears.

### Send a new message and verify fresh read status

10. On Device A, send another message like "Second message".
11. Verify it shows "Sent" with checkmark (no one has read it yet).
12. On Device B, the conversation is still open — a new incoming message should trigger Device B to send another read receipt.
13. Wait a few seconds for propagation.
14. On Device A, verify the "Second message" now shows "Read" with Device B's avatar.
15. Verify the previous message ("Hello everyone") no longer shows "Sent" or "Read" — only the last sent message shows read status.

### Verify scrolling avatar list

16. If more members have read the message, verify the avatar list scrolls horizontally and is capped at a max width with gradient fade on both sides (matching the reactions HStack pattern).

Note: With only two other members, the scroll/gradient may not be visible. The key check is that the avatar HStack is present and properly laid out.

### Verify opt-out stops sending and showing

17. On Device A, navigate to App Settings > Customize.
18. Find and disable the "Read receipts" toggle.
19. Navigate back to the conversation.
20. On Device B, send a new message to the conversation (e.g., "Can you see this?").
21. Wait for it to appear on Device A.
22. On Device B, verify that Device A's read status does NOT update — Device A should not have sent a read receipt.
23. On Device A, send a message (e.g., "Opt-out test").
24. On Device B, navigate away from and back into the conversation to trigger a read receipt.
25. On Device A, verify the last sent message shows "Sent" with checkmark, NOT "Read" — because Device A has opted out of seeing read receipts too.

### Re-enable read receipts

26. On Device A, navigate to App Settings > Customize.
27. Re-enable the "Read receipts" toggle.
28. Navigate back to the conversation.
29. On Device B, send another message to the conversation.
30. Wait for it to appear on Device A, which should trigger a read receipt send.
31. On Device A, verify the last sent message now shows "Read" with Device B's avatar again.

### Verify read receipts don't appear on non-last messages

32. On Device A, send three messages in quick succession: "One", "Two", "Three".
33. On Device B, navigate away and back to the conversation.
34. Wait for propagation.
35. On Device A, verify only "Three" (the last sent message) shows "Read" — "One" and "Two" should not show any read status.

### Verify "only visible to you" takes precedence

36. If the conversation has no other human members who have joined (edge case), the "only visible to you" state should still show when applicable, not "Read".

## Teardown

Explode the conversation via CLI to clean up. Shut down and delete Device B simulator.

## Pass/Fail Criteria

- [ ] Message shows "Sent" with checkmark when no one has read it
- [ ] "Sent" changes to "Read" when another member opens the conversation
- [ ] Profile avatar(s) of members who read the message appear next to "Read"
- [ ] Read status only shows on the last message sent by the current user
- [ ] New messages reset to "Sent" until read by others
- [ ] Disabling read receipts stops sending read receipts to others
- [ ] Disabling read receipts hides "Read" status (shows "Sent" instead)
- [ ] Re-enabling read receipts restores both sending and display
- [ ] Read receipt messages are not displayed as visible messages in the conversation
- [ ] No app-level errors in logs during the test

## Accessibility Improvements Needed

- The "Read" label should have an accessibility label like "Message read by N members"
- The scrolling avatar list should have an accessibility identifier like "read-receipt-avatars"
- The read receipts setting toggle should have an accessibility identifier like "read-receipts-toggle"
