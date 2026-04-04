# Generic File Attachment Support — Investigation

## Context

AI Assistants (agents) need to send users files beyond photos and videos — PDFs, documents, spreadsheets, code, Markdown, CSVs, etc. The app currently only renders image and video attachments. Any other MIME type silently falls through to a failed/empty state.

This document investigates what it would take to:
1. Render inline previews for generic files in the messages list
2. Let users open/view files in a full-screen preview
3. Let users save files to the iOS Files app or share them

## Current State

### What Works Today (Protocol Layer)

The XMTP protocol is **fully content-type agnostic**. The `Attachment` type is just `{filename, mimeType, data}` — no image-specific logic. Both `AttachmentCodec` (inline ≤1MB) and `RemoteAttachmentCodec` (encrypted + uploaded) work with any file type.

The CLI already supports sending any file: `convos conversation send-attachment <id> ./report.pdf`

### What Blocks Generic Files Today (App Layer)

| Layer | File | Issue |
|-------|------|-------|
| **Message decoding** | `DecodedMessage+DBRepresentation.swift` | No longer blocks — `image/` MIME guard was removed for video support |
| **DB model** | `StoredRemoteAttachment` | Already stores `mimeType`, `filename`. Works for any type. |
| **Hydration** | `MessagesRepository` → `hydrateAttachment()` | `MediaType` enum already has `.file` case. `HydratedAttachment` carries `mimeType` and `filename`. |
| **UI rendering** | `AttachmentPlaceholder` in `MessagesGroupItemView.swift` | Only renders `UIImage` or `AVPlayer`. No file preview path. Falls through to loading/error state for PDFs, etc. |
| **Message preview** | `DBMessage+MessagePreview.swift` | `attachmentsPreviewString` returns "a photo" or "a video". No "a file" / "a document" case. |
| **Context menu** | `MessageContextMenuOverlay.swift` | Save action only handles images and videos. No "Save to Files" or "Open In..." |
| **Reply views** | `ReplyComposerBar.swift`, `ReplyReferenceView.swift` | Only render photo/video thumbnails. No file icon/name for generic files. |

### What We Get for Free

- `HydratedAttachment.mediaType` already returns `.file` for non-image/video MIME types
- `StoredRemoteAttachment` already round-trips `mimeType` and `filename` through JSON
- `RemoteAttachmentLoader.loadAttachmentData()` returns `LoadedAttachment(data, mimeType, filename)` — works for any file
- The `AttachmentLocalState` DB table already has a `mimeType` column (added for video)
- `MediaType` enum already has `.audio`, `.file`, `.unknown` cases

## Investigation: File Preview Rendering

### Option A: QLThumbnailGenerator for Message Bubbles

iOS's `QLThumbnailGenerator` can generate thumbnail images for most file types — PDFs, Office docs, iWork docs, text files, source code, and more. It falls back to a system file-type icon for unsupported formats.

```swift
import QuickLookThumbnailing

let request = QLThumbnailGenerator.Request(
    fileAt: localFileURL,
    size: CGSize(width: 120, height: 160),
    scale: UIScreen.main.scale,
    representationTypes: [.thumbnail, .icon]
)

let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
let image = thumbnail.uiImage
```

**Pros:**
- Automatic support for 20+ file types without custom rendering
- Native iOS quality — same thumbnails as Files app
- Generates both content thumbnails (first page of PDF) and type icons (fallback)

**Cons:**
- Requires file on local disk — must download + decrypt first
- Async operation — adds latency to first render
- No thumbnail for many programmatic file types (.json, .yaml, .csv — renders as text icon only)

**Recommendation:** Use for the inline message bubble preview. The flow would be:
1. Show placeholder with file icon + filename + file size while loading
2. Download + decrypt file to temp directory
3. Generate thumbnail via `QLThumbnailGenerator`
4. Display thumbnail image in bubble (similar to photo treatment but smaller, with filename overlay)

### Option B: Custom Renderers Per File Type

Build custom inline previews for specific high-value types:
- **PDF:** First page via `PDFKit` (`PDFDocument` → `PDFPage.thumbnail()`)
- **Markdown:** Render to `AttributedString` and show styled preview text
- **Code/Text:** Show first N lines in monospace font
- **CSV:** Show mini table view with first few rows

**Pros:** Richer, more useful previews
**Cons:** Significant dev effort per type, maintenance burden

**Recommendation:** Not for V1. Start with QLThumbnailGenerator and add custom renderers for high-value types later.

### Option C: Sender-Generated Thumbnails (like video)

The sender generates a thumbnail and embeds it as base64 in the `StoredRemoteAttachment` metadata, same as video thumbnails today.

