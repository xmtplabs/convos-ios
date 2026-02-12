# Test: Reactions on All Message Content Types

Verify that reactions can be added to text messages, emoji messages, and attachment messages, both from the app and from the CLI.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in a shared conversation. Set this up using the invite flow from either test 03 or 04.

## Setup

Ensure the conversation has at least one message of each content type:

1. Use the CLI to send a text message, like "React to this text".
2. Use the CLI to send an emoji-only message, like "🚀".
3. Use the CLI to send an attachment (a small image file).
4. From the app, send a text message, like "React to this too".

Wait for all messages to appear in both the app and the CLI.

## Steps

### React from CLI, verify in app

5. Use the CLI to add a reaction emoji (like "👍") to the text message it sent.
6. Wait a few seconds, then verify the reaction appears on the message in the app.
7. Use the CLI to add a reaction emoji (like "❤️") to the emoji message.
8. Verify the reaction appears on the emoji message in the app.
9. Use the CLI to add a reaction emoji (like "🔥") to the attachment message.
10. Verify the reaction appears on the attachment message in the app.

### React from app, verify via CLI

11. In the app, long-press on the text message sent from the app to open the context menu or reaction picker.
12. Select a reaction emoji (like "😂").
13. Verify the reaction appears on the message in the app UI.
14. Use the CLI to read messages with sync, and verify the reaction from the app is present.

### React from app to a CLI message

15. In the app, long-press on the text message sent from the CLI.
16. Add a reaction emoji.
17. Verify the reaction appears in the app.
18. Verify the reaction appears via the CLI.

### Remove a reaction

19. In the app, tap the reaction you just added to toggle it off (remove it).
20. Verify the reaction is removed from the app UI.
21. Use the CLI to verify the reaction was removed (or use CLI to remove a reaction and verify it disappears from the app).

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] CLI reaction on a text message appears in the app
- [ ] CLI reaction on an emoji message appears in the app
- [ ] CLI reaction on an attachment message appears in the app
- [ ] App reaction on a text message is visible in the app
- [ ] App reaction on a text message is visible via CLI
- [ ] App reaction on a CLI-sent message is visible in both app and CLI
- [ ] Removing a reaction updates the app UI
- [ ] Removing a reaction is reflected across both app and CLI
