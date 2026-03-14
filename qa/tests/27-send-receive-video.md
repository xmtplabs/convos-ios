# Test: Send and Receive Video Messages

Verify end-to-end video messaging: selecting a video from the photo picker, sending with compression, receiving from CLI, thumbnail display with play button and duration badge, inline playback, blur/reveal for incoming video, context menu actions, size limit enforcement, and that existing photo messaging continues to work alongside video.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The simulator photo library has at least one video and one photo.

## Setup

1. Reset the CLI and re-initialize for dev.
2. Download a short test video and add it to the simulator photo library.
3. Create a conversation via CLI named "Video Test" with profile name "CLI User".
4. Generate an invite and open it as a deep link in the app.
5. Process the join request from the CLI (per invite ordering rules in RULES.md).

## Steps

### Picker shows photos and videos

6. Tap the media picker button (`photo-picker-button`). The system PhotosPicker should appear showing both photos and videos. Videos are distinguishable by a duration badge in the picker grid.

### Send a video from the app

7. Select a video from the picker. If "Pics are personal" education sheet appears, dismiss it.
8. Verify a thumbnail preview appears in the composer (`attachment-preview-image`).
9. Tap the send button. Verify the video message appears with a thumbnail, play button overlay, and duration badge. Check for `message.sent` event.

### Remove video before sending

10. Select another video from the picker.
11. Tap the remove button (`remove-attachment-button`).
12. Verify the preview disappears and the composer returns to text input.

### Inline playback

13. Tap the play button on the sent video. Verify inline playback starts (play button disappears).
14. Tap the playing video to pause. Verify the play button reappears.

### Receive a video from CLI

15. Send a video from the CLI using `send-attachment` with `--mime-type video/mp4`.
16. Verify the incoming video appears with a blurred thumbnail and "Tap to reveal" overlay. Check for `message.received` event.

### Incoming video blur/reveal

17. Verify the incoming video thumbnail is blurred (screenshot check).
18. Tap to reveal. Dismiss "Reveal" education sheet if it appears.
19. Verify the thumbnail is now clear with a play button and duration badge.
20. Tap the play button to start playback on the revealed video.

### Video context menu

21. Long-press on the revealed incoming video. Verify Reply, Save, and Blur in context menu.
22. Tap Blur. Verify the video returns to blurred state.
23. Long-press the blurred video. Verify menu shows Reveal instead of Blur.

### Own video context menu

24. Long-press on the video sent from the app. Verify Reply, Save, and Blur (own videos start unblurred).

### Photo still works

25. Select and send a photo. Verify it renders as a full-width image (unchanged behavior).

### Conversation list preview

26. Navigate back to conversations list. Verify the preview text shows "a photo" or "a video" as appropriate for the most recent message.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] Photo picker shows both photos and videos
- [ ] Video can be selected and sent with thumbnail preview in composer
- [ ] Sent video displays thumbnail with play button and duration badge
- [ ] `message.sent` event fires for video
- [ ] Video attachment can be removed before sending
- [ ] Tapping play button starts inline playback
- [ ] Tapping playing video pauses it
- [ ] Video from CLI appears in the app
- [ ] `message.received` event fires for incoming video
- [ ] Incoming video is blurred by default
- [ ] Tapping blurred video reveals the thumbnail
- [ ] Tapping revealed video starts inline playback
- [ ] Context menu shows Reply, Save, Blur/Reveal for incoming video
- [ ] Blur/Reveal toggles work from context menu
- [ ] Own sent video context menu shows Reply, Save, Blur
- [ ] Photo sending still works alongside video
- [ ] Conversation list preview shows "a video" or "a photo" appropriately

## Accessibility Improvements Needed

- Video play button overlay needs `accessibilityIdentifier("video-play-button")`
- Video duration badge needs `accessibilityIdentifier("video-duration-badge")`
- Video messages should have a label distinguishing them from photos (e.g., "Video message" vs photo labels)
- Inline video player play/pause state should be accessible
