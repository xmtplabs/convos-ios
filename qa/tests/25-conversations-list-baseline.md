# Test: Conversations List Baseline

Capture a complete baseline of the Conversations List view capabilities, layout, and interactions. This test documents the current SwiftUI List implementation to verify feature parity after migrating to UICollectionView.

## Purpose

This test serves as a visual and functional baseline for the Conversations List. Run this test BEFORE the UICollectionView migration, capture all screenshots, then run again AFTER migration to verify the new implementation matches exactly.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- No conversations exist (fresh state preferred, or explode all existing).

## Setup

Create a diverse set of conversations to exercise all visual states:

```bash
# Reset CLI state
convos reset
convos init --env dev --force

# Create 6 conversations with different states
# These will be joined from the app and configured

# 1. "Pin A" - will be pinned, unread
convos conversations create "Pin A" --json

# 2. "Pin B" - will be pinned, read, muted
convos conversations create "Pin B" --json

# 3. "Pin C" - will be pinned, read
convos conversations create "Pin C" --json

# 4. "Regular Unread" - normal, unread
convos conversations create "Regular Unread" --json

# 5. "Regular Muted" - normal, muted
convos conversations create "Regular Muted" --json

# 6. "Exploding Soon" - has scheduled explosion
convos conversations create "Exploding Soon" --json

# 7. "Long Name Test With Many Words That Should Truncate Properly" - tests truncation
convos conversations create "Long Name Test With Many Words That Should Truncate Properly" --json
```

Join each conversation from the app via invite deep link. Configure states:
- Pin conversations 1-3
- Mute "Pin B" and "Regular Muted"
- Send unread messages to "Pin A" and "Regular Unread" from CLI
- Schedule explosion on "Exploding Soon"

## Steps

### Screenshot: Pinned section with 3+ conversations (grid layout)

1. Ensure 3 conversations are pinned. Take a screenshot of the conversations list showing the pinned section in grid layout.
2. Verify pinned tiles show:
   - Conversation avatar
   - Conversation name (truncated if long)
   - Unread indicator (blue dot) for unread conversations
   - Muted icon for muted conversations
3. Document accessibility identifiers found on pinned items (pattern: `pinned-conversation-<id>`).

### Screenshot: Pinned section with 2 conversations (horizontal layout)

4. Unpin one conversation so only 2 remain pinned.
5. Take a screenshot showing the pinned section in horizontal layout.
6. Verify the layout switches from grid to horizontal row.

### Screenshot: Pinned section with 1 conversation

7. Unpin another so only 1 remains pinned.
8. Take a screenshot showing single pinned item centered.

### Note: Pinned section scroll behavior

The current SwiftUI List implementation has a parallax/scale/opacity effect when scrolling past the pinned section. This is a limitation of the current implementation, not a desired behavior. The UICollectionView migration should allow the pinned section to scroll naturally with the rest of the list without these effects.

### Screenshot: Conversation list items

12. Take a screenshot focusing on the unpinned conversation list items.
13. Verify each list item shows:
    - Conversation avatar (56x56)
    - Conversation name (bold if unread)
    - Subtitle with relative date + last message preview
    - Unread indicator (circle) on right
    - Muted icon if muted
    - Explosion countdown badge if scheduled
14. Document accessibility identifiers (pattern: `conversation-list-item-<id>`).

### Screenshot: List item with explosion countdown

15. Locate "Exploding Soon" which has a scheduled explosion.
16. Take a close-up screenshot showing the explosion countdown badge.

### Screenshot: List item with long name

17. Locate the conversation with the very long name.
18. Verify the name truncates with ellipsis on a single line.

### Swipe actions - leading edge (swipe right)

19. On a conversation where the user is the creator, swipe RIGHT to reveal leading actions.
20. Take a screenshot showing:
    - Delete button (red/caution color, trash icon)
    - Explode button (inverted background color, burst icon)
21. Verify button accessibility labels: "Delete conversation", "Explode conversation".

### Swipe actions - leading edge (non-creator)

22. On a conversation where the user is NOT the creator, swipe RIGHT.
23. Verify only Delete button appears (no Explode button).
24. Take a screenshot.

### Swipe actions - trailing edge (swipe left)

25. Swipe LEFT on an unread conversation.
26. Take a screenshot showing:
    - Mark as read button (inverted background, checkmark.message.fill icon)
    - Mute button (purple color, bell.slash.fill icon)
27. Verify accessibility labels: "Mark as read", "Mute".

28. Swipe LEFT on a read, unmuted conversation.
29. Take a screenshot showing:
    - Mark as unread button (message.badge.fill icon)
    - Mute button
30. Verify accessibility label: "Mark as unread".

31. Swipe LEFT on a muted conversation.
32. Verify the Mute button shows "Unmute" (bell.fill icon) instead.

### Context menu - long press

33. Long-press on an unpinned, unmuted, read conversation.
34. Take a screenshot of the context menu showing all options:
    - ControlGroup with: Fav, Unread, Mute (icon buttons)
    - Explode (if creator) - "For everyone"
    - Delete - "For me"
35. Document accessibility identifiers:
    - `context-menu-pin` (on the ControlGroup)
    - `context-menu-explode`
    - `context-menu-delete`

36. Long-press on a pinned (favorited), muted, unread conversation.
37. Take a screenshot showing the context menu with toggled states:
    - ControlGroup with: Unfav, Read, Unmute

### Context menu on pinned tile

38. Long-press on a pinned tile in the pinned section.
39. Verify the same context menu appears.
40. Take a screenshot.

### Delete confirmation dialog

