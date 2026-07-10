# Test: Fresh Onboarding Flow

Verify that a first-time user is offered the first-launch "Hello / My name is" profile setup sheet, can complete it, and then creates a conversation without being re-prompted for a profile.

## Prerequisites

- The app is installed on the simulator.
- The simulator must be erased to ensure no prior app state exists. Run `xcrun simctl erase booted`, then reinstall and launch the app.
- No other device's identity may exist in the iCloud-synced keychain backup — an erased simulator satisfies this. If a "Pair device" sheet appears instead of the profile sheet, the simulator was not fully erased.

## Steps

### Launch into first-launch profile setup

1. Launch the app. It lands on the home shell (Chats tab, compose button visible).
2. The "Hello / My name is" profile setup sheet self-presents over the Chats tab. Poll for `profile-setup-name-field` with `sim_wait_for_element` (timeout: 20s — the sheet waits for the inbox and global profile load on a cold fresh install).
3. Verify the sheet's empty state:
   - A name field (`profile-setup-name-field`) with placeholder "Name", an avatar on the left (`profile-setup-avatar`) showing the `person.crop.circle.fill` icon, and photo/camera buttons on the right (`profile-setup-photo-button`, `profile-setup-camera-button`).
   - The "I agree to Convos Privacy & Terms" row with a toggle (`profile-setup-terms-toggle`), OFF by default.
   - A "Come in" button (`profile-setup-save-button`), gray/disabled while the name field is empty or the terms toggle is off.

### Complete profile setup

4. Enter a display name like "QA Tester" in `profile-setup-name-field`. The avatar switches from the placeholder icon to a monogram of the typed name.
5. (Optional) Tap `profile-setup-avatar` or `profile-setup-photo-button` to pick a profile photo from the library — photo behavior is covered in depth by test 19.
6. Turn on `profile-setup-terms-toggle`. The "Come in" button enables.
7. Tap `profile-setup-save-button` ("Come in"). The sheet saves the global profile and dismisses.

### Create a conversation

8. Tap the compose button to start a new conversation.
9. The app presents the new conversation view. Verify the invite QR code and message input are visible.

### No in-conversation profile prompt

10. Verify the legacy "Add your name and pic" prompt (`setup-profile-button`) does **not** appear — the profile was already set on the first-launch sheet.

### Notification permission

11. A custom notification prompt appears with `notification-permission-button` ("Notify me of new messages"). Tap it.
12. The system notification permission dialog appears (Allow / Don't Allow). Tap either option.
13. The conversation view should be fully usable.

### Verify post-onboarding state

14. Navigate back to the conversations list.
15. Verify the conversation you created appears in the list.

## Fallback flow (01b): sheet dismissed without saving

The in-conversation onboarding flow still exists as a fallback. To exercise it:

1. On a fresh install, swipe the first-launch sheet down without saving.
2. Create a conversation. The legacy `setup-profile-button` prompt appears in the conversation's bottom bar, and the flow continues as before (quick-edit name field → "Profile saved" pill → notification prompt).
3. The first-launch sheet does not re-appear on later launches (it shows once).

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
