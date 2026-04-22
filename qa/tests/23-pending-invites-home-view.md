# Test: Pending Invites in Home View

Verify that pending invite conversations (accepted but not yet approved) appear in the home view conversations list, show "Verifying" status, and can be tapped to see the verifying state.

> **Single-inbox model (C10).** Pending-invite enumeration in the home view is now backed by `PendingInviteRepository.allPendingInvites()` (no clientId argument) rather than a multi-inbox aware enumeration. With one inbox per user the result is a single grouping. The home-view UX is unchanged.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- At least one existing conversation is in the conversations list (so the empty CTA is not shown).

## Setup

Use the CLI to create a conversation named "Pending Test Group" with a profile name for the CLI user. Generate an invite URL and capture it. **Do not process join requests** — this test relies on the invite staying in a pending state.

## Steps

### Accept the invite without approval

1. Open the invite URL in the simulator as a deep link.
2. The app should show the conversation view and transition to the "Verifying" onboarding state. Wait for the `InviteAcceptedView` to appear — verify by looking for the accessibility label containing "Verifying".
3. After a few seconds, a description should appear: "See and send messages after your access is verified"

### Verify the close button dismisses without a confirmation dialog

4. Tap the close button in the top-left toolbar to dismiss the new conversation view.
5. The app should dismiss directly back to the conversations list — no confirmation dialog should appear (the old "This convo will appear on your home screen after someone approves you" dialog has been removed).

### Verify pending conversation appears in home view

6. The conversations list should now include the pending invite conversation.
7. Find the conversation list item — it should have an accessibility identifier matching `conversation-list-item-draft-*` (the ID has a `draft-` prefix).
8. Verify the conversation's subtitle shows a relative timestamp followed by "Verifying" (e.g., "1h · Verifying").
9. The conversation should not show an unread indicator dot.
10. The conversation should not show a muted icon.

### Tap pending conversation to see invite accepted state

11. Tap the pending conversation in the list.
12. The app should open the conversation detail view.
13. Verify the `InviteAcceptedView` is displayed — look for the accessibility label containing "Verifying".
14. Navigate back to the conversations list.

### Verify swipe actions are restricted for pending conversations

15. Swipe right (leading edge) on the pending conversation to reveal swipe actions.
16. The "Delete" action should be available.
17. The "Explode" action should NOT be available (user is not the creator).
18. Dismiss the swipe actions.
19. Swipe left (trailing edge) on the pending conversation.
20. The "Mark as read/unread" and "Mute" actions should NOT appear for a pending invite.

### Verify context menu is restricted for pending conversations

21. Long-press on the pending conversation to open the context menu.
22. The "Delete" option should be present.
23. The pin/read/mute control group should NOT be present.
24. The "Explode" option should NOT be present.
25. Dismiss the context menu (tap elsewhere or press Escape).

### Verify pending invites filter

26. Tap the filter button (accessibility identifier: `filter-button`).
27. A menu should appear with filter options including "Pending invites".
28. Tap "Pending invites".
29. Verify only the pending invite conversation is shown in the list.
30. Other regular conversations should be hidden.
31. Verify the filter button indicates an active filter state.

### Clear the filter and verify all conversations return

32. Tap the filter button again.
33. Tap "All" to clear the filter.
34. Verify all conversations are shown again, including the pending invite.

### Approve the invite and verify transition

35. From the CLI, process the join request for the conversation. Use `--watch --timeout 30`.
36. Wait for the join to complete. Start the `process-join-requests` in the background and look for the quickname pill in the app (per ephemeral UI rules in RULES.md).
37. After the join is processed, the conversation should automatically transition in the home view — the "Verifying" subtitle should be replaced by normal conversation content (a timestamp or message preview).
38. The conversation's list item ID should change from `conversation-list-item-draft-*` to a non-draft ID.
39. If the pending invites filter is active, the conversation should disappear from the filtered list (it's no longer pending).

### Verify the conversation works normally after approval

40. Tap the conversation in the list.
41. The `InviteAcceptedView` should no longer be shown.
42. Use the CLI to send a message like "You're approved!".
43. Verify the message appears in the app.

## Teardown

Explode the conversation via CLI. Navigate back to the conversations list and verify it disappears.

## Pass/Fail Criteria

- [ ] Opening an invite URL shows the "Verifying" state in the conversation view
- [ ] Close button dismisses directly without a confirmation dialog
- [ ] Pending invite conversation appears in the home view conversations list
- [ ] Pending conversation subtitle shows relative timestamp and "Verifying" (e.g., "1h · Verifying")
- [ ] Pending conversation does not show unread or muted indicators
- [ ] Tapping the pending conversation opens it and shows `InviteAcceptedView`
- [ ] Leading swipe shows "Delete" but not "Explode" for pending invites
- [ ] Trailing swipe shows no actions (no read/unread, no mute) for pending invites
- [ ] Context menu shows only "Delete" for pending invites (no pin/read/mute/explode)
- [ ] "Pending invites" filter option appears in the filter menu
- [ ] Selecting "Pending invites" filter shows only pending invite conversations
- [ ] Clearing filter restores all conversations
- [ ] After approval, conversation transitions from pending to normal state in the list
- [ ] After approval, conversation detail no longer shows `InviteAcceptedView`
- [ ] Messages can be exchanged after the invite is approved
