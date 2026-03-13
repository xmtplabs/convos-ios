# Test: Receive File Attachments

Verify that generic file attachments (PDF, text, CSV, JSON, etc.) sent from
the CLI are received and displayed correctly in the app. Files should render
as compact message bubbles with a file type icon, filename, type label, and
file size — matching the iMessage file attachment design. Tapping a file should
open it in QuickLook for full-screen viewing. Context menu should offer Save to
Files and Share options.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

1. Reset the CLI and re-initialize for dev.
2. Create test files on disk:
   - `/tmp/test-document.pdf` — a small valid PDF
   - `/tmp/test-notes.txt` — a plain text file
   - `/tmp/test-data.csv` — a CSV file with a few rows
   - `/tmp/test-config.json` — a small JSON file
3. Create a conversation via CLI named "File Test" with profile name "Agent".
4. Generate an invite and open it as a deep link in the app.
5. Process the join request from the CLI.

## Steps

### Receive a PDF from CLI

6. Send the PDF from CLI: `convos conversation send-attachment <id> /tmp/test-document.pdf`.
7. Wait for the message to appear in the app.
8. Verify the file bubble shows:
   - A file type icon on the left (PDF icon or generic document icon)
   - Filename "test-document.pdf" (bold)
   - Type label "PDF Document" and file size below the filename
   - The bubble fits within the standard message bubble area
9. Verify the sender avatar appears in the correct position.

### Receive a text file from CLI

10. Send the text file: `convos conversation send-attachment <id> /tmp/test-notes.txt`.
11. Verify the file bubble shows the filename "test-notes.txt", type label, and size.

### Receive a CSV from CLI

12. Send the CSV: `convos conversation send-attachment <id> /tmp/test-data.csv`.
13. Verify the file bubble shows "test-data.csv" with appropriate type and size.

### Receive a JSON file from CLI

14. Send the JSON: `convos conversation send-attachment <id> /tmp/test-config.json`.
15. Verify the file bubble shows "test-config.json" with appropriate type and size.

### Tap file to open in QuickLook

16. Tap the PDF file bubble.
17. Verify a full-screen QuickLook preview opens showing the PDF content.
18. Verify the QuickLook toolbar has a share button.
19. Dismiss QuickLook (tap Done or swipe down).

### Tap text file to open in QuickLook

20. Tap the text file bubble.
21. Verify QuickLook opens and displays the text content.
22. Dismiss QuickLook.

### File context menu

23. Long-press the PDF file bubble.
24. Verify context menu shows: Reply, Save to Files, Share.
25. Dismiss the context menu.

### Save to Files

26. Long-press the PDF file bubble again.
27. Tap "Save to Files".
28. Verify the iOS document picker opens for choosing a save location.
29. Dismiss the picker.

### Share file

30. Long-press the PDF file bubble.
31. Tap "Share".
32. Verify the standard iOS share sheet opens with the file.
33. Dismiss the share sheet.

### Conversation list preview

34. Navigate back to the conversations list.
35. Verify the preview text shows the filename (e.g., "test-config.json") or
    "sent a file" for the most recent message.

### Incoming file blurred by default

36. Open the conversation and verify the file bubbles from the CLI user
    follow the same blur/reveal treatment as photos and videos.
37. If blurred, tap to reveal and verify the file bubble content becomes visible.

### Photo and video still work

38. Send a photo from the app (or verify existing photos in conversation still
    render correctly).
39. Verify file messages don't break photo/video rendering.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] PDF sent from CLI appears as file bubble with icon, filename, type, size
- [ ] Text file sent from CLI appears as file bubble with correct metadata
- [ ] CSV file sent from CLI appears as file bubble with correct metadata
- [ ] JSON file sent from CLI appears as file bubble with correct metadata
- [ ] File bubble layout matches iMessage style (icon left, text right, within bubble)
- [ ] Tapping file opens QuickLook full-screen preview
- [ ] QuickLook shows correct file content (PDF renders, text displays)
- [ ] QuickLook can be dismissed
- [ ] Context menu shows Reply, Save to Files, Share
- [ ] Save to Files opens document picker
- [ ] Share opens standard share sheet
- [ ] Conversation list shows filename or "sent a file" for file messages
- [ ] File messages respect blur/reveal privacy treatment
- [ ] Existing photo/video messages still render correctly

## Accessibility Identifiers Needed

- `file-attachment-bubble` — the file bubble container
- `file-attachment-icon` — the file type icon/thumbnail
- `file-attachment-filename` — the filename text
- `file-attachment-subtitle` — the type label and size text
