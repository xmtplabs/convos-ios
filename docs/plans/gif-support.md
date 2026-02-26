# Plan: GIF Support

## Goal

Send and receive GIFs as animated content (not flattened to JPEG).

This plan assumes clipboard image paste for static images has already shipped (see `docs/plans/clipboard-image-paste.md`), including the `ComposerTextView` UITextView wrapper.

## Current State Assessment

### What works today

- Composer supports selecting a single image from Photos (`MessagesBottomBar` + `.photosPicker(..., matching: .images)`)
- Selected media is stored as `selectedAttachmentImage: UIImage?` in the conversation view model
- Outgoing photo pipeline (`OutgoingMessageWriter` + `PhotoAttachmentService`) supports one attachment and background upload
- Static photo compression targets ~1MB (`targetBytes: 1_000_000`) with a hard failure if resized JPEG is still above 10MB (`maxBytes: 10_000_000`)
- Incoming attachment decoding accepts any `image/*` MIME type in `DecodedMessage+DBRepresentation`
- Eager upload API (`startEagerUpload`) accepts `ImageType` (UIImage) and returns a tracking key
- `PhotoAttachmentService` hardcodes `mimeType: "image/jpeg"` in the XMTP `Attachment` constructor
- `ComposerTextView` (from clipboard paste work) already intercepts paste events

### What is missing

- Photo picker filter is `.images` only — excludes animated images
- Composer attachment model is `UIImage` only, which loses original binary format
- Send pipeline always generates `.jpg` filenames and `"image/jpeg"` MIME type
- `ImageCompression.compressForPhotoAttachment` always outputs JPEG
- Attachment rendering uses `Image(uiImage:)` which does not animate GIF frames in SwiftUI
- MIME type is not persisted in the data model:
  - `StoredRemoteAttachment` has `filename` (nullable) but no `mimeType` field
  - `HydratedAttachment` has no MIME type info
  - `DBMessage.attachmentUrls` is `[String]` — just keys, no metadata
  - Incoming XMTP `Attachment.mimeType` is available at decode time but discarded

### Conclusion

- GIF sending: not implemented (pipeline normalizes everything to JPEG)
- GIF receiving: payload accepted as `image/*`, but rendered as static frame
- GIF type detection: no MIME type persisted, would require data model changes

## Scope

- Represent composer attachment as typed media (static image vs animated GIF data)
- Preserve GIF bytes through the send pipeline (no JPEG conversion)
- Render GIFs as animated content in message cells and composer preview
- Persist MIME type so rendering layer can distinguish static vs animated
- Support GIFs from both clipboard paste and photo picker

### Out of scope

- Multi-attachment composer
- Video/webp/other animated formats
- GIF search/keyboard integrations
- In-app camera
- GIF transcoding/downsampling (iteration 1 rejects oversized GIFs)

## Size Limits and Compression

### Static images

No changes — existing JPEG compression pipeline.

### GIFs

GIFs bypass the JPEG compression pipeline entirely. Original bytes are preserved.

Proposed limits (to be tuned with QA perf runs on lower-memory devices):
- Raw GIF data max: **15MB** (reject above this at paste/pick time)
- Total decoded pixels cap: **40M pixels** (`width × height × frameCount`) to prevent memory spikes during rendering
- Frame count cap: **300 frames**

### Where to enforce

1. **Paste/pick preflight (UI layer):** check raw data size, then decode GIF header for frame count and dimensions. Reject before attaching to composer.
2. **Send pipeline (core layer):** re-validate before encryption/upload as a safety net.

### Over-limit UX

- Show immediate error (toast/banner) on paste/pick failure
- Do not start eager upload for invalid media
- Keep text draft intact
- Provide clear reason: "GIF is too large" / "GIF has too many frames"
- Iteration 1: reject only (no transcoding/downsampling)

## Phase 0: Product + UX alignment

- Confirm GIF visual treatment:
  - Autoplay policy (always, or respect Reduce Motion / Low Power Mode)
  - Loop behavior (infinite loop vs play-once)
  - Whether to show a "GIF" badge on bubbles/previews
- Confirm behavior when text + GIF are both sent (photo + caption using existing behavior?)
- Finalize limit values and error copy
- Confirm fallback for unsupported animated content

Deliverable: signed-off UX notes appended to this plan.

## Phase 1: MIME type persistence and incoming path

This must land before GIF rendering because the UI needs to know whether content is animated.

- Add MIME type to `StoredRemoteAttachment` (or a parallel metadata field)
- Persist incoming `Attachment.mimeType` in `DecodedMessage+DBRepresentation` instead of discarding it
- Propagate MIME type through `HydratedAttachment` so the rendering layer can branch
- Backfill strategy for existing messages: sniff first bytes for GIF magic number (`47 49 46 38`) at render time as fallback

Likely files:
- `ConvosCore/Sources/ConvosCore/Storage/Models/StoredRemoteAttachment.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Models/HydratedAttachment.swift`
- `ConvosCore/Sources/ConvosCore/Storage/XMTP DB Representations/DecodedMessage+DBRepresentation.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/MessagesRepository.swift`