41. Swipe right on a conversation and tap Delete.
42. Take a screenshot of the confirmation dialog.
43. Verify dialog shows: "This convo will be deleted immediately." with Delete and Cancel buttons.
44. Tap Cancel to dismiss.

### Selection highlighting

45. On iPad or in split view, tap a conversation to select it.
46. Take a screenshot showing the selected conversation with highlight.
47. Verify the selected row has a different background color (`.colorFillMinimal`).

### Empty state - no conversations

48. Explode all conversations to reach empty state.
49. Take a screenshot of the empty conversations list.
50. Verify the empty state CTA appears with "Start" and "Join" options.

### Filter menu

51. Create at least one conversation again.
52. Tap the filter button in the top toolbar.
53. Take a screenshot of the filter menu showing:
    - All
    - Unread
    - Exploding
    - Pending invites
54. Verify the filter button changes appearance when a filter is active.

### Filtered empty state

55. Apply the "Unread" filter when no conversations are unread.
56. Take a screenshot of the filtered empty state.
57. Verify it shows a message about no matching conversations and a "Show all" button.

### Toolbar buttons

58. Take a screenshot showing the bottom toolbar with:
    - Scan button (viewfinder icon)
    - Compose button (square and pencil icon)
59. Document accessibility identifiers: `scan-button`, `compose-button`.

60. Take a screenshot showing the top toolbar with:
    - Settings button (Convos logo)
    - Filter button
61. Document accessibility identifiers: `app-settings-button`, `filter-button`.

## Teardown

Explode all test conversations via CLI to clean up.

## Pass/Fail Criteria

### Pinned Section
- [ ] Grid layout displays when 3+ conversations are pinned (rows of 3)
- [ ] Horizontal layout displays when < 3 conversations are pinned
- [ ] Single pinned item is centered
- [ ] Pinned tiles show avatar and name
- [ ] Long names truncate with ellipsis on pinned tiles
- [ ] Pinned section scrolls naturally with the list (no parallax - UICollectionView goal)

### List Items
- [ ] List items show avatar, name, subtitle (date + message), indicators
- [ ] Unread indicator displays for unread conversations
- [ ] Muted icon displays for muted conversations
- [ ] Explosion countdown badge displays for scheduled explosions
- [ ] Long names truncate properly
- [ ] Bold font weight for unread conversation names

### Swipe Actions
- [ ] Leading swipe reveals Delete button
- [ ] Leading swipe reveals Explode button (creator only)
- [ ] Trailing swipe reveals Mark as read/unread button
- [ ] Trailing swipe reveals Mute/Unmute button
- [ ] Swipe buttons have correct icons and colors

### Context Menu
- [ ] Long-press opens context menu on list items
- [ ] Long-press opens context menu on pinned tiles
- [ ] Context menu ControlGroup shows Fav/Unfav based on pin state
- [ ] Context menu ControlGroup shows Mute/Unmute based on state
- [ ] Context menu ControlGroup shows Read/Unread based on state
- [ ] Context menu shows "Delete - For me" option
- [ ] Context menu shows "Explode - For everyone" option (creator only)
- [ ] Context menu preview shows rounded rectangle shape

### Empty States
- [ ] Empty state CTA appears when no conversations exist
- [ ] Filtered empty state appears with "Show all" button

### Filters
- [ ] Filter menu accessible from toolbar
- [ ] Filter button appearance changes when filter is active
- [ ] All/Unread/Exploding/Pending filters work correctly

### Selection
- [ ] Selected conversation has visible highlight
- [ ] Selection persists during navigation

### Accessibility
- [ ] All interactive elements have accessibility identifiers
- [ ] Pinned items: `pinned-conversation-<id>`
- [ ] List items: `conversation-list-item-<id>`
- [ ] Toolbar buttons: `app-settings-button`, `filter-button`, `scan-button`, `compose-button`

## Screenshots Captured

All screenshots saved to `qa/reports/baseline-screenshots/`:

| Screenshot | Description |
|------------|-------------|
| `01-pinned-grid-4items.png` | Pinned section with 4 items in grid layout (2 rows) |
| `02-pinned-row-3items.png` | Pinned section with 3 items in single row |
| `03-pinned-horizontal-2items.png` | Pinned section with 2 items in horizontal layout |
| `04-context-menu-pinned-tile.png` | Context menu on pinned tile (Unfav/Unread/Mute + Explode + Delete) |
| `05-pinned-single-1item.png` | Pinned section with 1 item (centered) |
| `06-context-menu-list-item.png` | Context menu on unpinned list item (Fav/Unread/Mute + Explode + Delete) |
| `07-swipe-trailing-actions.png` | Trailing swipe actions (Mute purple, Mark as unread black) |
| `08-swipe-leading-actions.png` | Leading swipe actions (Delete red, Explode black) |
| `09-filter-menu.png` | Filter menu (All/Unread/Exploding/Pending invites) |
| `10-context-menu-pending-invite.png` | Context menu on pending invite (Delete only) |

### Not captured (would need additional setup):
- Explosion countdown badge
- Unread/muted indicators on list items
- Long name truncation
- Delete confirmation dialog
- Empty state CTA
- Filtered empty state
- Selection highlighting (iPad/split view)

## Accessibility Improvements Needed

Document any UI elements that were hard to find during testing:

| Element | Issue | Recommendation |
|---------|-------|----------------|
| (fill during test) | | |

## Performance Notes

Document any scroll performance issues observed:
- Frame drops during scroll
- Hitches when loading cells
- Lag when pinned section animates

This information will help verify the UICollectionView migration improves performance.
