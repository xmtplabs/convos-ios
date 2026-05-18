# Whiteboard Attachment

## User Story

**As a user, I want to draw something on a whiteboard and send it as an attachment in a conversation.**

Flow: Attach → Camera Roll / **Whiteboard** → Whiteboard → Draw → Send

## Problem

Users currently have no way to quickly sketch, annotate, or hand-draw something inline in a conversation. The only image sources are the photo library and the camera. A whiteboard fills the gap for quick diagrams, doodles, handwritten notes, or visual explanations without leaving the app.

## Existing Architecture

### Attachment pipeline

The entire image-send flow is driven by a single binding:

```swift
@Binding var selectedAttachmentImage: UIImage?
```

When this value is set (from any source — photo picker, camera, or a future whiteboard), the following happens automatically:

1. A thumbnail preview appears in the composer (`MessagesInputView.attachmentPreviewArea`)
2. The user can remove it via the X button before sending
3. On send, `ConversationViewModel.sendAttachmentIfNeeded()` fires
4. The image is compressed, encrypted, and uploaded via `PhotoAttachmentService`
5. A `RemoteAttachment` is published over XMTP
6. Recipients see it as a normal image bubble

No changes to the send pipeline, encryption, XMTP encoding, or receiving/rendering are required. The whiteboard is just another `UIImage` source.

### Media buttons

`MessagesMediaButtonsView` renders the row of attachment actions (photo library, camera, voice memo, Convos action). Each button toggles a `@State` bool that presents a picker or full-screen cover. Adding a whiteboard button follows the same pattern.

### Key files

| File | Role |
|------|------|
| `Convos/.../Views/MessagesMediaInputView.swift` | Media button row (`MessagesMediaButtonsView`) |
| `Convos/.../Views/MessagesBottomBar.swift` | Wires pickers, camera, and media buttons; manages `selectedAttachmentImage` |
| `Convos/.../Views/MessagesInputView.swift` | Composer with attachment preview strip |
| `Convos/.../Views/CameraPickerView.swift` | Reference pattern — `UIViewControllerRepresentable` that returns a `UIImage` |
| `Convos/Conversation Detail/ConversationViewModel.swift` | Send orchestration; `onPhotoSelected`, `sendAttachmentIfNeeded` |
| `ConvosCore/.../Writers/OutgoingMessageWriter.swift` | Eager upload, encryption, XMTP publish |
| `ConvosCore/.../Messaging/PhotoAttachmentService.swift` | Compression, encryption, upload |

## Design

### Entry point

Add a whiteboard button to `MessagesMediaButtonsView`, between the camera and voice memo buttons.