## Phase 2: Typed attachment model in composer

- Replace `selectedAttachmentImage: UIImage?` with a media enum, e.g.:
  ```
  enum ComposerAttachment {
      case staticImage(UIImage)
      case animatedImage(Data, firstFrame: UIImage)
  }
  ```
- Update preview, removal, and send-enable logic to use new model
- Update photo picker filter to `.any(of: [.images, .animatedImages])` and handle GIF data from picker
- Update `ComposerTextView` paste handler to detect GIF data and create `.animatedImage` variant
- Add paste/pick-time preflight validation for GIF limits

Likely files:
- `Convos/Conversation Detail/ConversationViewModel.swift`
- `Convos/Conversation Detail/Messages/.../MessagesBottomBar.swift`
- `Convos/Conversation Detail/Messages/.../MessagesInputView.swift`
- `Convos/Shared Views/ComposerTextView.swift`

## Phase 3: Outgoing GIF-preserving pipeline

- Extend `PhotoAttachmentService` (or introduce a sibling) to accept raw `Data` + MIME type instead of only `ImageType`
- Generate filename based on media type (`.jpg` vs `.gif`)
- Propagate correct MIME type (`image/jpeg` vs `image/gif`) to XMTP `Attachment` constructor
- Skip JPEG recompression for GIF path
- Change `OutgoingMessageWriter.startEagerUpload` to accept either `ImageType` or raw `Data` (the current API only takes `ImageType`, which flattens GIFs)
- Add core-layer revalidation of GIF limits before encryption/upload
- Ensure invalid media never enters eager upload state

Likely files:
- `ConvosCore/Sources/ConvosCore/Messaging/PhotoAttachmentService.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Writers/OutgoingMessageWriter.swift`

## Phase 4: GIF rendering

The rendering approach: a **`UIViewRepresentable` wrapping a `UIImageView`** that loads frames via `CGImageSource`. This avoids third-party dependencies and follows the project's existing UIKit-wrapper pattern. SwiftUI's `Image(uiImage:)` does not animate GIF frames.

- Create an `AnimatedImageView` component (`UIViewRepresentable` + `CGImageSource` frame extraction)
- Use in composer preview for `.animatedImage` attachments
- Use in chat message attachment cells when MIME type indicates GIF
- Use in reply attachment thumbnails for consistency
- Static image rendering path (`Image(uiImage:)`) remains unchanged
- Respect `UIAccessibility.isReduceMotionEnabled` — show first frame only when enabled

Likely files:
- New: `Convos/Shared Views/AnimatedImageView.swift`
- Modified: `Convos/Conversation Detail/Messages/MessagesListView/MessagesGroupItemView.swift`
- Modified: `Convos/Conversation Detail/Messages/.../MessagesInputView.swift`
- Modified: `Convos/Conversation Detail/Messages/.../ReplyComposerBar.swift`

## Phase 5: QA + reliability hardening

- QA scenarios:
  - Paste GIF from clipboard → animated preview in composer → sends → animated in message list
  - Pick GIF from photo picker → same flow
  - Send GIF, receive on second device, verify animation
  - Reply to GIF message → thumbnail in reply bar
  - Paste oversized GIF → rejection with error message
  - Paste GIF with too many frames → rejection with error message
  - Reduce Motion enabled → GIF shows first frame only
  - Paste static image still works (regression)
  - Photo picker static image still works (regression)
  - Eager upload cancel/replace with GIF works
  - Background upload retry with GIF payload
  - Memory profiling with multiple large GIFs in conversation
- Regression checks:
  - Existing JPEG photo picker flow end-to-end
  - Background upload retry behavior
  - Reply-to-photo flow

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Memory pressure from animated GIF decoding | Total decoded pixel cap + frame count cap; fallback to first frame for oversized content |
| Data model changes rippling through eager upload and hydration | Land in stacked checkpoints (MIME persistence → model → pipeline → rendering) |
| GIF transcoding quality/performance tradeoffs | Iteration 1 uses rejection only, no transcoding; revisit with metrics |
| Eager upload API change (`ImageType` → also `Data`) | Additive overload, existing callers unchanged |
| `PhotoAttachmentService` MIME type hardcoded to `"image/jpeg"` | Parameterize in Phase 3; static image callers pass `"image/jpeg"` explicitly |
| Backfill for existing messages without MIME type | Byte-sniff GIF magic number at render time as fallback |

## Suggested PR Stack

1. Plan PR (this document)
2. MIME type persistence + incoming path
3. Typed composer attachment model + photo picker GIF support
4. Outgoing GIF-preserving pipeline
5. GIF rendering (AnimatedImageView + integration)
6. QA + cleanup

## Open Questions

1. Should GIF autoplay respect Reduce Motion / Low Power Mode? (Plan assumes yes for Reduce Motion)
2. Are the proposed default limits (15MB raw, 300 frames, 40M decoded pixels) acceptable after QA on older devices?
3. Should pasted image + text send as one message (photo + caption) using existing behavior?
4. Do we need a visible "GIF" badge in message bubbles?
5. Do we want a future iteration to add GIF transcoding/downsampling instead of rejection?
