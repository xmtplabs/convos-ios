# Test: Send and Receive Photos

Verify end-to-end photo messaging: sending a photo from the app, receiving a photo from the CLI, photo context menu actions, and the first-time "Pics are personal" education sheet.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- At least one conversation exists where both app and CLI are members.
- The simulator photo library has at least one image. If not, add one:
  ```
  curl -sL "https://picsum.photos/850/650" -o /tmp/test-photo.jpg
  xcrun simctl addmedia <UDID> /tmp/test-photo.jpg
  ```

## Setup

1. Create a conversation via CLI named "Photo Test" with a profile name for the CLI user.
2. Generate an invite and open it as a deep link in the app.
3. Process the join request from the CLI (per invite ordering rules in RULES.md).
4. Verify the app enters the conversation.

## Steps

### Send a photo from the app

5. Tap the photo library button (accessibility identifier: `photo-picker-button`). The system PhotosPicker should appear.
6. If this is the first time sending a photo, a "Pics are personal" education sheet will appear after selecting a photo. It has a "Got it" button — tap it to dismiss. This sheet only appears once per install.
7. Select any photo from the picker by tapping a thumbnail.
8. Verify the attachment preview appears in the composer area (accessibility identifier: `attachment-preview-image`).
9. Verify the remove button is visible on the preview (accessibility identifier: `remove-attachment-button`).
10. Tap the send button (accessibility identifier: `send-message-button`).
11. Verify the photo message appears in the conversation as a full-width image. Take a screenshot to confirm it rendered (not a placeholder or error state).
12. Verify a "Sent" indicator appears near the message (accessibility label contains "sent").

### Remove attachment before sending

13. Tap the photo library button again and select a photo.
14. Verify the attachment preview appears in the composer.
15. Tap the remove attachment button (`remove-attachment-button`).
16. Verify the attachment preview disappears — the composer should return to the text-only input state.
17. Verify `attachment-preview-image` is no longer present on screen.

### Send a photo with text

18. Tap the photo library button and select a photo.
19. Verify the attachment preview appears.
20. Type a text message in the message input field (e.g., "Check out this photo").
21. Tap the send button.
22. Verify both the photo and the text message are sent. The conversation should show the photo rendered as an image.

### Receive a photo from the CLI

23. Download a test photo on the host machine:
    ```
    curl -sL "https://picsum.photos/850/650" -o /tmp/cli-photo.jpg
    ```
24. Use the CLI to send the photo to the conversation using `send-attachment`.
25. Wait for the photo to appear in the app (use `sim_find_elements` to check for new content, or take a screenshot after a few seconds).
26. Verify the incoming photo renders as a full-width image in the conversation. Take a screenshot to confirm it loaded (not stuck on a loading placeholder or error state).

### Photo context menu

27. Long-press on the incoming photo to open the context menu (duration ≥ 0.3s).
28. Verify the context menu appears with these options:
    - "Reply" — standard message action
    - "Save" — save photo to camera roll
    - "Share" — share the photo
29. Verify the menu has no "Blur" or "Reveal" action.
30. Dismiss the context menu.

### Own photo context menu

31. Long-press on one of the photos you sent from the app.
32. Verify the context menu appears with "Reply", "Save", and "Share", and no "Blur" or "Reveal" action.

## Teardown

Explode the conversation via CLI to clean up.

## Pass/Fail Criteria

- [ ] Photo picker button opens the system PhotosPicker
- [ ] "Pics are personal" education sheet appears on first photo selection and can be dismissed
- [ ] Selected photo appears as a preview in the composer
- [ ] Remove button clears the attachment preview
- [ ] Photo sends successfully and renders as a full-width image
- [ ] Sent indicator appears after sending a photo
- [ ] Photo with text sends both content types
- [ ] Incoming photo from CLI renders immediately as a full-width image, unblurred (not stuck loading or errored)
- [ ] Photo context menu shows Reply, Save, and Share for incoming photos
- [ ] Photo context menu has no Blur or Reveal action
- [ ] Own sent photos show Reply, Save, and Share with no Blur or Reveal action
