# Test: Pin and Unpin Conversation

Verify that conversations can be pinned and unpinned, and that pinned conversations appear in the dedicated pinned section.

## Prerequisites

- The app is running and past onboarding.
- There are at least two conversations in the conversations list. Create them via the app or by joining CLI-created conversations.

## Steps

### Pin a conversation

1. From the conversations list, long-press on a conversation to open the context menu.
2. Look for a "Pin" option in the context menu.
3. Tap "Pin".
4. Verify the conversation moves to the pinned section at the top of the conversations list. The pinned section should be visually distinct from the unpinned list.

### Verify pinned section

5. Take a screenshot and verify the pinned conversation appears in the pinned section area at the top.
6. The pinned conversation should show its avatar and possibly its name in a compact format.

### Unpin a conversation

7. Long-press on the pinned conversation (in the pinned section or via the context menu).
8. Look for an "Unpin" option.
9. Tap "Unpin".
10. Verify the conversation moves back to the unpinned list and the pinned section adjusts accordingly.

### Pin limit (if applicable)

11. If there's a limit on pinned conversations, try pinning more than the allowed number and verify appropriate feedback is shown.

## Teardown

Unpin any pinned conversations to restore the default state.

## Pass/Fail Criteria

- [ ] Conversation can be pinned from the context menu
- [ ] Pinned conversation appears in the pinned section at the top
- [ ] Pinned section is visually distinct from the unpinned list
- [ ] Conversation can be unpinned
- [ ] Unpinned conversation returns to the normal list
