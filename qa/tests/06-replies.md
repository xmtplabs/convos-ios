# Test: Reply to Messages

Verify that replies work correctly — both sending replies from the app and receiving replies from the CLI, with the reply reference displayed properly.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in a shared conversation.

## Setup

Ensure the conversation has messages to reply to:

1. Use the CLI to send a text message like "Original message from CLI".
2. From the app, send a text message like "Original message from app".
3. Wait for both messages to appear on both sides.

## Steps

### Reply from CLI, verify in app

4. Use the CLI to send a reply to "Original message from app", with reply text like "CLI replying to your message".
5. Wait a few seconds for the reply to appear in the app.
6. Verify the reply message appears in the app with a visual reference to the original message it's replying to. The reply should show some indication of the original message content.

### Reply from app, verify via CLI

7. In the app, swipe on the "Original message from CLI" message (or use the context menu) to trigger a reply.
8. A reply composer bar should appear at the bottom showing the message being replied to.
9. Type a reply like "App replying to your message" and send it.
10. Verify the reply appears in the app conversation with the reply reference visible.
11. Use the CLI to read messages with sync and verify the reply from the app includes the reference to the original message.

### Cancel a reply

12. Start a reply to any message in the app (swipe or context menu).
13. Verify the reply composer bar appears.
14. Tap the cancel reply button to dismiss it.
15. Verify the reply composer bar disappears and the input returns to normal mode.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] CLI reply appears in the app with a visible reference to the original message
- [ ] App can initiate a reply to a message (reply composer bar appears)
- [ ] App reply is sent with the correct reply reference
- [ ] App reply appears in the conversation with reply context visible
- [ ] App reply is visible via CLI with the original message reference
- [ ] Reply can be cancelled before sending
