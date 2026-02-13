# Test: Reactions on All Message Content Types

Verify that reactions can be added to text messages, emoji messages, and attachment messages, both from the app and from the CLI. Also verify the reactions drawer, sender attribution, multiple reactions, and own-message reactions.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in a shared conversation. Set this up using the invite flow from either test 03 or 04.

## Setup

Ensure the conversation has at least one message of each content type:

1. Use the CLI to send a text message, like "React to this text".
2. Use the CLI to send an emoji-only message, like "🚀".
3. Download a test photo (`curl -sL "https://picsum.photos/850/650" -o /tmp/test-photo.jpg`) and send it as an attachment from the CLI.
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

### React to own message from app

11. In the app, double-tap on the text message sent from the app ("React to this too") to add a heart reaction.
12. Verify a heart reaction appears on the message.

### React from app to a CLI message

13. In the app, double-tap on the text message sent from the CLI ("React to this text") to add a heart reaction.
14. Verify the reaction appears in the app.
15. Use the CLI to read messages with sync, and verify the reaction from the app is present.

### Multiple reactions on one message

16. From the CLI, add a different reaction (like "😂") to the same text message that already has the app's heart reaction.
17. Add another reaction from the CLI (like "🔥") to the same message.
18. Verify the app displays all reactions on the message — there should be at least 3 different reaction types visible.

### View reactions drawer

19. In the app, tap on the reaction count area below a message that has multiple reactions. This should open a reactions drawer/popover.
20. Verify the reactions drawer opens and shows all reactions.
21. Verify sender attribution — each reaction should show who sent it (the display name of the sender).
22. Dismiss the reactions drawer.

### Remove a reaction

23. In the app, tap the heart reaction you added earlier to toggle it off (remove it).
24. Verify the reaction is removed from the app UI.
25. Use the CLI to verify the reaction was removed.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] CLI reaction on a text message appears in the app
- [ ] CLI reaction on an emoji message appears in the app
- [ ] CLI reaction on an attachment message appears in the app
- [ ] Double-tap on own message adds a heart reaction
- [ ] Double-tap on CLI message adds a heart reaction
- [ ] App reaction is visible via CLI
- [ ] Multiple reactions display correctly on a single message (3+ types)
- [ ] Reactions drawer opens when tapping the reaction count
- [ ] Reactions drawer shows sender names (attribution)
- [ ] Removing a reaction updates the app UI
- [ ] Removing a reaction is reflected via CLI
