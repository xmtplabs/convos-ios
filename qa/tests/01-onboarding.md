# Test: Fresh Onboarding Flow

Verify that a first-time user can launch the app, create a conversation, and complete the quickname onboarding flow.

## Prerequisites

- The app is installed on the simulator.
- The simulator must be erased to ensure no prior app state exists. Run `xcrun simctl erase booted`, then reinstall and launch the app.

## Steps

### Launch into empty state

1. Launch the app.
2. Verify that the conversations list is empty and shows the empty state call-to-action with options to start or join a conversation.

### Create a conversation

3. Tap the compose button to start a new conversation.
4. The app should present a new conversation view. Verify a conversation name field and a message input are visible.
5. Enter a conversation name like "QA Onboarding Test".
6. Tap the send button or type a first message and send it.

### Quickname onboarding appears

7. After creating the conversation, **immediately** poll for the setup quickname prompt using `sim_wait_for_element` with identifier `setup-quickname-button` (timeout: 15s, interval: 1s). Do not take screenshots or perform other operations first — the prompt may appear quickly after conversation creation.
8. As soon as the element is found, tap it immediately using `sim_tap_id` with identifier `setup-quickname-button`.
9. The profile editor should appear. Enter a display name like "QA Tester".
10. Confirm or dismiss the profile editor.
11. A "Quickname saved" confirmation should appear briefly.

### Notification permission

12. After the quickname step, a notification permission prompt should appear — either the system permission dialog or a custom prompt within the app.
13. If the system dialog appears, accept or deny it. If a custom prompt appears, interact with it.
14. The onboarding flow should complete and the conversation view should be fully usable.

### Verify post-onboarding state

15. Navigate back to the conversations list.
16. Verify the conversation you created appears in the list with the name you entered.

## Pass/Fail Criteria

- [ ] App launches to an empty conversations list after simulator erase
- [ ] Compose button opens a new conversation flow
- [ ] Conversation can be created with a name
- [ ] Quickname setup prompt appears after creating the first conversation
- [ ] Quickname can be set via the profile editor
- [ ] Quickname saved confirmation appears
- [ ] Notification permission step is shown
- [ ] Onboarding completes and the conversation is usable
- [ ] Conversation appears in the conversations list with the correct name
