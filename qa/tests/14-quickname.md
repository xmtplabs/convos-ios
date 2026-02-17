# Test: Quickname Flow

Verify that the quickname feature works end-to-end: setting up a quickname, having it auto-applied to new conversations, editing per-conversation identity via the quick edit view, and overriding with the quickname from the My Info view.

## Prerequisites

- The app is running and has a quickname already set up (from the onboarding flow or a previous session).
- The convos CLI is initialized for the dev environment.
- If no quickname is set up, set one up first by creating a conversation and going through the onboarding flow.

Note the quickname display name and avatar before starting. These will be verified throughout the test.

## Steps

### Part 1: Quickname auto-applied on new conversation

1. Create a new conversation via the CLI with a name like "Quickname Test" and a profile name for the CLI user.
2. Generate an invite and open it as a deep link in the app. Wait 2-3 seconds for the app to send the join request.
3. Start the CLI `process-join-requests` command **in the background** (append `&` in bash) and **in the same parallel call block**, use `sim_tap_id` with identifier `"Tap to chat"` and `retries: 30` to find-and-tap the quickname pill in one atomic operation. The pill appears as soon as the conversation becomes ready (during join processing) and auto-dismisses after ~8 seconds. The background CLI command and the `sim_tap_id` must be issued simultaneously so polling starts before the pill appears. Do not use `sim_wait_for_element` followed by a separate tap — the pill will auto-dismiss between the two calls.
4. After the pill is tapped, take a screenshot and verify:
   - The composer area shows the quickname avatar next to the text field.
   - The text field placeholder says "Chat as <quickname display name>".
7. Send a message from the app.
8. Verify the sent message appears with the quickname display name.
9. Use the CLI to check the member profiles for the conversation. Verify the app user's profile shows the quickname display name.

### Part 2: Edit display name via quick edit

10. Tap the avatar button next to the message composer. This should open the quick edit view — a capsule-shaped editor with a photo picker, a text field for the display name, a lanyard button for settings, and a checkmark done button.
11. Verify the quick edit view is visible. The text field should show the current display name.
12. Clear the display name and type a new name like "Custom Name".
13. Tap the done button (checkmark) to save.
14. Verify the composer now shows "Chat as Custom Name" in the placeholder.
15. Send a message and verify it appears with "Custom Name" as the sender.
16. Use the CLI to check profiles — the app user's name should now be "Custom Name".

### Part 3: Override with quickname from My Info view

17. Tap the avatar button again to open the quick edit view.
18. Tap the lanyard button (the settings button with the lanyard icon). This should open the My Info view as a sheet.
19. In the My Info view, verify:
    - There is a section showing how you appear in the current convo (with the "Custom Name" you set in Part 2).
    - There is a quickname section showing your saved quickname with a "Use" button.
20. Tap the "Use" button next to the quickname.
21. The button should change to a checkmark to confirm.
22. Dismiss the My Info view.
23. Verify the composer now shows "Chat as <quickname display name>" (back to the quickname).
24. Send a message and verify it appears with the quickname display name.
25. Use the CLI to verify the profile was updated back to the quickname.

### Part 4: Edit quickname from App Settings

26. Navigate back to the conversations list.
27. Tap the Convos settings button (top-left corner) to open App Settings.
28. In App Settings, find the "My info" row. It should show the lanyard icon, the text "My info", and the current quickname display name and avatar on the right side.
29. Tap the "My info" row. This should navigate to the My Info view with the quickname editable.
30. Change the quickname display name to something new like "Updated QN".
31. Optionally change the quickname avatar using the photo picker.
32. Navigate back to App Settings. The "My info" row should now show the updated quickname name.
33. Dismiss App Settings.

### Part 5: Verify updated quickname in a new conversation

34. Create another conversation via the CLI with a different name like "Quickname Persist Test".
35. Generate an invite and open it as a deep link. Wait 2-3 seconds for the app to send the join request.
36. Start the CLI `process-join-requests` command **in the background** (append `&`) and **in the same parallel call block**, use `sim_tap_id` with identifier `"Tap to chat"` and `retries: 30` to find-and-tap the quickname pill atomically.
37. Verify the tap result label contains the updated quickname display name ("Updated QN" or whatever was set in Part 4).
38. Verify the composer shows "Chat as Updated QN".
39. Send a message and verify it appears with the updated quickname display name.
40. Use the CLI to check profiles — the app user's name should be the updated quickname.

## Teardown

Explode all conversations created during this test via the CLI.

## Pass/Fail Criteria

- [ ] Quickname pill appears above the composer when entering a new conversation
- [ ] Quickname pill shows the correct display name and avatar
- [ ] After applying the quickname, the composer shows "Chat as <display name>"
- [ ] Messages sent with the quickname show the correct display name
- [ ] Quickname is visible to other participants via CLI
- [ ] Quick edit view opens when tapping the avatar
- [ ] Display name can be changed via the quick edit view
- [ ] Changed display name is reflected in the composer and sent messages
- [ ] Lanyard button in quick edit opens the My Info view
- [ ] My Info view shows the current convo identity and the quickname
- [ ] "Use" button in My Info applies the quickname to the current conversation
- [ ] Quickname override is reflected in the composer and sent messages
- [ ] App Settings "My info" row shows the current quickname
- [ ] Quickname can be edited from App Settings My Info view
- [ ] Updated quickname appears in App Settings row after saving
- [ ] Updated quickname pill appears in a new conversation with the new name
- [ ] Updated quickname is applied correctly to the new conversation
