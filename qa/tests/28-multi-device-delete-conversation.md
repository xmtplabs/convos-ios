# Test: Multi-Device Delete and Explode Conversation Sync

Verify that deleting and exploding conversations on one paired device correctly removes them from the other device.

## Prerequisites

- Two iOS Simulators are available, referred to as **Device A** and **Device B**.
- Both devices have been paired via the Vault pairing flow (test 26 or equivalent).
- Both devices are past onboarding and showing the conversations list.
- Both simulators have Reduce Motion enabled and animations disabled (per RULES.md simulator preparation).
- At least two conversations exist on both devices (e.g., from test 26 seed data, test 27, or prior setup).

## Setup

### Verify or create test conversations

If running after test 26 with seed data, conversations are already present on both devices. Otherwise:

1. On **Device A**, use the seed feature (Settings → Debug → Seed Conversations) to create 2 conversations, or manually create them by tapping compose (`compose-button`), sending a message in each, and navigating back.
2. Wait for both conversations to appear on **Device B** (up to 30 seconds each). Verify with `sim_find_elements`.
3. Confirm both devices show both conversations in their lists.

## Steps

### Part 1: Delete for me

#### Delete a conversation on Device A

4. On **Device A**, long-press on the first conversation in the conversations list to open the context menu.
5. Tap "Delete" (`context-menu-delete`) in the context menu. This is the "Delete — For me" option.
6. A confirmation action sheet should appear with title "This convo will be deleted immediately."
7. Tap "Delete" in the confirmation sheet.
8. Verify the conversation is removed from Device A's conversations list. Use `sim_find_elements` to confirm it is gone.

#### Verify the conversation is also removed from Device B

9. On **Device B**, check the conversations list. The deleted conversation should disappear within 30 seconds — "Delete for me" on a paired device should propagate to all of the user's devices.
10. If the conversation is still visible after a few seconds, wait and check periodically with `sim_find_elements`.
11. Verify the conversation is no longer in Device B's conversations list.

### Part 2: Explode for everyone

#### Create a fresh conversation for the explode test

12. On **Device A**, create a new conversation by tapping compose, sending a message like "This will be exploded", and navigating back.
13. Wait for the new conversation to appear on **Device B** (up to 30 seconds). Verify with `sim_find_elements`.

#### Explode the conversation from Device A

14. On **Device A**, tap the new conversation to open it.
15. Tap the conversation info button at the top of the conversation view (`conversation-info-button` — the conversation name/info area at the top center). This opens the conversation info/details drawer.
16. Scroll down if needed to find the explode option. Look for the "Explode Now" button or the explode sheet trigger. The explode flow uses the `ExplodeConvoSheet` which appears as an overlay.
17. Long-press the "Explode Now" button (hold for at least 1.5 seconds — this is a hold-to-confirm button with `HoldToConfirmPrimitiveStyle`, duration 1.5s). Use `sim_ui_tap` with `duration: 1.6` on the button coordinates. The button should transition through `exploding` → `exploded` states.
18. After the explosion animation, verify the `conversation.exploded` event fires using `sim_log_events` with `event_filter="conversation.exploded"`.
19. The app should navigate back to the conversations list or show that the conversation is destroyed. Verify the exploded conversation no longer appears in Device A's conversations list.

#### Verify the conversation is removed from Device B

20. On **Device B**, check the conversations list. The exploded conversation should disappear within a few seconds as the XMTP SDK processes the group removal.
21. If the conversation is still visible, wait up to 30 seconds and check periodically. The conversation stream should process the explosion event.
22. Verify the exploded conversation is no longer in Device B's conversations list using `sim_find_elements`.

### Part 3: Verify remaining conversations

23. On **Device A**, verify that the second conversation ("Beta") still appears in the conversations list.
24. On **Device B**, verify the same — the second conversation should still be present and unaffected.

## Teardown

No specific cleanup needed. Remaining conversations can be left for subsequent tests or the simulators can be erased.

## Pass/Fail Criteria

- [ ] "Delete for me" confirmation sheet appears before deletion
- [ ] "Delete for me" removes the conversation from Device A's conversations list
- [ ] "Delete for me" also removes the conversation from Device B within 30 seconds
- [ ] Exploded conversation is removed from Device A after the explosion animation
- [ ] `conversation.exploded` event fires on Device A
- [ ] Exploded conversation is removed from Device B within 30 seconds
- [ ] Remaining conversations are unaffected on both devices

## Notes

- "Delete for me" deletes the conversation identity (inbox). Since both devices share the same keys via the Vault, the deletion should propagate to the other device — either via a Vault message signaling the deletion, or because the XMTP inbox is destroyed network-wide.
- "Explode" is a network-wide operation — it destroys the conversation for all participants across all devices. The XMTP SDK propagates this to all group members.
- The explode button uses `HoldToConfirmPrimitiveStyle` requiring a sustained press of 1.5 seconds. Use `sim_ui_tap` with `duration: 1.6` on the button coordinates.
- The `ExplodeConvoSheet` appears as an overlay (not a system sheet), so dismissing it may require tapping outside the card area.
- After exploding, Device B should receive the removal via the conversation stream or message stream.

## Accessibility Improvements Needed

- The `ExplodeConvoSheet`'s "Explode Now" hold-to-confirm button does not have a dedicated accessibility identifier — it is a `Button` inside the sheet. Adding `accessibilityIdentifier("explode-now-button")` would make it easier to target.
- The delete confirmation action sheet uses system `UIAlertController` — its "Delete" button can be found by label but lacks a custom accessibility identifier.
