# Test: Conversation Filters

Verify the unread filter in the conversations list — filtering, clearing, empty state, and behavior when new messages arrive while filtered.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- At least 3 conversations exist with the app as a member. At least one should have unread messages, and at least one should be fully read.

## Setup

Create 3 conversations via CLI and join all from the app. Name them "Filter Read", "Filter Unread A", and "Filter Unread B".

1. In "Filter Read", send a message from the CLI. Open the conversation in the app so it becomes read.
2. In "Filter Unread A", send a message from the CLI. Do NOT open it in the app — leave it unread.
3. In "Filter Unread B", send a message from the CLI. Do NOT open it in the app — leave it unread.
4. Navigate to the conversations list and verify all 3 conversations are visible. "Filter Unread A" and "Filter Unread B" should show unread indicators.

## Steps

### Apply unread filter

5. Tap the filter button (accessibility identifier: `filter-button`).
6. A menu should appear with filter options. Tap "Unread".
7. Verify only conversations with unread messages are shown — "Filter Unread A" and "Filter Unread B" should be visible.
8. Verify "Filter Read" is NOT visible in the list.
9. Verify the filter button visually indicates an active filter (filled/highlighted state).

### Read a conversation while filtered

10. Tap on "Filter Unread A" to open it (this marks it as read).
11. Navigate back to the conversations list.
12. Verify the filter updates — "Filter Unread A" should no longer appear (it's now read and the unread filter is active).
13. Only "Filter Unread B" should remain visible.

### New message while filtered

14. With the unread filter still active, use the CLI to send a new message to "Filter Read" (which was previously read and hidden by the filter).
15. Wait a few seconds for the message to arrive.
16. Verify "Filter Read" now appears in the filtered list (it has a new unread message).

### Empty filter state

17. Open "Filter Unread B" to mark it as read.
18. Open "Filter Read" to mark it as read.
19. Navigate back to the conversations list with the unread filter still active.
20. Verify an empty state message appears (e.g., "No unread convos") since no conversations have unread messages.

### Clear filter

21. Tap the filter button again.
22. Tap "All" to clear the filter.
23. Verify all conversations are shown again — "Filter Read", "Filter Unread A", and "Filter Unread B" should all be visible.
24. Verify the filter button returns to its default (non-highlighted) state.

### Filter persistence during session

25. Apply the unread filter again by tapping the filter button and selecting "Unread".
26. Navigate away — open app settings (tap the settings button).
27. Navigate back to the conversations list.
28. Verify the unread filter is still active (check the filter button state and the filtered results).

## Teardown

Clear the filter back to "All". Explode all test conversations via CLI.

## Pass/Fail Criteria

- [ ] Filter button opens a menu with "All" and "Unread" options
- [ ] Selecting "Unread" shows only conversations with unread messages
- [ ] Read conversations are hidden when unread filter is active
- [ ] Filter button indicates active filter state
- [ ] Reading a conversation while filtered removes it from the filtered list
- [ ] New unread message causes a conversation to appear in the filtered list
- [ ] Empty state message appears when no conversations match the filter
- [ ] Clearing the filter restores all conversations
- [ ] Filter state persists during the session (survives navigation)
