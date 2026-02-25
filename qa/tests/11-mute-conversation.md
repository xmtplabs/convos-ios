# Test: Mute and Unmute Conversation

Verify that conversations can be muted and unmuted, and that the mute state is reflected in the UI.

## Prerequisites

- The app is running and past onboarding.
- There is at least one conversation in the conversations list.
- The convos CLI is initialized and is a participant in the conversation.

## Steps

### Mute via swipe action

1. From the conversations list, swipe left on a conversation to reveal swipe actions.
2. Look for a mute button (bell slash icon).
3. Tap the mute button.
4. Verify the conversation shows a muted indicator in the list.

### Verify mute in conversation info

5. Open the muted conversation.
6. Open conversation info.
7. Verify the notifications toggle is off, reflecting the muted state.

### Receive a message while muted

8. Use the CLI to send a message to the muted conversation.
9. Navigate back to the conversations list.
10. Verify the conversation updates with the new message but the muted indicator is still present.

### Unmute via swipe action

11. Swipe left on the muted conversation again.
12. Tap the unmute button (bell icon).
13. Verify the muted indicator is removed.

### Unmute via conversation info

14. Alternatively, open conversation info and toggle notifications back on.
15. Verify the muted state is cleared.

## Teardown

Ensure the conversation is unmuted to restore default state.

## Pass/Fail Criteria

- [ ] Conversation can be muted via swipe action
- [ ] Muted indicator appears in the conversations list
- [ ] Muted state is reflected in conversation info (notifications toggle off)
- [ ] Messages still arrive in a muted conversation
- [ ] Conversation can be unmuted via swipe action
- [ ] Conversation can be unmuted via conversation info toggle
