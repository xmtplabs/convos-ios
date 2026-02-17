# Test: Message Gestures and Interactions

Verify all gesture-based interactions in the messages list: single tap, double tap, long press, swipe to reply, link tapping, avatar tapping, reaction indicator tapping, and context menu actions across all message content types (text, emoji, photo, invite).

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The simulator photo library has at least one image.

## Setup

1. Create a conversation via CLI named "Gesture Test" with a profile name "GestureBot".
2. Generate an invite and open it as a deep link in the app.
3. Process the join request from the CLI (per invite ordering rules in RULES.md).
4. Verify the app enters the conversation.
5. From the CLI, send the following messages in order:
   - A text message: "Hello from the CLI"
   - A text message containing a URL: "Check out https://example.com for details"
   - An emoji message: "🎉"
6. From the app, send a text message: "Hello from the app"
7. From the CLI, send an inline attachment (a test photo downloaded from picsum).
8. Wait for all messages to appear in the app.

## Steps

### Double tap — toggle heart reaction

9. Double-tap the CLI text message "Hello from the CLI".
10. Verify a ❤️ reaction indicator appears below the message.
11. Double-tap the same message again.
12. Verify the ❤️ reaction indicator disappears (reaction toggled off).
13. Double-tap the emoji message "🎉" from the CLI.
14. Verify a ❤️ reaction indicator appears below the emoji.
15. Double-tap the app's own message "Hello from the app".
16. Verify a ❤️ reaction indicator appears below the outgoing message.

### Swipe right — reply

17. Swipe right on the CLI text message "Hello from the CLI" (horizontal swipe, ≥60pt).
18. Verify the reply composer bar appears at the bottom, showing "Replying to GestureBot: Hello from the CLI" (accessibility identifier: `reply-composer-bar`).
19. Verify the cancel button is visible (accessibility identifier: `cancel-reply-button`).
20. Type "This is a reply" and tap the send button.
21. Verify the reply message appears in the conversation with a reply reference to "Hello from the CLI".
22. Swipe right on the emoji message "🎉".
23. Verify the reply composer bar shows a reference to the emoji.
24. Tap the cancel reply button to dismiss without sending.
25. Verify the reply composer bar disappears.

### Long press — context menu on text message

26. Long-press on the CLI text message "Hello from the CLI" (duration ≥ 0.3s).
27. Verify the context menu appears with at least these options:
    - "Reply"
    - "Copy"
28. Tap "Copy" in the context menu.
29. Read the simulator pasteboard and verify it contains "Hello from the CLI".
30. Verify the context menu dismisses and returns to the conversation.

### Long press — context menu on emoji message

31. Long-press on the emoji message "🎉".
32. Verify the context menu appears with "Reply" and "Copy".
33. Tap "Copy".
34. Read the pasteboard and verify it contains "🎉".

### Long press — context menu reply action

35. Long-press on the CLI text message "Hello from the CLI".
36. Tap "Reply" in the context menu.
37. Verify the reply composer bar appears referencing "Hello from the CLI".
38. Tap the cancel reply button to dismiss.

### Single tap — link in text message

39. Tap on the URL "https://example.com" within the message "Check out https://example.com for details".
40. Verify the link opens — either Safari opens or an in-app browser/sheet appears with example.com.
41. Navigate back to the conversation if needed.

### Single tap — blurred incoming photo

42. Scroll to the incoming photo from the CLI. It should be blurred by default with a "Tap pic to reveal" overlay.
43. Single-tap the blurred photo.
44. Verify the photo is revealed (blur removed). If the "Reveal" education sheet appears, dismiss it with "Got it".

### Single tap — revealed photo (no action)

45. Single-tap the now-revealed photo again.
46. Verify nothing happens — the photo stays revealed, no navigation or context menu appears. The single tap should be a no-op on a revealed photo.

### Long press — context menu on photo

47. Long-press on the revealed incoming photo.
48. Verify the context menu appears with "Reply", "Save", and "Blur".
49. Dismiss the context menu by tapping the dimmed background (accessibility label: "Dismiss menu").

### Long press — context menu on own outgoing message

50. Long-press on the app's outgoing message "Hello from the app".
51. Verify the context menu appears with "Reply" and "Copy".
52. Dismiss the context menu.

### Avatar tap — incoming message sender

53. Find the sender avatar at the bottom-left of a CLI message group (accessibility label: "View GestureBot's profile").
54. Tap the avatar.
55. Verify a profile view or sheet appears showing the sender's profile information.
56. Dismiss the profile view.

### Reaction indicator tap — opens reactions drawer

57. Double-tap the CLI text "Hello from the CLI" to add a ❤️ reaction (if not already present).
58. From the CLI, also add a reaction to the same message (e.g., 👍).
59. Tap the reaction indicator pill below the message (accessibility label contains "reactions").
60. Verify a reactions drawer/sheet opens showing all reactions with sender attribution.
61. Dismiss the reactions drawer.

### Invite message — single tap opens join flow

62. From the CLI, send a text message with an invite-like slug, or create a second conversation and send its invite as a message. Alternatively, if an invite QR code is visible in the conversation from the setup, tap on it.
63. If an invite message is available, single-tap it.
64. Verify the app opens the join flow or navigates to the invite handling screen.
65. Dismiss or navigate back to the conversation.

### Press state — visual feedback

66. Press and hold (without long-pressing to trigger the context menu — briefly touch) a photo message.
67. Verify the photo shows a visual press effect (e.g., slightly increased blur or dimming). This is a visual-only check — take a screenshot during the press if possible.

## Teardown

Explode the conversation via CLI to clean up.

## Pass/Fail Criteria

- [ ] Double-tap on incoming text toggles ❤️ reaction on
- [ ] Double-tap again toggles ❤️ reaction off
- [ ] Double-tap on emoji message adds ❤️ reaction
- [ ] Double-tap on own outgoing message adds ❤️ reaction
- [ ] Swipe right on a message opens the reply composer bar
- [ ] Reply composer bar shows reference to the original message
- [ ] Sending a reply creates a message with reply context
- [ ] Swipe right on emoji opens reply composer
- [ ] Cancel button dismisses reply composer without sending
- [ ] Long press on text message opens context menu with Reply and Copy
- [ ] Copy action puts message text on the pasteboard
- [ ] Long press on emoji opens context menu with Reply and Copy
- [ ] Copy on emoji puts emoji on the pasteboard
- [ ] Reply from context menu opens reply composer bar
- [ ] Tapping a link in a text message opens the URL
- [ ] Single tap on blurred incoming photo reveals it
- [ ] Single tap on revealed photo is a no-op
- [ ] Long press on photo opens context menu with Reply, Save, and Blur
- [ ] Long press on own message opens context menu with Reply and Copy
- [ ] Tapping sender avatar opens profile view
- [ ] Tapping reaction indicator opens reactions drawer with sender attribution
- [ ] Context menu dismisses when tapping the dimmed background
