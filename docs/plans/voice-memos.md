# Voice Memos

> **Status**: Draft
> **Branch**: `jarod/voice-memos`

## Overview

Add voice memo recording and playback as a new remote attachment type. Voice memos use the existing XMTP remote attachment infrastructure (same as photos/videos) with an `audio/m4a` MIME type. The recording experience is inline in the message input bar, following iMessage's UX pattern.

## UX Flow

### Recording

1. User taps the **waveform** icon (SF Symbol `waveform`) in the media buttons bar (after camera, before convos button)
2. The bottom bar morphs to a full-width recording state:
   - The expand/collapse button and media buttons container are hidden
   - A live waveform animation shows audio levels
   - The waveform marquees left as recording progresses
   - Duration counter shows elapsed time (e.g., `0:05`)
   - A red **stop** button (square in circle) on the right
3. Tapping stop transitions to the **review** state

### Review (after recording)

The bottom bar shows:
- **X** (cancel) button on the left — discards the recording
- **Play/pause** button — preview the recording
- Waveform visualization of the recorded audio
- Duration label (e.g., `+ 0:07`)
- **Send** button on the right (same as normal send)

### Message Cell (sent/received)

Inside our existing message container (MessageBubble):
- **Play/pause** button on the left
- Waveform visualization (static, shows playback progress)
- Duration / elapsed time label
- Context menu: "Save to Files" option

### Reply Reference

When a voice memo is the parent of a reply:
- Small static waveform icon + "Voice memo" text
- No play/pause button (just a visual indicator)

## Architecture

### Recording Service

**New file**: `ConvosCore/Sources/ConvosCore/Messaging/VoiceMemoRecorder.swift`

```swift
actor VoiceMemoRecorder {
    enum State { case idle, recording, recorded(URL, TimeInterval) }
    
    var state: State
    var audioLevels: [Float]  // normalized 0-1, for waveform visualization
    var duration: TimeInterval
    
    func startRecording() async throws
    func stopRecording() async throws -> (url: URL, duration: TimeInterval)
    func cancelRecording()
}
```

Uses `AVAudioRecorder` with `.m4a` format (AAC codec). Publishes audio levels periodically for the waveform animation.

### Sending

Voice memos are sent as remote attachments — same flow as video:

1. Record audio to a local `.m4a` file
2. Read the file data into an XMTP `Attachment(filename:, mimeType: "audio/m4a", data:)`
3. Encrypt with `RemoteAttachment.encodeEncrypted`
4. Upload encrypted data to S3 via presigned URL
5. Send the `RemoteAttachment` message via XMTP

**New method on `OutgoingMessageWriterProtocol`:**
```swift
func sendVoiceMemo(at fileURL: URL, duration: TimeInterval, replyToMessageId: String?) async throws -> String
```

### Receiving / Playback

**New file**: `ConvosCore/Sources/ConvosCore/Messaging/VoiceMemoPlayer.swift`

```swift
@Observable
class VoiceMemoPlayer {
    enum State { case idle, loading, playing, paused }
    
    var state: State
    var currentTime: TimeInterval
    var duration: TimeInterval
    var progress: Double  // 0-1
    
    func play(url: URL) async throws
    func pause()
    func stop()
}
```

Uses `AVAudioPlayer` for playback. The player is shared per conversation to ensure only one voice memo plays at a time.

### Content Type Detection

The existing `HydratedAttachment` model detects attachment types by MIME type. Add audio MIME type detection:

```swift
var isAudio: Bool {
    mimeType?.hasPrefix("audio/") == true
}
```

### DB / Models

No new DB tables needed. Voice memos are stored as regular messages with remote attachment content type, same as photos and videos. The MIME type (`audio/m4a`) distinguishes them.

The `MessageContent` enum may need a new case or the existing `.remoteAttachment` case handles it (with MIME-based rendering in the view layer).

## Files to Create

| File | Purpose |
|------|---------|
| `ConvosCore/.../Messaging/VoiceMemoRecorder.swift` | AVAudioRecorder wrapper |
| `ConvosCore/.../Messaging/VoiceMemoPlayer.swift` | AVAudioPlayer wrapper |
| `Convos/.../Views/VoiceMemoRecordingView.swift` | Recording state bottom bar |
| `Convos/.../Views/VoiceMemoReviewView.swift` | Review state bottom bar |
| `Convos/.../Messages List Items/VoiceMemoBubble.swift` | Message cell view |
| `Convos/.../Messages List Items/VoiceMemoWaveformView.swift` | Reusable waveform visualization |

## Files to Modify

| File | Change |
|------|--------|
| `MessagesMediaInputView.swift` | Add waveform button after camera |
| `MessagesBottomBar.swift` | Handle recording/review states, morph animation |
| `MessagesInputView.swift` | Integrate recording state |
| `ConversationViewModel.swift` | Recording state management, send voice memo |
| `OutgoingMessageWriter.swift` | `sendVoiceMemo` method |
| `MessagesGroupItemView.swift` | Render voice memo bubble |
| `MessagesGroupView.swift` | Layout for voice memo messages |
| `ReplyReferenceView.swift` | Voice memo reply preview |
| `HydratedAttachment.swift` | Audio type detection |
| `MessageContent.swift` | Voice memo content identification |

## Audio Format

- **Container**: M4A (MPEG-4 Audio)
- **Codec**: AAC
- **Sample rate**: 44100 Hz
- **Channels**: 1 (mono)
- **Bit rate**: 64 kbps (good quality for voice, small file size)
- **Max duration**: 5 minutes (configurable)

## Waveform Visualization

Two modes:
1. **Live recording**: Animated bars driven by `AVAudioRecorder.averagePower(forChannel:)`, sampled at ~60fps, marquees left as time progresses
2. **Static playback**: Pre-computed from the audio file's amplitude data, with a progress overlay showing playback position

The waveform is rendered as a series of vertical bars (`RoundedRectangle`) with varying heights based on audio levels.

## Permissions

Microphone access requires `NSMicrophoneUsageDescription` in Info.plist (already present for camera video recording).

## Edge Cases

| Scenario | Handling |
|----------|----------|
| App backgrounded during recording | Stop recording, transition to review state |
| Phone call during recording | Stop recording via AVAudioSession interruption notification |
| No microphone permission | Show system permission dialog on first tap, show error if denied |
| Recording too short (< 1s) | Discard silently, stay in idle state |
| Recording at max duration | Auto-stop, transition to review state |
| Network failure during send | Same retry mechanism as photo/video attachments |
| Received audio in unsupported format | Show "Unsupported audio" placeholder |
