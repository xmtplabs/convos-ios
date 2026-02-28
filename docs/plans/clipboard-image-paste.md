# Plan: Clipboard Image Paste in Composer

## Goal

Allow users to paste images from the system clipboard into the message composer. Reuses the entire existing JPEG send pipeline with no changes to compression, upload, or rendering.

## Current State Assessment

### What works today

- Composer supports selecting a single image from Photos (`MessagesBottomBar` + `.photosPicker(..., matching: .images)`)
- Selected media is stored as `selectedAttachmentImage: UIImage?` in the conversation view model
- Outgoing photo pipeline (`OutgoingMessageWriter` + `PhotoAttachmentService`) supports one attachment and background upload
- Static photo compression targets ~1MB (`targetBytes: 1_000_000`) with a hard failure if resized JPEG is still above 10MB (`maxBytes: 10_000_000`)
- Eager upload starts automatically when `selectedAttachmentImage` changes (via `onPhotoSelected`)

### What is missing

- No clipboard paste handling exists anywhere in the composer (no paste hooks, no custom input delegate)
- The composer uses a SwiftUI `TextField` which has no paste interception API on iOS

## Scope

- Paste JPEG/PNG/HEIC from clipboard into composer
- Reuse existing `UIImage` attachment model and JPEG send pipeline — no pipeline changes
- Reuse existing eager upload, background upload, and rendering paths
- Validate pasted image can produce a `UIImage` before accepting

### Out of scope

- GIF / animated image support (separate plan: `docs/plans/gif-support.md`)
- Multi-attachment
- Any changes to the send pipeline, compression, or rendering

## Size Limits

Static images go through the existing compression pipeline, so limits are already enforced:
- `compressForPhotoAttachment` resizes to max 2048px dimension, targets ~1MB output
- Hard reject if resized image at quality 1.0 exceeds 10MB

No new limit infrastructure needed.

## Implementation

### Phase 1: Paste input mechanism

The composer uses a SwiftUI `TextField` with `.vertical` axis. SwiftUI does not provide reliable paste interception on iOS (`.onPasteCommand` is macOS/Catalyst only, `UIPasteControl` requires a system button tap).

The recommended approach is a **`UITextView` subclass wrapped in `UIViewRepresentable`** that overrides `paste(_:)`. The codebase already uses this pattern (`LinkTextView` is a `UITextView` subclass in `Convos/Shared Views/`).

Implementation:
- Create a composer-specific `UITextView` wrapper that intercepts `paste(_:)`
- On paste, check `UIPasteboard.general` for image types (`public.image`, `public.png`, `public.jpeg`)
- If image data is present, convert to `UIImage` and set as `selectedAttachmentImage`
- If only text is present, insert text normally
- If both image and text are on clipboard, prefer image (text can still be typed separately)
- Replace the current SwiftUI `TextField` in `MessagesInputView` with this wrapper
- Preserve all existing TextField behavior: placeholder, focus, multiline growth, on-submit

Likely files:
- New: `Convos/Shared Views/ComposerTextView.swift` (UITextView subclass + UIViewRepresentable)
- Modified: `Convos/Conversation Detail/Messages/.../MessagesInputView.swift` (swap TextField)
- Modified: `Convos/Conversation Detail/Messages/.../MessagesBottomBar.swift` (wire paste callback)

### Phase 2: Validation and UX

- Validate pasted image can produce a `UIImage` before accepting
- If `UIImage(data:)` returns nil, discard silently (corrupt/unsupported data)
- Existing eager upload flow handles the rest — `onPhotoSelected` is already called when `selectedAttachmentImage` changes
- Text draft is preserved when image paste fails

### Phase 3: QA

- Paste JPEG from clipboard → appears in composer preview → sends successfully
- Paste PNG from clipboard → same flow
- Paste screenshot (PNG) → same flow
- Paste image from Safari/web → same flow
- Paste text only → inserts text normally
- Paste image when attachment already exists → replaces previous attachment
- Paste image, remove it, type text, send → text-only message
- Copy image from Photos app, paste into composer → works
- Hardware keyboard ⌘V and edit menu "Paste" both work
- Regression: photo picker flow unchanged
- Regression: text input behavior (multiline, submit, placeholder) unchanged

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| `UITextView` wrapper doesn't match `TextField` behavior (placeholder, focus, growth) | Follow existing `LinkTextView` pattern; match current styling and layout precisely |
| `FocusState` integration with UIKit text view | Use `UIViewRepresentable` coordinator to bridge `becomeFirstResponder`/`resignFirstResponder` with SwiftUI focus |
| Edit menu "Paste" differs from ⌘V behavior | Both go through `paste(_:)` override on `UITextView` — single code path |

## Suggested PR Stack

1. Plan PR (this document)
2. `ComposerTextView` wrapper + paste handling + validation
