# Test: Send and Receive Messages

Verify that the app can send text messages and receive messages from another participant.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

Use the CLI to create a conversation and generate an invite. Open the invite in the app via deep link so both the CLI and the app are participants in the same conversation.

After the app joins, process the join request from the CLI side so the app is admitted.

Wait for the app to load into the conversation view.

## Steps

### Receive a text message

1. Use the CLI to send a text message to the conversation, like "Hello from the CLI".
2. Wait a few seconds for the message to sync.
3. Verify the message appears in the app's conversation view.

### Receive an emoji message

4. Use the CLI to send a single emoji message, like "🎉".
5. Wait for it to appear in the app.
6. Verify the emoji message is displayed (emoji-only messages may render larger than regular text).

### Send a text message from the app

7. Tap the message input field in the app.
8. Type a message like "Hello from the app".
9. Tap the send button.
10. Verify the message appears in the conversation as a sent message.

### Verify the app's message via CLI

11. Use the CLI to read recent messages from the conversation with sync enabled.
12. Verify the message "Hello from the app" appears in the CLI output.

### Send an attachment from the CLI

13. Create a small test image file (or use any small file).
14. Use the CLI to send the attachment to the conversation.
15. Wait for it to appear in the app.
16. Verify an attachment/image message appears in the conversation view.

## Teardown

Explode the conversation via CLI to clean up.

## Pass/Fail Criteria

- [ ] Text message sent from CLI appears in the app
- [ ] Emoji message sent from CLI appears in the app
- [ ] Text message sent from the app appears in the conversation view
- [ ] Text message sent from the app is visible via CLI
- [ ] Attachment sent from CLI appears in the app
