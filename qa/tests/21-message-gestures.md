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

### Swipe right — only swiped message moves in a group

26. From the app, send two more text messages rapidly: "Group msg A" and "Group msg B" so they appear in the same sender group as "Hello from the app".
27. Swipe right on the middle outgoing message in the group (not the first or last). Use a slow swipe (≥60pt horizontal, long duration) so the reply arrow becomes visible mid-swipe.
28. Take a screenshot while the swipe gesture is active (before the finger lifts).
29. Verify that only the swiped message is offset to the right with a reply arrow visible to its left. The other messages in the group must remain in their original positions with no arrow or offset.
30. Complete the swipe or let it cancel. Dismiss the reply composer if it appeared.

### Long press — context menu on text message

31. Long-press on the CLI text message "Hello from the CLI" (duration ≥ 0.3s).
32. Verify the context menu appears with at least these options:
    - "Reply"
    - "Copy"
33. Tap "Copy" in the context menu.
34. Read the simulator pasteboard and verify it contains "Hello from the CLI".
35. Verify the context menu dismisses and returns to the conversation.

### Long press — context menu works on every message in a group

36. Using the outgoing message group ("Hello from the app", "Group msg A", "Group msg B"), long-press on the first message in the group ("Hello from the app").
37. Verify the context menu appears showing "Hello from the app" as the source bubble.
38. Dismiss the context menu.
39. Long-press on the middle message ("Group msg A").
40. Verify the context menu appears showing "Group msg A" as the source bubble.
41. Dismiss the context menu.
42. Long-press on the last message ("Group msg B").
43. Verify the context menu appears showing "Group msg B" as the source bubble.
44. Dismiss the context menu.

### Long press — context menu on emoji message

45. Long-press on the emoji message "🎉".
46. Verify the context menu appears with "Reply" and "Copy".
47. Tap "Copy".
48. Read the pasteboard and verify it contains "🎉".

### Long press — context menu reply action

49. Long-press on the CLI text message "Hello from the CLI".
50. Tap "Reply" in the context menu.
51. Verify the reply composer bar appears referencing "Hello from the CLI".
52. Tap the cancel reply button to dismiss.

### Single tap — link in text message

53. Tap on the URL "https://example.com" within the message "Check out https://example.com for details".
54. Verify the link opens — either Safari opens or an in-app browser/sheet appears with example.com.
55. Navigate back to the conversation if needed.

### Single tap — incoming photo (no action)

56. Scroll to the incoming photo from the CLI. It renders immediately as a full-width image, unblurred, with no "Tap pic to reveal" overlay.
57. Single-tap the photo.
58. Verify nothing happens — the photo stays as-is, no navigation or context menu appears. A single tap on a photo is a no-op.

### Long press — context menu on photo

59. Long-press on the incoming photo.
60. Verify the context menu appears with "Reply", "Save", and "Share", and no "Blur" or "Reveal" action.
61. Dismiss the context menu by tapping the dimmed background (accessibility label: "Dismiss menu").

### Long press — context menu on own outgoing message

62. Long-press on the app's outgoing message "Hello from the app".
63. Verify the context menu appears with "Reply" and "Copy".
64. Dismiss the context menu.

### Avatar tap — incoming message sender

65. Find the sender avatar at the bottom-left of a CLI message group (accessibility label: "View GestureBot's profile").
66. Tap the avatar.
67. Verify a profile view or sheet appears showing the sender's profile information.
68. Dismiss the profile view.

### Reaction indicator tap — opens reactions drawer

69. Double-tap the CLI text "Hello from the CLI" to add a ❤️ reaction (if not already present).
70. From the CLI, also add a reaction to the same message (e.g., 👍).
71. Tap the reaction indicator pill below the message (accessibility label contains "reactions").
72. Verify a reactions drawer/sheet opens showing all reactions with sender attribution.
73. Dismiss the reactions drawer.

### Invite message — single tap opens join flow

74. From the CLI, send a text message with an invite-like slug, or create a second conversation and send its invite as a message. Alternatively, if an invite QR code is visible in the conversation from the setup, tap on it.
75. If an invite message is available, single-tap it.
76. Verify the app opens the join flow or navigates to the invite handling screen.
77. Dismiss or navigate back to the conversation.

### Press state — visual feedback

78. Press and hold (without long-pressing to trigger the context menu — briefly touch) a photo message.
79. Verify the photo shows a visual press effect (e.g., slightly increased blur or dimming). This is a visual-only check — take a screenshot during the press if possible.

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
- [ ] Swiping on one message in a group only moves that message (others stay in place)
- [ ] Long press works on every message in a group (first, middle, and last)
- [ ] Long press on text message opens context menu with Reply and Copy
- [ ] Copy action puts message text on the pasteboard
- [ ] Long press on emoji opens context menu with Reply and Copy
- [ ] Copy on emoji puts emoji on the pasteboard
- [ ] Reply from context menu opens reply composer bar
- [ ] Tapping a link in a text message opens the URL
- [ ] Single tap on an incoming photo is a no-op
- [ ] Long press on photo opens context menu with Reply, Save, and Share, and no Blur or Reveal action
- [ ] Long press on own message opens context menu with Reply and Copy
- [ ] Tapping sender avatar opens profile view
- [ ] Tapping reaction indicator opens reactions drawer with sender attribution
- [ ] Context menu dismisses when tapping the dimmed background
