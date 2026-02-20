# Test: Pin and Unpin Conversations

Verify pinning, unpinning, pin persistence, multiple pins, muted icon on pinned tiles, empty pinned section behavior, and title truncation.

## Prerequisites

- The app is running and past onboarding.
- At least 3 conversations exist in the conversations list. Create them by joining CLI-created conversations via invite, or by creating them from the app.

## Setup

Ensure at least 3 conversations are visible in the conversations list and none are currently pinned. If any are pinned, unpin them first.

Name the conversations distinctly so they can be identified (e.g., "Pin Test A", "Pin Test B", "Pin Test C"). At least one should have a very long name (30+ characters) like "Pin Test With An Extremely Long Conversation Name That Should Truncate".

## Steps

### Pin a conversation

1. From the conversations list, long-press on "Pin Test A" to open the context menu.
2. Tap "Pin" (accessibility identifier: `context-menu-pin`).
3. Verify the conversation moves to a pinned section at the top of the list.
4. The pinned section should be visually distinct — pinned items appear as compact tiles with avatars (accessibility identifier pattern: `pinned-conversation-<id>`).

### Pin multiple conversations

5. Long-press on "Pin Test B" and tap "Pin".
6. Long-press on "Pin Test C" and tap "Pin".
7. Verify all 3 conversations appear in the pinned section.
8. Verify they no longer appear in the unpinned list below.

### Verify muted icon on pinned tile

9. Mute one of the pinned conversations (e.g., "Pin Test B") by swiping right on its pinned tile or via conversation info.
10. Verify a muted icon appears on the pinned tile for "Pin Test B".

### Verify title truncation

11. Pin the conversation with the very long name.
12. Verify its name is truncated in the pinned tile (single line with ellipsis).

### Pin persistence across app restart

13. Kill the app (`xcrun simctl terminate <UDID> org.convos.ios-preview`).
14. Relaunch the app.
15. Verify all pinned conversations are still in the pinned section after relaunch.

### Unpin a conversation

16. Long-press on one of the pinned conversations ("Pin Test A") to open the context menu.
17. Tap "Unpin".
18. Verify the conversation moves back to the unpinned list.
19. The pinned section should still show the remaining pinned conversations.

### Empty pinned section

20. Unpin all remaining conversations one by one.
21. Verify the pinned section disappears entirely when no conversations are pinned.

## Teardown

Unpin any remaining pinned conversations. Optionally explode test conversations via CLI.

## Pass/Fail Criteria

- [ ] Conversation can be pinned from the context menu
- [ ] Pinned conversation appears in the pinned section at the top
- [ ] Pinned section is visually distinct (compact tiles with avatars)
- [ ] Multiple conversations can be pinned simultaneously
- [ ] Pinned conversations are removed from the unpinned list
- [ ] Muted icon shows on a pinned tile for a muted conversation
- [ ] Long conversation name truncates on the pinned tile
- [ ] Pins persist across app kill and relaunch
- [ ] Conversation can be unpinned from the context menu
- [ ] Unpinned conversation returns to the unpinned list
- [ ] Pinned section disappears when all conversations are unpinned