**Pros:** Instant display, no download needed for preview
**Cons:** Only works for app-sent files (agents use CLI, which doesn't generate thumbnails). Adds message size.

**Recommendation:** Use as an optimization layer on top of Option A. If `thumbnailDataBase64` exists, use it immediately; otherwise fall back to QLThumbnailGenerator after download.

### Recommended Approach: Hybrid (A + C)

1. **Immediate render:** File icon + filename + size badge (from metadata in `StoredRemoteAttachment`)
2. **If thumbnail exists in metadata:** Show it immediately (like video thumbnails)
3. **After download:** Generate QLThumbnail and cache it (replaces icon)
4. **Cache thumbnails** in `ImageCache` with `.persistent` tier so they survive app restarts

## Investigation: Full-Screen File Viewing

### SwiftUI `.quickLookPreview()` Modifier

The simplest approach — SwiftUI's built-in QuickLook integration:

```swift
@State private var previewURL: URL?

view
    .quickLookPreview($previewURL)
```

When `previewURL` is set, iOS presents a full-screen `QLPreviewController` modally. Supports:
- PDF (with page navigation, search, markup)
- Office docs (Word, Excel, PowerPoint)
- iWork docs (Pages, Numbers, Keynote)
- Images, videos, audio
- Text, RTF, HTML, CSV
- 3D models (USDZ)

The user gets native iOS file viewing with share, markup, and print built in.

**Flow:**
1. User taps file attachment bubble
2. If file not yet downloaded: show loading spinner, download + decrypt, save to temp with correct filename/extension
3. Set `previewURL` → system presents QLPreviewController
4. User can share from within QuickLook (share button in toolbar)

**Key detail:** The temp file MUST have the correct file extension (e.g., `.pdf`, not `.bin`) for QuickLook to render it properly. Use `UTType(mimeType:)?.preferredFilenameExtension` to derive the extension from MIME type.

### UIDocumentInteractionController (Alternative)

More control than QuickLook — shows "Open In..." menu with compatible apps. But it's UIKit-only and mostly superseded by `UIActivityViewController`.

**Recommendation:** Use `.quickLookPreview()` for V1. It's the standard iOS pattern and requires minimal code.

## Investigation: Save to Files / Share

### Option 1: Share Sheet via UIActivityViewController

Present a share sheet with the file URL. The system automatically offers:
- Save to Files
- AirDrop
- Mail, Messages
- Third-party apps (Slack, Google Drive, etc.)

This is what the QuickLook share button already does, so we get it for free with `.quickLookPreview()`.

### Option 2: Direct "Save to Files" via UIDocumentPickerViewController

```swift
let picker = UIDocumentPickerViewController(forExporting: [fileURL])
picker.shouldShowFileExtensions = true
present(picker, animated: true)
```

This opens the Files app picker directly, letting the user choose where to save.

### Option 3: Context Menu Actions

Add to the long-press context menu:
- **"Save to Files"** — Opens document picker for save location
- **"Share"** — Opens share sheet
- **"Open"** — Opens in QuickLook

**Recommendation:** For V1:
- Tap → QuickLook preview (which has built-in share)
- Context menu → "Save to Files" + "Share" + "Open"

## Investigation: Message List Preview Text

Currently `attachmentsPreviewString` returns "a photo" or "a video". For files, we should show the filename:

```swift
static func attachmentsPreviewString(attachmentUrls: [String], count: Int) -> String {
    // ... existing photo/video logic ...
    
    // For generic files, show filename
    if let stored = try? StoredRemoteAttachment.fromJSON(attachmentUrls.first ?? ""),
       let filename = stored.filename {
        return count <= 1 ? filename : "\(count) files"
    }
    return count <= 1 ? "a file" : "\(count) files"
}
```

## Data Model Changes Required

### StoredRemoteAttachment — Needs One Addition

The existing fields cover most file metadata:
- `filename` — Already present
- `mimeType` — Already present (added for video)
- `mediaWidth`/`mediaHeight` — N/A for files, already optional
- `thumbnailDataBase64` — Can be reused for file thumbnails

One addition needed:
- `fileSize: Int64?` — Original file size in bytes (for display in bubble). Not currently stored. The XMTP `RemoteAttachment.contentLength` is the *encrypted* payload size, not the original.

### HydratedAttachment — Two Fields Need Hydration

- `filename: String?` — Currently NOT hydrated from `StoredRemoteAttachment`. Must be added to `hydrateAttachment()` in `MessagesRepository`. Critical for determining file type when `mimeType` is nil.
- `fileSize: Int?` — Already defined on `HydratedAttachment` but never populated. Should be hydrated from `StoredRemoteAttachment.fileSize` once that field exists.

### filename Hydration Path

Currently in `MessagesRepository.hydrateAttachment()`:

```swift
private func hydrateAttachment(key: String, localState: AttachmentLocalState?) -> HydratedAttachment {
    // ... existing code extracts mimeType, duration, thumbnailDataBase64, width, height
    // filename is NOT extracted — needs to be added:
    var filename: String? = nil
    if let stored = try? StoredRemoteAttachment.fromJSON(key) {
        filename = stored.filename
        // ... existing extractions
    }
    // For file:// URLs, derive from path
    if filename == nil, key.hasPrefix("file://") {
        filename = URL(string: key)?.lastPathComponent
    }
}
```

### AttachmentLocalState — No Changes

Already has `mimeType` column.

## UI Design: File Attachment Bubble

### Proposed Layout (Compact)

```
┌─────────────────────────────────┐
│  ┌────┐                        │
│  │ 📄 │  report.pdf            │
│  │    │  245 KB · PDF          │
│  └────┘                        │
└─────────────────────────────────┘
```

For files with thumbnails (after QLThumbnailGenerator):

```
┌─────────────────────────────────┐
│  ┌────────┐                    │
│  │ thumb  │  report.pdf        │
│  │ nail   │  245 KB · PDF      │
│  └────────┘                    │
└─────────────────────────────────┘
```

### Components:
- **File icon or thumbnail:** 48×64pt area. SF Symbol `doc.fill` initially, replaced by QLThumbnail after download.
- **Filename:** Primary text, truncated with ellipsis.
- **Subtitle:** File size + file type label (derived from MIME type or extension).
- **Background:** Rounded rectangle matching message bubble style.
- **Sender avatar:** Same position as photo/video messages.

### File Type to Icon Mapping

Use SF Symbols for instant rendering before thumbnail loads:

| MIME Type | SF Symbol | Label |
|-----------|-----------|-------|
| `application/pdf` | `doc.fill` | PDF |
| `text/plain` | `doc.text.fill` | Text |
| `text/markdown` | `doc.text.fill` | Markdown |
| `text/csv` | `tablecells.fill` | CSV |
| `text/html` | `globe` | HTML |
| `application/json` | `curlybraces` | JSON |
| `application/zip` | `doc.zipper` | ZIP |
| `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | `doc.fill` | Word |
| `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | `tablecells.fill` | Excel |
| `application/vnd.openxmlformats-officedocument.presentationml.presentation` | `rectangle.fill.on.rectangle.angled.fill` | PowerPoint |
| `audio/*` | `waveform` | Audio |
| (default) | `doc.fill` | File |

## Implementation Layers (Estimated Effort)

### Layer 1: Receive & Display (Core — ~2 days)

1. Add `filename` hydration to `hydrateAttachment()` in `MessagesRepository`
2. Add `fileSize` hydration from `StoredRemoteAttachment` metadata
3. Create `FileAttachmentBubble` SwiftUI view (icon + filename + size)
4. Route `MediaType.file` in `AttachmentPlaceholder` to `FileAttachmentBubble` instead of photo path
5. Update `attachmentsPreviewString` for conversation list ("report.pdf" instead of "a photo")
6. Update reply views to show file icon + filename instead of photo thumbnail

### Layer 2: Download & Preview (Core — ~2 days)

1. Download + decrypt file via `RemoteAttachmentLoader.loadAttachmentData()`
2. Save to temp directory with correct file extension
3. Present via `.quickLookPreview()` on tap
4. Add download progress indicator to bubble
5. Cache downloaded files in `VideoURLCache`-style actor (reuse for repeat opens)

### Layer 3: Thumbnails (Polish — ~1 day)

1. After download, generate thumbnail via `QLThumbnailGenerator`
2. Cache thumbnail in `ImageCache` with persistent tier
3. Replace file icon with thumbnail in bubble
4. For sender-generated thumbnails (future), display from `thumbnailDataBase64`

### Layer 4: Context Menu & Save (Polish — ~1 day)

1. Add "Save to Files" context menu action (UIDocumentPickerViewController)
2. Add "Share" context menu action (UIActivityViewController)
3. Add "Open" context menu action (QuickLook)
4. Handle file-specific context menu (no "Blur/Reveal" for files)

### Layer 5: Conversation List & Notifications (Polish — ~0.5 day)

1. Update preview text: show filename for file attachments
2. Update push notification text for file messages

### Total Estimated Effort: ~6.5 days

## Critical Finding: MIME Type Not Available at Receive Time

When a `RemoteAttachment` arrives via XMTP, we only get `{url, contentDigest, secret, salt, nonce, filename}`. The `mimeType` is inside the encrypted payload — only available after download and decryption.

For **sender-side** (our app sending video), we embed `mimeType` into `StoredRemoteAttachment` during send. But for **receiver-side** (files from agents/CLI), `StoredRemoteAttachment.mimeType` will be `nil`.

**Implication:** We must derive media type from the `filename` extension:

```swift
import UniformTypeIdentifiers

extension HydratedAttachment {
    var mediaType: MediaType {
        // Check explicit mimeType first (sender-set)
        if let mimeType {
            if mimeType.hasPrefix("image/") { return .image }
            if mimeType.hasPrefix("video/") { return .video }
            if mimeType.hasPrefix("audio/") { return .audio }
            return .file
        }
        
        // Fall back to filename extension
        if let filename = self.filename,
           let ext = filename.split(separator: ".").last,
           let utType = UTType(filenameExtension: String(ext)) {
            if utType.conforms(to: .image) { return .image }
            if utType.conforms(to: .movie) || utType.conforms(to: .video) { return .video }
            if utType.conforms(to: .audio) { return .audio }
            return .file
        }
        
        // No mimeType, no filename → assume image (backward compat)
        return .image
    }
}
```

This also means `filename` MUST be hydrated from `StoredRemoteAttachment` to `HydratedAttachment` — it currently isn't.

After the file is downloaded and decrypted, we get the actual `mimeType` from the `Attachment` payload. At that point, we should update `AttachmentLocalState.mimeType` so subsequent renders use the authoritative MIME type.

### Inline Attachments (≤1MB from CLI)

For inline `ContentTypeAttachment` messages, the attachment `data` is decoded immediately and saved to `Caches/InlineAttachments/{messageId}_{filename}`. The `attachmentUrls` array stores a `file://` URL (not JSON).

The `Attachment.mimeType` IS available at decode time but is **not currently stored** — only the file URL is saved. The filename preserves the original extension, so we can derive type from extension.

However, for correctness we should store the mimeType in `AttachmentLocalState` at decode time for inline attachments:

```swift
// In handleAttachmentContent():
let fileURL = try Self.saveInlineAttachment(data: attachment.data, messageId: id, filename: attachment.filename)
// NEW: Also save mimeType for inline attachments
// (needs to be done post-save in StreamProcessor since we don't have conversationId here)
```

### Two Attachment Key Formats

| Format | Source | Example |
|--------|--------|---------|
| `file://...` URL | Inline attachments (≤1MB), just-sent photos/videos | `file:///var/.../Caches/InlineAttachments/msgId_report.pdf` |
| JSON string | Remote attachments (>1MB) | `{"url":"https://...","contentDigest":"...","filename":"report.pdf",...}` |

The UI code checks `attachment.key.hasPrefix("file://")` to distinguish these. For `file://` keys, it reads data directly. For JSON keys, it uses `RemoteAttachmentLoader` to download + decrypt.

## Key Questions to Resolve Before Implementation

1. **File size limit:** Currently 25MB for video. Same limit for files? The XMTP `RemoteAttachment` has no inherent limit, but S3 presigned URLs and upload may have constraints.

2. **Blur/reveal for files:** Should files from non-contacts be blurred like photos? Files don't have visual content to blur — could show "File from unknown sender" with a reveal button. Or skip blur entirely for files (only apply to visual media).

3. **Inline vs. remote threshold:** CLI sends inline (≤1MB) or remote (>1MB). Our app always sends remote for photos/video. For files, do we want to support inline `ContentTypeAttachment` receiving? Currently `handleAttachmentContent()` saves inline attachments to `Caches/InlineAttachments/` — this already works.

4. **Audio files:** `MediaType.audio` is already defined. Should audio get its own playback treatment (waveform + play button) or be treated as a generic file? iMessage shows audio as inline waveform players.

5. **Agent thumbnail generation:** Should the agent SDK / CLI be enhanced to generate and embed thumbnails for files it sends? This would give instant previews without download.

6. **File caching strategy:** Downloaded files can be large. Should they persist across sessions (Application Support) or be treated as temp (Caches, OS can purge)? Videos currently use temp directory.

## Appendix: MIME Types Agents Are Likely to Send

Based on common AI assistant use cases:

| Category | Types | Priority |
|----------|-------|----------|
| Documents | PDF, DOCX, TXT, RTF | High |
| Data | CSV, JSON, XML, YAML | High |
| Code | .py, .swift, .js, .ts, .html, .css | Medium |
| Markdown | .md | High |
| Spreadsheets | XLSX, Numbers | Medium |
| Presentations | PPTX, Keynote | Low |
| Archives | ZIP, TAR.GZ | Low |
| Audio | MP3, WAV, M4A | Medium (separate feature) |
