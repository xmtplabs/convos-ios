# Multi-attachment composer

## Problem

The composer in a conversation can stage at most one attachment at a time today — either one photo, one video, one file, one side-convo invite, or one link preview. Users routinely want to send several photos or files in a single composing session and currently have to send each one as its own send action, which is friction-heavy on mobile and produces noisy chat history when they get it wrong (e.g. forgetting to attach the third photo).

## Goal

Let the user stage up to **8** photos / videos / files at once (any mix), in an explicit order, and send them with a single tap. Side convo invites and link previews retain their existing single-instance semantics.

## Rules

- **Max 1 side convo** per send. The side-convo button is disabled while one is staged.
- **Max 8 photos + videos + files combined** per send. Reaching 8 disables the photo, camera, and file buttons.
- **Voice memo stays as its own one-off thing.** Recording takes over the input bar today; that doesn't change. Voice memos do not count toward the 8 and cannot coexist with other staged attachments.
- **Send order = the order attachments appear in the bar.** Text always sends last.
- **Pickers respect remaining capacity.** If 2 photos are staged, the photos picker offers `maxSelectionCount: 6` and the file picker truncates the selection to 6 (with a notification if more were picked).

## Wire format: separate messages, not MultiRemoteAttachment

XMTP's `MultiRemoteAttachment` codec bundles N attachments into a single message. Reactions and replies in XMTP target a `messageId` only — there is no `subreference` or `attachmentIndex`, so a reaction on a `MultiRemoteAttachment` message reacts to the bundle as a unit, not to one item within it.

iMessage and WhatsApp both let users react to and reply to individual photos in a multi-photo send. To match that, **we send each staged attachment as its own message**, sequenced in bar order. Per-item reactions and replies then work natively because each attachment is its own message with its own ID. The receiving render path also requires no changes — it already handles single-attachment messages.

The cost is N publishes instead of 1: more network chatter, more potential partial-failure points, and the total "send time" is the sum of upload times rather than the max. Eager upload (already wired for photos) mitigates this — uploading happens during composition, leaving only `publish()` to serialize at send time. Extending eager upload to videos and files is a follow-up.

## Send sequence

For a send with staged state `[photo, video, file]` + side convo + text:

1. Side convo invite publishes first (existing path)
2. Each media attachment publishes as its own message, in bar order, **awaited sequentially** so they land in order on the recipient
3. Text + link preview publishes last (existing path)

If attachment N of M fails to upload or publish, the chain stops. The failed attachment surfaces as a failed-message bubble using the existing failed-message UI (which already supports retry and delete per item). Subsequent attachments and the trailing text are not sent — the user sees the failed bubble in chat and can decide whether to retry it or recompose.

## State model

Replace the three single-attachment fields on `ConversationViewModel` with one ordered array:

```swift
enum PendingMediaAttachment: Identifiable, Equatable {
    case photo(PendingPhotoAttachment)   // image + per-item eager upload key + tracking key
    case video(PendingVideoAttachment)   // URL + thumbnail
    case file(PendingFileAttachment)
    var id: UUID { ... }
}
var pendingMediaAttachments: [PendingMediaAttachment] = []  // ordered, capped at 8
```

`pendingInvite` and `pastedLinkPreview` stay separate — they are singletons with dedicated UI and different lifecycle.

The current `currentEagerUploadKey` singleton becomes per-photo state inside `PendingPhotoAttachment`. Each photo entry tracks its own eager upload independently so the user can stage several photos in parallel.

## UI changes

- **`MessagesInputView.attachmentPreviewArea`** iterates over `pendingMediaAttachments` (one preview card per item) instead of branching on three optional fields. Each card has the existing poof-to-dismiss pattern and removes by `id` from the array. Side convo and link preview cards continue to render at fixed positions.
- **`MessagesMediaButtonsView`** — photo, camera, and file buttons disabled when `mediaCount == 8`. Side convo button disabled when a side convo is staged. Voice memo button unaffected.
- **PhotosPicker** — pass `maxSelectionCount: 8 - mediaCount`.
- **`.fileImporter`** — enable `allowsMultipleSelection: true`. The callback truncates the picked URLs to remaining capacity and shows a brief alert when truncation happens.

## Receiving side

No changes. Each attachment arrives as its own message; existing single-attachment rendering handles them. Per-item reactions and replies work naturally.

(Optional follow-up someday: client-side visual grouping — render N consecutive media messages from the same sender within a short window with shared rounded corners, WhatsApp-style. Pure render-layer change, no protocol change. Out of scope here.)

## Stacked PRs

1. **State model refactor.** Replace `selectedAttachmentImage` / `selectedVideoURL` / `pendingFileAttachment` with `pendingMediaAttachments`. UI still allows only one staged at a time. Send path extracts the head element to call existing single-attachment writers. Pure refactor, no behavior change.
2. **Sequential multi-send.** New `OutgoingMessageWriter.sendMediaAttachments(_:replyToMessageId:)` loops the existing per-type writers, awaiting each. `ConversationViewModel.onSendMessage` switches to it. UI still 1-at-a-time, but the writer can handle N. Per-photo eager-upload tracking moves from singleton key to dictionary keyed by attachment id.
3. **Multi-select UI.** Picker capacity wiring, button disabled states, preview-area iteration. This is when the cap actually lifts to 8 from the user's perspective.
4. **Polish.** Mid-upload cancellation when removing from the bar, optional eager upload extended to videos and files, any partial-failure UX gaps that surfaced during dogfooding.

Drag-to-reorder and visual grouping of received multi-attachment sequences are deferred and not in this stack.

## Out of scope

- Reordering staged attachments (defer until users ask)
- Visual grouping of received media (render-layer follow-up)
- Voice memo as a multi-slot media type (recording UX is its own surface)
- Captions on the wire (text remains a separate trailing message)
