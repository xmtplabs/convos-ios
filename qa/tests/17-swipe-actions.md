# Test: Swipe Actions (Mark Read/Unread)

Verify that conversations can be marked as read or unread via swipe actions on the conversations list.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- At least one conversation exists with unread messages, and at least one conversation is fully read.

## Setup

Create 2 conversations via CLI and join both from the app. Name them "Swipe Read" and "Swipe Unread".

1. In "Swipe Read", open the conversation in the app so it becomes read.
2. In "Swipe Unread", send a message from the CLI. Do NOT open it — leave it unread.
3. Navigate to the conversations list.

## Steps

### Mark as read via swipe

4. On "Swipe Unread" (which has an unread indicator), swipe left to reveal trailing actions.
5. Verify a "Mark as read" button appears (accessibility label: "Mark as read").
6. Tap the "Mark as read" button.
7. Verify the unread indicator disappears from "Swipe Unread".

### Mark as unread via swipe

8. On "Swipe Read" (which is fully read and has no unread indicator), swipe left to reveal trailing actions.
9. Verify a "Mark as unread" button appears (accessibility label: "Mark as unread").
10. Tap the "Mark as unread" button.
11. Verify an unread indicator appears on "Swipe Read".

### Toggle back

12. On "Swipe Read" (now marked unread), swipe left again.
13. Verify the button now says "Mark as read" (since it's currently unread).
14. Tap it to mark as read.
15. Verify the unread indicator disappears.

### Mark as read via context menu

16. Send a new message from the CLI to "Swipe Unread" so it has a new unread indicator.
17. Long-press on "Swipe Unread" to open the context menu.
18. Verify a "Mark as Read" option appears (accessibility identifier: `context-menu-toggle-read`).
19. Tap it.
20. Verify the unread indicator disappears.

### Mark as unread via context menu

21. Long-press on "Swipe Unread" (now read) to open the context menu.
22. Verify a "Mark as Unread" option appears.
23. Tap it.
24. Verify the unread indicator appears again.

## Teardown

Explode both conversations via CLI.

## Pass/Fail Criteria

- [ ] Swiping left reveals a "Mark as read" button for unread conversations
- [ ] Tapping "Mark as read" removes the unread indicator
- [ ] Swiping left reveals a "Mark as unread" button for read conversations
- [ ] Tapping "Mark as unread" adds an unread indicator
- [ ] Mark as read is available via context menu
- [ ] Mark as unread is available via context menu
