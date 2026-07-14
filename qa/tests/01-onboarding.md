# Test: Fresh Onboarding Flow

Verify that a first-time user is offered the first-launch "Hello / My name is" profile setup sheet, can complete it, and then creates a conversation without being re-prompted for a profile.

## Prerequisites

- The app is installed on the simulator.
- The simulator must be erased to ensure no prior app state exists. Run `xcrun simctl erase booted`, then reinstall and launch the app.
- No other device's identity may exist in the iCloud-synced keychain backup — an erased simulator satisfies this. If a "Pair device" sheet appears instead of the profile sheet, the simulator was not fully erased.

## Steps

### Launch into first-launch profile setup

1. Launch the app. It lands on the home shell (Chats tab, compose button visible).
2. The "Hello / My name is" profile setup sheet self-presents over the Chats tab. Poll for `profile-setup-name-field` with `sim_wait_for_element` (timeout: 20s — the sheet waits for the inbox and global profile load on a cold fresh install). It presents on every launch while the user has no name or photo set — including users who completed onboarding before this sheet existed — and cannot be swiped away while "Come in" is disabled.
3. Verify the sheet's empty state:
   - A name field (`profile-setup-name-field`) with placeholder "Name", an avatar on the left (`profile-setup-avatar`) showing the `person.crop.circle.fill` icon, and photo/camera buttons on the right (`profile-setup-photo-button`, `profile-setup-camera-button`).
   - The "I agree to Convos Privacy & Terms" row with a toggle (`profile-setup-terms-toggle`), ON by default.
   - A "Come in" button (`profile-setup-save-button`), gray/disabled while the name field is empty (or if the toggle is turned off).

### Complete profile setup

4. Enter a display name like "QA Tester" in `profile-setup-name-field`. The avatar switches from the placeholder icon to a monogram of the typed name.
5. (Optional) Tap `profile-setup-avatar` or `profile-setup-photo-button` to pick a profile photo from the library — photo behavior is covered in depth by test 19.
6. Tap `profile-setup-save-button` ("Come in"). The sheet saves the global profile and dismisses.

### Create a conversation

7. Tap the compose button to start a new conversation.
8. The app presents the new conversation view. Verify the invite QR code and message input are visible.

### No in-conversation profile prompt

9. Verify the legacy "Add your name and pic" prompt (`setup-profile-button`) does **not** appear — the profile was already set on the first-launch sheet.

### Notification permission

10. A custom notification prompt appears with `notification-permission-button` ("Notify me of new messages"). Tap it.
11. The system notification permission dialog appears (Allow / Don't Allow). Tap either option.
12. The conversation view should be fully usable.

### Verify post-onboarding state

13. Navigate back to the conversations list.
14. Verify the conversation you created appears in the list.

## Dismissal gating (01b)

The sheet cannot be swiped away while "Come in" is disabled, and it re-presents on every launch until a profile is set:

1. On a fresh install with the name field empty, try to swipe the sheet down — it must bounce back (interactive dismissal is disabled while the save gate is unsatisfied).
2. Type a name (terms toggle already on) so "Come in" enables, then swipe the sheet down without saving. Dismissal now succeeds.
3. Create a conversation. The legacy `setup-profile-button` prompt appears in the conversation's bottom bar as the fallback (quick-edit name field → "Profile saved" pill → notification prompt).
4. Relaunch the app without ever saving a profile — the sheet self-presents again (it gates on the profile being unset, not on having been shown before). Once a name or photo is saved, it stops appearing.

## Pass/Fail Criteria

- [ ] App launches to the home shell after simulator erase
- [ ] First-launch "Hello / My name is" sheet self-presents with name field, terms toggle, and "Come in" button
- [ ] "Come in" is disabled until a name is entered and the terms toggle is on
- [ ] Profile can be set via the sheet; the avatar shows a live monogram while typing
- [ ] Conversation can be created after dismissal
- [ ] The in-conversation profile prompt does not appear after completing the sheet
- [ ] Notification permission step is shown in the first conversation
- [ ] Onboarding completes and the conversation is usable
- [ ] Conversation appears in the conversations list with the correct name
