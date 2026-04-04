# Test: Voice Memos

Verify that voice memos can be recorded, previewed, and sent as messages.

## Prerequisites

- The app is running and past onboarding on the primary simulator.
- At least one conversation exists.
- Microphone permission has been granted (or will be granted on first use).

## Steps

### Verify waveform button exists

1. Open a conversation from the conversations list.
2. If the media buttons are collapsed, tap the expand button to show them.
3. Verify that a waveform button (SF Symbol "waveform") appears in the media buttons bar, after the camera icon and before the convos button.

### Start recording

4. Tap the waveform button to start recording.
5. If a microphone permission dialog appears, grant permission.
6. The bottom bar should morph to show the recording state:
   - A live waveform animation showing audio levels
   - A duration counter (e.g., "0:02") incrementing in real time
   - A red stop button on the right

### Stop recording

7. Wait at least 2 seconds for a valid recording.
8. Tap the red stop button.
9. The bottom bar should transition to the review state:
   - An X (cancel) button on the left
   - A play/pause button
   - A static waveform visualization
   - The duration label showing the recorded length
   - A send button (arrow up) on the right

### Preview playback

10. Tap the play button in the review state.
11. The button should change to a pause icon and audio should play (if on a real device — simulator may not produce audible output but the state should change).
12. Tap pause to stop playback.

### Cancel recording

13. Tap the X (cancel) button.
14. The bottom bar should return to the normal input state with the text field and media buttons.
15. No voice memo should be sent.

### Record and send

16. Tap the waveform button again to start a new recording.
17. Record for at least 2 seconds, then tap stop.
18. Tap the send button (arrow up) in the review state.
19. The bottom bar should return to the normal input state.
20. A voice memo message should appear in the messages list (it may appear as an attachment/remote attachment).

### Short recording discard

21. Tap the waveform button to start recording.
22. Immediately tap the stop button (within 1 second).
23. The recording should be discarded and the bar should return to idle state (no review state shown for recordings under 1 second).

## Teardown

No specific teardown needed.

## Pass/Fail Criteria

- [ ] Waveform button appears in media buttons bar after camera icon
- [ ] Tapping waveform button starts recording (duration counter increments)
- [ ] Stop button transitions to review state with play/cancel/send controls
- [ ] Cancel button returns to normal input state without sending
- [ ] Send button sends the voice memo as a message
- [ ] Recordings under 1 second are discarded automatically
- [ ] Recording state shows live waveform animation

## Accessibility Improvements Needed

- The waveform button should have `accessibilityIdentifier("voice-memo-button")` — verify it's findable
- The stop button should have `accessibilityIdentifier("voice-memo-stop-button")`
- The cancel button should have `accessibilityIdentifier("voice-memo-cancel-button")`
- The send button should have `accessibilityIdentifier("voice-memo-send-button")`
- The play button should have `accessibilityIdentifier("voice-memo-play-button")`
