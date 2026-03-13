# Test: Typing Indicators

Verify that typing indicators appear when another participant is typing and disappear when they stop or send a message.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

Use the CLI to create a conversation and generate an invite. Open the invite in the app via deep link so both the CLI and the app are participants in the same conversation.

After the app joins, process the join request from the CLI side so the app is admitted.

Wait for the app to load into the conversation view.

## Steps

### Receive a typing indicator

1. Use the CLI to send a typing indicator to the conversation: `convos conversation send-typing-indicator <conversation-id>`.
2. Wait a few seconds for the typing indicator to arrive.
3. Verify that a typing indicator bubble appears in the conversation view — it should show animated pulsing dots inside a message bubble, with the sender's avatar.

### Typing indicator disappears on stop

4. Use the CLI to send a stop-typing indicator: `convos conversation send-typing-indicator <conversation-id> --stop`.
5. Wait a few seconds.
6. Verify the typing indicator bubble is no longer visible in the conversation view.

### Typing indicator disappears when message arrives

7. Use the CLI to send a typing indicator again: `convos conversation send-typing-indicator <conversation-id>`.
8. Wait a few seconds and verify the typing indicator appears.
9. Use the CLI to send a text message: `convos conversation send-text <conversation-id> "Hello from CLI"`.
10. Verify the typing indicator disappears and the text message appears in its place. The typing indicator should not be visible alongside the new message — it should be cleared before or at the same time the message renders.

### Typing indicator groups with sender's messages

11. Use the CLI to send another text message: `convos conversation send-text <conversation-id> "Setting up context"`.
12. Wait for the message to appear in the app.
13. Use the CLI to send a typing indicator: `convos conversation send-typing-indicator <conversation-id>`.
14. Wait for the typing indicator to appear.
15. Verify the typing indicator bubble appears below the CLI's last message in the same message group — it should share the same avatar and not have a separate sender label.

### Send typing indicator from the app

16. Tap the message input field in the app.
17. Type a few characters (e.g., "test").
18. Use the CLI to stream or read recent messages with sync to check if a typing indicator was received. Note: typing indicators are ephemeral and may not appear in the message list — this step verifies the sending path works.
19. Clear the text field or send the message.

### Typing indicator expires after timeout

20. Use the CLI to send a typing indicator: `convos conversation send-typing-indicator <conversation-id>`.
21. Verify the typing indicator appears.
22. Wait approximately 15 seconds without sending any more typing indicators or messages.
23. Verify the typing indicator has automatically disappeared due to the 15-second expiry.

## Teardown

Explode the conversation via CLI to clean up.

## Pass/Fail Criteria

- [ ] Typing indicator bubble with pulsing dots appears when CLI sends isTyping=true
- [ ] Typing indicator disappears when CLI sends isTyping=false
- [ ] Typing indicator disappears when a message arrives from the typer (no flicker — indicator is not visible alongside the new message)
- [ ] Typing indicator appears in the same message group as the sender's last message (shared avatar, no separate sender label)
- [ ] Typing indicator automatically expires after ~15 seconds of no activity
