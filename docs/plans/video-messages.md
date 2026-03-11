# Video Messages

## Problem

Convos currently supports sending and receiving photos but not video. Users expect to share short video clips in a messaging app. The attachment system is also tightly coupled to images — hardcoded MIME type checks, image-only compression, and `UIImage`-specific display code. Adding video support requires generalizing the attachment pipeline to handle multiple media types, with an architecture that extends naturally to future content types (audio notes, files, etc.).

## Goals

- Send and receive video messages up to 25MB
- Inline playback in the messages list (full-bleed, matching photo layout)
- Instant thumbnail preview before video downloads
- Progressive playback (play while downloading)
- Generalize the attachment model with a `mimeType` field for future content types
- Maintain backward compatibility with existing photo messages

## Non-Goals

- Audio notes, file attachments, or other content types (future work, but architecture should support them)
- Video editing (trimming, filters) before send
- Video recording from camera (use system picker only for v1)
- Animated GIF support (separate feature)
- Group video/photo albums in a single message (existing multi-attachment flow stays as-is)

## Design

### Size and Format Constraints

- Maximum file size: 25MB after compression
- Output format: H.264 in MP4 container (`video/mp4`)
- Compression target: 720p, medium quality via `AVAssetExportSession`
- Maximum duration: derived from size limit (roughly 30-60 seconds depending on content)
- Thumbnail: 200px max dimension, JPEG, typically 5-15KB

### Thumbnail Strategy

Embed a base64-encoded thumbnail JPEG in the XMTP `RemoteAttachment` parameters map. The parameters map is a `map<string,string>` on the protobuf `EncodedContent` — it's extensible and available to the receiver without downloading the remote payload.

Parameters added to `RemoteAttachment`:
- `thumbnail`: base64-encoded JPEG data (5-15KB encoded, ~7-20KB as base64)
- `thumbnailWidth`: pixel width as string
- `thumbnailHeight`: pixel height as string
- `mediaWidth`: full video width as string
- `mediaHeight`: full video height as string
- `mediaDuration`: duration in seconds as string (e.g., "14.5")
- `mediaMimeType`: the MIME type of the remote payload (e.g., "video/mp4")

This approach was chosen over alternatives because:
- Available instantly — no extra network request for the thumbnail
- Single upload — only the video goes to S3
- Well within XMTP message size limits
- Extensible — same pattern works for audio waveforms, file previews, etc.

If we later decide to use `MultiRemoteAttachment` (thumbnail + video as separate entries), there is no conflict — the two approaches use different XMTP content types entirely (`remoteStaticAttachment` vs `multiRemoteStaticAttachment`), and the receiver can handle both.

Note: these same parameters should also be added retroactively for photo messages (`mediaMimeType: "image/jpeg"`, `mediaWidth`, `mediaHeight`). This gives the receiver dimensions before downloading, enabling proper aspect-ratio placeholders. No thumbnail parameter is needed for photos since the photo itself is small enough to load quickly.

### XMTP Transport

No SDK changes required. The existing `RemoteAttachment` content type wraps an `Attachment(filename, mimeType, data)` — the inner `Attachment.mimeType` is set to `"video/mp4"` instead of `"image/jpeg"`. The encrypted payload is uploaded to S3 via the same presigned URL flow. The `contentLength` field on `RemoteAttachment` provides file size for download progress.

### Data Model Changes

#### `StoredRemoteAttachment` — add fields

```
mimeType: String?         // "video/mp4", "image/jpeg", etc.
thumbnailData: String?    // base64 JPEG thumbnail (from parameters)
mediaWidth: Int?          // full media dimensions
mediaHeight: Int?
mediaDuration: Double?    // seconds
```

These are populated from the `RemoteAttachment` parameters when the message is first received and stored, so they're available without re-parsing the XMTP message.

#### `HydratedAttachment` — add fields

```
mimeType: String?         // "video/mp4", "image/jpeg", etc.
duration: Double?         // seconds, for video/audio
thumbnailKey: String?     // cache key or inline base64 for thumbnail
fileSize: Int?            // bytes, for download progress UI
```

A computed `mediaType` property derives the category from `mimeType`:

```swift
enum MediaType { case image, video, audio, file, unknown }
var mediaType: MediaType {
    guard let mimeType else { return .unknown }
    if mimeType.hasPrefix("image/") { return .image }
    if mimeType.hasPrefix("video/") { return .video }
    if mimeType.hasPrefix("audio/") { return .audio }
    return .file
}
```

#### DB migration

Add a `mimeType TEXT` column to `AttachmentLocalState`. For existing rows, `mimeType` defaults to `NULL` which the app treats as `"image/jpeg"` (backward compatible).

#### Message preview text

`DBMessage+MessagePreview.swift` currently hardcodes "a photo" / "N photos". Change to derive from MIME type: "a video", "a photo", "a file", etc.

### Sending Flow

1. **Picker**: Change `PhotosPicker` filter from `.images` to `.any(of: [.images, .videos])`. After selection, inspect the `PhotosPickerItem.supportedContentTypes` to determine if it's image or video.