- SF Symbol: `pencil.tip.crop.circle` (or `scribble.variable` — designer's call)
- Accessibility label: "Whiteboard"
- Behavior: sets `isWhiteboardPresented = true`

### Whiteboard screen

Presented as a `.fullScreenCover` (same as the camera), containing a drawing canvas.

**Technology:** PencilKit (`PKCanvasView`). It provides:

- Finger and Apple Pencil drawing out of the box
- Pen, marker, and eraser tools
- Pressure and tilt sensitivity (Apple Pencil)
- Programmatic undo/redo
- Rendering to `UIImage` via `PKDrawing.image(from:scale:)`

**Layout:**

```
┌──────────────────────────────────┐
│  Cancel              Done        │  ← Navigation bar
├──────────────────────────────────┤
│                                  │
│                                  │
│         PKCanvasView             │  ← Drawing area (white background)
│                                  │
│                                  │
├──────────────────────────────────┤
│  Undo   Redo   Color   Tool     │  ← Toolbar
└──────────────────────────────────┘
```

**Controls:**

| Control | Behavior |
|---------|----------|
| Cancel | Dismiss without sending. If the canvas has strokes, show a confirmation alert. |
| Done | Render the canvas to `UIImage`, pass it back, dismiss. |
| Undo / Redo | `PKCanvasView.undoManager` (built-in) |
| Tool picker | Pen / Marker / Eraser. Can use `PKToolPicker` (system-provided floating palette) or a custom segmented control. |
| Color | A small palette of preset colors (black, red, blue, green, orange, purple) + optional custom color via `ColorPicker`. |

**Canvas rendering:**

```swift
let image = drawing.image(from: canvasView.bounds, scale: UIScreen.main.scale)
```

This produces a `UIImage` at screen resolution — the same type the rest of the pipeline expects.

### Wiring

In `MessagesBottomBar`:

```swift
@State private var isWhiteboardPresented: Bool = false

// In the .fullScreenCover chain:
.fullScreenCover(isPresented: $isWhiteboardPresented) {
    WhiteboardView(
        onImageCreated: { image in
            selectedAttachmentImage = image
            isWhiteboardPresented = false
            focusCoordinator.moveFocus(to: .message)
        }
    )
    .ignoresSafeArea()
}
```

In `MessagesMediaButtonsView`, add the binding and a new button.

### What the recipient sees

The drawing is sent as a standard image attachment (`RemoteAttachment` with JPEG/PNG data). Recipients see it in a normal image bubble — no special rendering needed. They can long-press to save it to their photo library, same as any other image.

## Scope

### In scope (v1)

- Whiteboard button in the media button row
- Full-screen drawing canvas using PencilKit
- Pen tool with a small color palette
- Eraser tool
- Undo / redo
- Cancel with discard confirmation (if canvas is not empty)
- Done → renders to `UIImage` → sets `selectedAttachmentImage`
- User can add text in the composer alongside the drawing before sending
- Preview thumbnail in the composer (existing behavior)
- Remove drawing before sending (existing X button behavior)

### Out of scope (future)

- Drawing annotations on top of photos
- Background color or template options (grid paper, dot grid)
- Text tool on the canvas
- Shape recognition / straight-line assist
- Custom XMTP content type for vector drawings
- Collaborative / real-time shared whiteboard
- Recipient-side "Whiteboard" label or badge on the bubble

## Implementation Plan

### 1. `WhiteboardView` (new file)

Create `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/Views/WhiteboardView.swift`.

- `UIViewControllerRepresentable` wrapping a view controller that hosts `PKCanvasView`
- Callback: `onImageCreated: (UIImage) -> Void`
- Navigation bar with Cancel and Done
- Bottom toolbar with undo, redo, color picker, tool selector
- `PKToolPicker` attached to the canvas for the system tool palette (alternatively, a custom toolbar if we want tighter design control)

### 2. Update `MessagesMediaButtonsView`

- Add `@Binding var isWhiteboardPresented: Bool`
- Add a button between camera and voice memo

### 3. Update `MessagesBottomBar`

- Add `@State private var isWhiteboardPresented: Bool`
- Pass the binding to `MessagesMediaButtonsView`
- Add `.fullScreenCover` for `WhiteboardView`
- On image created: set `selectedAttachmentImage`, dismiss, move focus

### 4. Update `MessagesView` / parent wiring

- Thread the new binding through if needed (check if `MessagesMediaButtonsView` is used elsewhere)

### 5. Preview updates

- Update `#Preview` blocks in modified files to include the new binding

## Estimated Effort

| Task | Estimate |
|------|----------|
| `WhiteboardView` with PencilKit canvas | 1 day |
| Media button + `MessagesBottomBar` wiring | 2 hours |
| Polish (transitions, discard confirmation, toolbar design) | 0.5 day |
| Testing (device + simulator, finger + Apple Pencil) | 0.5 day |
| **Total** | **~2 days** |

## Open Questions

1. **Tool palette style:** Use the system `PKToolPicker` (floating, Apple-standard, supports Apple Pencil hover) or a custom fixed toolbar (more design control, consistent with app aesthetic)?
2. **Canvas background:** Always white? Or offer a dark option for dark mode? A transparent background would render as white in JPEG but could be PNG with transparency.
3. **Image format:** JPEG (smaller, lossy, no transparency) or PNG (lossless, supports transparency, larger)? The existing photo pipeline uses JPEG compression — drawings with flat colors compress well either way.
4. **Button placement:** Where exactly in the media row? Between camera and voice memo? Replace the Convos action button? Add to an overflow menu if the row gets crowded?
5. **Canvas size / aspect ratio:** Full-screen canvas rendered at screen resolution? Or a fixed aspect ratio (e.g., 4:3, square) for more predictable bubble sizing on the recipient side?
