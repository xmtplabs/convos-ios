# Test: HTML Attachment Rendering

Verify that an HTML file attachment sent from the CLI is received and rendered
correctly in the app. An HTML attachment is special-cased (`HydratedAttachment.isHTMLFile`):
it is detected by a `.html` / `.htm` extension or a `text/html` MIME type and is
treated as full-bleed. Instead of a generic file bubble it renders as a tall
`html-attachment-bubble` tile: a sender header ("View ->") on top and a
thumbnail of the page below, produced by rendering the HTML at 160pt wide and
upsampling to fill the tile. Tapping the tile opens `AttachmentPreviewSheet`
full-screen, where the HTML is rendered live in a `WKWebView` with a close
button, the sender indicator, and a share affordance.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The CLI upload provider is configured (see note below) so
  `send-attachment` can encrypt, upload, and send the file as a remote
  attachment.

## Setup

1. Reset the CLI and re-initialize for dev.
2. Create a small test HTML file on disk at `/tmp/convos-qa-tile.html` with a
   visible heading and a distinct background color, e.g.:
   ```html
   <!DOCTYPE html>
   <html><head><meta charset="utf-8"><title>QA Tile</title></head>
   <body style="background:#1E88E5;color:#fff;font-family:-apple-system,sans-serif;margin:0;padding:32px;">
   <h1>Convos QA HTML Tile</h1>
   <p>If you can read this, the HTML attachment rendered.</p>
   </body></html>
   ```
3. Create a conversation via CLI named "HTML Test" with profile name "Agent".
4. Generate an invite and open it as a deep link in the app (`sim_open_url`).
5. Process the join request from the CLI (`--watch --timeout 30`).

> **CLI upload-provider dependency.** `convos conversation send-attachment`
> always encrypts the file, uploads it via the configured upload provider, and
> sends it as a *remote* attachment - there is no inline path. This means the
> app exercises its remote-attachment loader (`FileAttachmentLoader.loadFile`)
> when building the tile thumbnail and the preview. The provider must be
> configured before this test can send: set `CONVOS_API_KEY` (auto-selects the
> `convos-api` provider) or `CONVOS_UPLOAD_PROVIDER` in the CLI `.env`, or pass
> `--upload-provider` / `--upload-provider-token` on the command. If no
> provider is configured, `send-attachment` fails and the test cannot proceed.

## Steps

### Receive an HTML attachment from CLI

6. Send the HTML file from the CLI:
   `convos conversation send-attachment <id> /tmp/convos-qa-tile.html`.
7. Wait for the message to arrive in the app (expect a `message.received`
   event for the conversation).
8. Verify an `html-attachment-bubble` tile appears (not a generic file bubble).
9. Verify the tile shows the sender header: the sender avatar + name
   (`html-attachment-bubble-sender`) and a "View ->" affordance.
10. Verify the tile renders the page thumbnail filled (not a blank or
    placeholder tile) - the blue background and the "Convos QA HTML Tile"
    heading should be visible in the rendered thumbnail area.

### Tap the tile to open the full-screen preview

11. Tap the `html-attachment-bubble` tile.
12. Verify `AttachmentPreviewSheet` opens full-screen and shows:
    - `attachment-preview-close` (the X / Close button) in the toolbar.
    - `attachment-preview-sender` (the sender indicator with name and date).
    - `attachment-preview-share` (the share affordance - HTML always offers
      sharing the rendered image).
13. Verify the HTML renders live in the web view - the heading
    "Convos QA HTML Tile" and the body text are visible at full size.

### Close the preview

14. Tap `attachment-preview-close`.
15. Verify the preview dismisses and the conversation is shown again
    (`message-text-field` present) with the `html-attachment-bubble` tile
    still in the list.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] HTML attachment from CLI renders as an `html-attachment-bubble` tile,
      not a generic file bubble
- [ ] Tile shows the sender header (avatar, name, "View ->")
- [ ] Tile thumbnail renders the page content filled (heading + background
      color visible)
- [ ] Tapping the tile opens the full-screen `AttachmentPreviewSheet`
- [ ] Preview shows close, sender, and share controls
- [ ] HTML renders live in the preview web view (heading + body text visible)
- [ ] Closing the preview returns to the conversation with the tile intact

## Accessibility Identifiers Needed

- `html-attachment-bubble` - the tall HTML tile in the message list
- `html-attachment-bubble-sender` - the sender name inside the tile header
- `attachment-preview-close` - the close button in the preview sheet
- `attachment-preview-sender` - the sender indicator in the preview sheet
- `attachment-preview-share` - the share affordance in the preview sheet
