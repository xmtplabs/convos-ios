# Test: Invite Code Gating

Verify that the Instant Assistant toggle is gated behind a one-time invite code, and that the full redeem flow works correctly.

## Prerequisites

- The app is running and past onboarding on the primary simulator.
- The backend (dev) has invite code gating deployed.
- A valid unredeemed invite code is available (e.g., `ZAWBZDKF`).
- The assistant feature flag is enabled (`FeatureFlags.isAssistantEnabled` is true — default on dev).

## Setup

1. If the app has previously redeemed a code on this simulator, reset the unlock state by going to App Settings → "Delete All Data" (or erase the simulator and reinstall the app).
2. Confirm the app is on the conversations list after onboarding.

## Steps

### Verify toggle is gated

1. Navigate to App Settings (tap the settings/hamburger icon in the conversations list).
2. Tap "Assistants" to open the Assistant Settings screen.
3. The "Instant assistant" toggle should be visible and in the OFF position (because no code has been redeemed).
4. Tap the toggle to turn it ON.
5. Instead of toggling, a code entry sheet should appear with:
   - Title "Additional assistants"
   - Body text about entering a code
   - A text field with placeholder "Invite code"
   - A "Continue" button

### Dismiss without entering a code

6. Dismiss the sheet by tapping outside it (drag down or tap the scrim).
7. The toggle should remain OFF.
8. Navigate back to the conversations list.
9. Tap the compose button to create a new conversation.
10. After the conversation is created, verify that the pull-to-add-assistant gesture area is not shown (scroll to the bottom — there should be no assistant prompt since the feature is gated).

### Enter an invalid code

11. Navigate back to App Settings → Assistants.
12. Tap the toggle to open the code entry sheet again.
13. Type "XXXXXXXX" in the text field.
14. Tap "Continue".
15. An inline error message should appear below the text field (e.g., "No invite code found with that value").
16. The text field should remain editable.
17. The sheet should remain open.

### Enter a valid code

18. Clear the text field and type the valid code "ZAWBZDKF".
19. Tap "Continue".
20. The "Continue" button should show a loading indicator while the request is in flight.
21. On success, the sheet should dismiss automatically.
22. The toggle should now be ON.

### Verify unlocked state persists

23. Navigate away from Assistant Settings (go back to the conversations list).
24. Return to App Settings → Assistants.
25. The toggle should still be ON — no code prompt appears.
26. Toggle OFF, then toggle ON again.
27. The toggle should switch freely without showing the code entry sheet.

### Verify assistant features are now available

28. Navigate to a conversation (create one if needed).
29. The pull-to-add-assistant gesture should now be functional (if the conversation has no assistant).
30. Tap the "+" button in the toolbar — the "Instant assistant" menu item should be visible.

### Verify Delete All Data clears unlock

31. Navigate to App Settings.
32. Scroll to the bottom and tap "Delete All Data".
33. Confirm the deletion (hold to delete).
34. After the app resets, complete onboarding.
35. Navigate to App Settings → Assistants.
36. The toggle should be OFF again (unlock state was cleared).
37. Tap the toggle — the code entry sheet should appear again, confirming the unlock was reset.

## Teardown

No specific teardown needed. The "Delete All Data" in step 32 resets the app. If continuing with other tests, the app will need to go through onboarding again.

## Pass/Fail Criteria

- [ ] Toggle shows as OFF when no code has been redeemed
- [ ] Tapping toggle ON (when not unlocked) opens the code entry sheet
- [ ] Dismissing the sheet without a code leaves the toggle OFF
- [ ] Invalid code shows an inline error message and the sheet stays open
- [ ] Valid code submission shows a loading state on the button
- [ ] Successful redemption dismisses the sheet and turns the toggle ON
- [ ] Unlocked state persists across navigation and toggle cycles
- [ ] Pull-to-add-assistant and "+" menu work after unlocking
- [ ] "Delete All Data" clears the unlock state — code prompt returns

## Accessibility Improvements Needed

- The code entry text field should have `accessibilityIdentifier("invite-code-text-field")` — verify it's findable.
- The submit button should have `accessibilityIdentifier("invite-code-submit-button")` — verify it's findable.