2. **Video compression**: New `VideoCompressionService` (or extend to `MediaCompressionService`):
   - Input: `URL` to the picked video file
   - Use `AVAssetExportSession` with `AVAssetExportPresetMediumQuality`
   - Output format: `.mp4`
   - Check compressed size against 25MB limit; reject if over
   - Extract thumbnail via `AVAssetImageGenerator` at time 0

3. **Upload**: Reuse existing `PhotoAttachmentService` flow, generalized:
   - Create `Attachment(filename: "video_<timestamp>.mp4", mimeType: "video/mp4", data: compressedData)`
   - Encrypt via `RemoteAttachment.encodeEncrypted(content:codec:)`
   - Upload encrypted payload to S3 via presigned URL
   - Construct `RemoteAttachment` with thumbnail and media metadata in parameters

4. **Eager upload**: Extend `OutgoingMessageWriter` with `startEagerUpload(videoURL:)` — begins compression + upload immediately when video is selected, before user taps Send. The existing eager upload infrastructure handles this.

5. **Local preview**: Save the thumbnail and a local file URL for the video so the sending user sees the content immediately (same pattern as photo local cache).

### Receiving Flow

1. **`DecodedMessage+DBRepresentation`**: Remove the `guard attachment.mimeType.hasPrefix("image/")` checks (3 places). Accept any MIME type. Store `mimeType` in `StoredRemoteAttachment` JSON. Extract thumbnail/dimensions from `RemoteAttachment` parameters.

2. **`RemoteAttachmentLoader`**: Rename to `AttachmentLoader` (or keep name, generalize internals). Remove the `guard attachment.mimeType.hasPrefix("image/")` check. For video, return the raw encrypted data URL for streaming rather than loading everything into memory.

3. **Hydration**: `StoredRemoteAttachment` → `HydratedAttachment` populates `mimeType`, `duration`, `thumbnailKey`, `fileSize` from the stored JSON.

### Display

#### Inline Video in Messages List

The messages list uses full-bleed media (edge-to-edge on iPhone, constrained width on iPad). Video follows the same layout as photos:

- **Before download**: Show thumbnail at correct aspect ratio (from `mediaWidth`/`mediaHeight`). Overlay a play button and duration badge. The blur/reveal system applies to the thumbnail the same way it does for photos.
- **On tap**: Begin streaming the video. The player replaces the thumbnail inline. Use `AVPlayer` with a custom `AVPlayerLayer` view. Loop playback. Tap again to pause. Show a subtle progress indicator if buffering.
- **Progressive playback**: `AVPlayer` supports streaming from an HTTPS URL natively. However, the video is encrypted — we need to decrypt on-the-fly. Options:
  - **Option 1**: Download + decrypt fully, then play from local file. Simpler but no progressive playback.
  - **Option 2**: Stream-decrypt via a local HTTP proxy or custom `AVAssetResourceLoaderDelegate`. Complex but enables true streaming.
  - For v1, Option 1 (download-then-play) is acceptable. Show download progress on the thumbnail. Once downloaded, playback is instant. Cache the decrypted file locally.

If progressive playback from encrypted sources proves too complex for v1, fall back to download-then-play with a progress indicator. The thumbnail ensures the user sees something immediately regardless.

#### Video Player Controls

- Tap to play/pause
- No scrubber for inline playback (keep it simple like iMessage)
- Duration badge on thumbnail (e.g., "0:14")
- Download progress ring overlaid on play button
- Mute/unmute toggle (videos start muted by default in the feed)
- Fullscreen option via long-press or dedicated button

#### Blur/Reveal for Video

Same as photos. The thumbnail is blurred when `shouldBlurPhotos` is true and not yet revealed. Tap to reveal shows the thumbnail; a second tap starts playback.

### Backward Compatibility

- Old clients that don't understand video will see the `RemoteAttachment` fallback text: "Can't display this content."
- Old messages (photos without `mimeType` in parameters) continue to work — `nil` mimeType is treated as `"image/jpeg"`.
- The `parameters` map is ignored by clients that don't know about the new keys — no breaking change.

### Error Handling

- Video too large after compression: show error "Video is too long. Try a shorter clip." with the size/duration limit.
- Upload failure: same retry flow as photos (pending upload writer, background upload manager).
- Download failure: show error state on the thumbnail with retry button.
- Unsupported codec in received video: show generic "Can't play this video" with the filename.

## Future Considerations

- **Audio notes**: Same `RemoteAttachment` + parameters pattern. `mediaMimeType: "audio/m4a"`, `mediaDuration`, optional `waveform` base64 parameter. Display as waveform + play button.
- **File attachments**: `mediaMimeType: "application/pdf"` etc. Display as file icon + name + size. Tap to download and open with system viewer.
- **Larger videos via MultiRemoteAttachment**: If 25MB proves too limiting, could split video into chunks or use `MultiRemoteAttachment` with a low-res version + full-res version for adaptive quality.
- **Camera capture**: Add "Record video" option alongside photo library picker.
- **Video trimming**: In-app trim UI before send to help users stay under size limit.
