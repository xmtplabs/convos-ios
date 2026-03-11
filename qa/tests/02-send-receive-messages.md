# Test: Send and Receive Messages

Verify that the app can send and receive all message content types: text, emoji, attachments, and link previews.

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

### Send a link preview from the app

17. Tap the message input field in the app.
18. Type a standalone URL like "https://www.apple.com" (the entire message should be just the URL, with no other text).
19. Tap the send button.
20. Verify the message appears as a link preview card — not as a plain text bubble. The card should have:
    - An image area at the top (may show a fallback link icon while the OpenGraph image loads, then update to the page's og:image if available).
    - A title below the image (the page's og:title, e.g. "Apple"). If the page title hasn't loaded yet, the domain name (e.g. "www.apple.com") may appear temporarily.
    - A subtitle showing the domain name (e.g. "www.apple.com" or "Apple").
21. Wait a few seconds for the OpenGraph metadata to load. Take a screenshot and verify the card has updated with the page's title and/or image.

### Receive a link preview from CLI

22. Use the CLI to send a standalone URL as a text message, like "https://www.wikipedia.org".
23. Wait for the message to appear in the app.
24. Verify the incoming message renders as a link preview card (same visual style as the outgoing link preview — image area, title, domain), not as a plain text bubble.

### Tap a link preview to open in Safari

25. Tap on the link preview card from the previous step.
26. Verify the URL opens in Safari (the app will switch to Safari or an in-app browser showing the linked page).
27. Navigate back to the app.

### Verify link message is visible via CLI

28. Use the CLI to read recent messages from the conversation with sync enabled.
29. Verify the URL sent from the app (e.g. "https://www.apple.com") appears in the CLI output as a plain text message. The CLI does not render link previews — it should show the raw URL.

### Non-standalone URL remains a text bubble

30. From the app, type a message that contains a URL with surrounding text, like "Check out https://example.com for details".
31. Tap the send button.
32. Verify the message renders as a regular text bubble (not a link preview card). The URL within the text should still be tappable as a link, but the message should not be displayed as a card.

## Teardown

Explode the conversation via CLI to clean up.

## Pass/Fail Criteria

- [ ] Text message sent from CLI appears in the app
- [ ] Emoji message sent from CLI appears in the app
- [ ] Text message sent from the app appears in the conversation view
- [ ] Text message sent from the app is visible via CLI
- [ ] Attachment sent from CLI appears in the app
- [ ] Standalone URL sent from app renders as a link preview card (not plain text)
- [ ] Link preview card shows title and domain after OpenGraph metadata loads
- [ ] Standalone URL sent from CLI renders as a link preview card in the app
- [ ] Tapping a link preview card opens the URL in Safari
- [ ] Link message sent from app is visible as plain text via CLI
- [ ] Message with URL mixed with other text renders as a normal text bubble (not a link preview)
