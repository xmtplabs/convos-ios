# Test: Send and Receive Photos

Verify end-to-end photo messaging: sending a photo from the app, receiving a photo from the CLI, the blur/reveal privacy flow for incoming photos, photo context menu actions, and the first-time "Pics are personal" education sheet.

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

### Incoming photo blur/reveal

27. Incoming photos from other participants should be blurred by default with a "Tap pic to reveal" overlay.
28. Take a screenshot to verify the incoming photo is blurred (the image should be unrecognizable, with the overlay text visible).
29. If a "Reveal" education sheet appears (title: "Reveal"), tap "Got it" to dismiss. This sheet only appears once per install.
30. Tap the blurred photo to reveal it. The blur should animate away and the full photo should be visible.
31. Take a screenshot to verify the photo is now revealed (sharp, no blur overlay).

### Photo context menu

32. Long-press on the revealed incoming photo to open the context menu (duration ≥ 0.3s).
33. Verify the context menu appears with these options:
    - "Reply" — standard message action
    - "Save" — save photo to camera roll
    - "Blur" — re-blur the photo (since it's currently revealed)
34. Tap "Blur" in the context menu.
35. Verify the photo returns to the blurred state with the "Tap pic to reveal" overlay.
36. Long-press on the blurred photo to open the context menu again.
37. Verify the menu now shows "Reveal" instead of "Blur".
38. Tap "Reveal" to unblur the photo.
39. Verify the photo is revealed again.

### Own photo context menu

40. Long-press on one of the photos you sent from the app.
41. Verify the context menu appears with "Reply", "Save", and "Blur". Own photos are never auto-blurred, but the owner can manually blur them (which sets `isHiddenByOwner`). The menu should show "Blur" (not "Reveal") since own photos start unblurred.

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
- [ ] Incoming photo from CLI renders as a full-width image (not stuck loading or errored)
- [ ] Incoming photo is blurred by default with "Tap pic to reveal" overlay
- [ ] Tapping a blurred photo reveals it (blur animates away)
- [ ] Photo context menu shows Reply, Save, and Blur/Reveal for incoming photos
- [ ] "Blur" in context menu re-blurs the photo
- [ ] "Reveal" in context menu unblurs the photo
- [ ] Own sent photos show Reply, Save, and Blur (not auto-blurred, but owner can blur)
