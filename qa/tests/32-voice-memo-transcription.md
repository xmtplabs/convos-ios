# Test: Voice Memo Transcription

Verify that received voice memos are transcribed locally on-device, that the transcript row appears under the voice memo bubble, that it can be expanded and collapsed, that the expand/collapse state survives an app relaunch, and that failed transcriptions show a retry affordance.

## Prerequisites

- The app is running and past onboarding on the primary simulator.
- The convos CLI is initialized for the dev environment.
- The simulator is iOS 26+ (Speech `SpeechAnalyzer` / `SpeechTranscriber` APIs require iOS 26).
- An English on-device speech model is installed on the simulator. The first time the app calls `AssetInventory.assetInstallationRequest(...)`, the system downloads the model. If the test machine has never used on-device speech before, allow extra time on the first run.
- Outgoing voice memos are intentionally NOT transcribed; the test only exercises the receiving side.

## Setup

Use the CLI to create a conversation, generate an invite, and open the invite in the app via deep link so both the CLI and the app are participants in the same conversation. After the app joins, process the join request from the CLI side so the app is admitted (per invite ordering rules in RULES.md). Wait for the app to load into the conversation view.

Generate a short test audio clip on disk that contains a known phrase, for example using macOS `say`:

```sh
say -v Samantha "Picking up coffee on the way home" -o /tmp/convos-qa-voice-memo.m4a --data-format=alac
```

(Any short, clearly spoken English clip in `audio/m4a` will do. The transcript text does not need to match exactly — only the *presence* of a non-empty transcript matters for pass/fail.)

## Steps

### Receive a voice memo and wait for the transcript

1. Use the CLI to send the audio file from `/tmp/convos-qa-voice-memo.m4a` to the conversation as an attachment with mime-type `audio/m4a`. Force `--remote` upload so the app exercises the remote attachment loader path.
2. Wait for the voice memo bubble to appear in the conversation view (a message with a play button, waveform, and duration label).
3. After the voice memo is visible, watch for the transcript row to appear directly beneath the voice memo bubble.
   - The transcript row may first show a "Transcribing…" header (with a `waveform` icon) while the on-device job is running. On a warm machine the row often jumps straight to the completed state.
   - The first run on a fresh machine may take noticeably longer because iOS has to download the speech model. Allow at least 60 seconds the first time, ~5–15 seconds on subsequent runs.
4. Verify the transcript row updates to a "Transcript" header (with a `text.bubble` icon) and shows non-empty text. The text is shown collapsed by default to a 2-line preview, with a chevron-down indicator on the trailing edge of the header row.

### Expand and collapse the transcript

5. Tap the transcript row.
6. The row should expand: the chevron flips to chevron-up and the text expands to its full height. The text should not be truncated.
7. Tap the transcript row again.
8. The row should collapse back to the 2-line preview with chevron-down.

### Persistence across relaunch

9. Tap the transcript row once more so it is in the **expanded** state.
10. Terminate the Convos app from the simulator (`xcrun simctl terminate <udid> org.convos.ios-preview` or equivalent).
11. Relaunch Convos and reopen the same conversation.
12. Verify the transcript row for the same voice memo is still **expanded** (chevron-up, full text visible). This confirms the local expansion store persisted the state.
13. Tap the transcript row to collapse it again, then terminate and relaunch one more time. Verify it stays collapsed after relaunch.

### No transcript row for non-audio attachments

14. Use the CLI to send a small image attachment to the same conversation (e.g. a 100x100 PNG). Force `--remote` upload.
15. Wait for the photo bubble to appear in the conversation.
16. Verify that **no** transcript row appears beneath the photo bubble. Transcript rows should only appear under voice memo (audio) attachments.

### Outgoing voice memos are not transcribed

17. From the app, record a short voice memo (per `30-voice-memos.md`) and send it.
18. Verify the outgoing voice memo bubble appears in the conversation as a sent message.
19. Verify that **no** transcript row appears beneath the outgoing voice memo. Transcripts only run for received voice memos.

### Failure path and retry affordance (optional, environment dependent)

This section is best-effort. The exact way to force a transcription failure depends on the simulator state.

20. If you can reach a state where transcription fails (for example, by denying speech recognition authorization in Settings, or by sending an audio file that the speech model rejects), the transcript row should switch to the "Transcript unavailable" header with the `exclamationmark.bubble` icon, an optional one-line error description from the transcriber, and a small "Try again" capsule button.
21. Tap "Try again". The row should re-enter the "Transcribing…" state and either complete successfully or fail again. The retry affordance must work without leaving the conversation.
22. If you cannot easily induce a failure on the test machine, mark this section as "skipped" in the report rather than "failed".

## Teardown

Explode the conversation via CLI to clean up. Remove `/tmp/convos-qa-voice-memo.m4a`.

## Pass/Fail Criteria

- [ ] A received voice memo eventually shows a transcript row beneath its bubble
- [ ] The transcript row defaults to a 2-line collapsed preview with a chevron-down indicator
- [ ] Tapping the transcript row expands it to show the full text and flips the chevron up
- [ ] Tapping again collapses it back to the preview
- [ ] Expand/collapse state for a voice memo survives terminating and relaunching the app
- [ ] No transcript row appears beneath non-audio attachments (photos, videos, files)
- [ ] No transcript row appears beneath outgoing (current-user) voice memos
- [ ] (Optional) Failed transcripts show a "Transcript unavailable" header and a "Try again" button that re-runs the job
- [ ] No XMTP errors are logged during the test (per log monitoring rules in RULES.md). Note any speech-asset download warnings as informational only.

## Accessibility Improvements Needed

- The transcript row currently uses a `Button` with text content but does not have an explicit `accessibilityIdentifier`. Adding `accessibilityIdentifier("voice-memo-transcript-<messageId>")` and `accessibilityLabel` derived from the header + status would make this test fully scriptable via `sim_tap_id`.
- The retry button (`Try again`) likewise has no identifier. Suggested: `accessibilityIdentifier("voice-memo-transcript-retry-<messageId>")`.
- The chevron / expanded-state indicator is purely visual; consider exposing the expanded state via `accessibilityValue` ("expanded" / "collapsed") so VoiceOver users can tell the state.
