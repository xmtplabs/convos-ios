# Test: Delete All Data

Verify that the "Delete All Data" flow in App Settings permanently deletes all conversations and returns the app to the onboarding state.

## Prerequisites

- The app is running and past onboarding.
- At least one conversation exists in the conversations list.
- This test is destructive — it wipes all app data. Run it last or on a simulator that can be reset afterward.

## Setup

Ensure at least 2 conversations exist in the conversations list so we can verify they are all deleted. Note the conversation names for verification.

## Steps

### Navigate to Delete All Data

1. From the conversations list, tap the settings button (accessibility identifier: `app-settings-button`).
2. Verify the App Settings view appears.
3. Scroll down and find the "Delete All Data" button (accessibility identifier: `delete-all-data-button`).
4. Tap the "Delete All Data" button.

### Confirmation view

5. Verify a confirmation view appears with a title like "Delete everything?" and a warning message about permanent deletion.
6. Verify a "Hold to delete" button is present (accessibility identifier: `hold-to-delete-button`).
7. Verify a "Cancel" button is present.

### Cancel the deletion

8. Tap "Cancel".
9. Verify the confirmation view dismisses and the app returns to settings (or conversations list).
10. Verify conversations still exist — nothing was deleted.

### Perform the deletion

11. Navigate back to the "Delete All Data" button and tap it again.
12. Long-press and hold the "Hold to delete" button for the required duration (about 3 seconds).
13. Verify a "Deleting..." progress state appears on the button while deletion is in progress.

### Verify deletion completes

14. Wait for the deletion to complete. The app should return to the onboarding/empty state.
15. Verify the conversations list is empty — showing the empty state CTA ("Start a convo" / "or join one").
16. Verify no conversations from before the deletion are visible.

### Verify no stuck state

17. Verify there is no lingering "Deleting..." message or spinner.
18. Verify the app is fully interactive — you can tap "Start a convo" and create a new conversation.

## Teardown

No teardown needed — the app is already in a fresh state. If further tests need to run after this, re-create conversations as needed.

## Pass/Fail Criteria

- [ ] "Delete All Data" button is accessible in App Settings
- [ ] Confirmation view appears with warning and hold-to-delete button
- [ ] Cancel dismisses confirmation without deleting anything
- [ ] Holding the delete button shows "Deleting..." progress state
- [ ] Deletion completes and app returns to empty/onboarding state
- [ ] No conversations remain after deletion
- [ ] No stuck "Deleting..." state — app is fully interactive after completion
