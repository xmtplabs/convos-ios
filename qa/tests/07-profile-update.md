# Test: Update Profile in Conversation

Verify that a user can update their display name and profile photo within a conversation, that changes are reflected for other participants, and that per-conversation profile isolation works.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in at least two shared conversations (to test profile isolation).

## Setup

Join two CLI-created conversations from the app. Name them "Profile Test A" and "Profile Test B". Ensure the app user has a display name set in both conversations. Send at least one message from the app in each conversation.

## Steps

### View current profile

1. Open "Profile Test A" and note the current display name shown on messages sent from the app.

### Open conversation info

2. Tap the conversation info button in the toolbar.
3. Verify the conversation info view appears and shows the conversation name, members, and other details.

### Edit display name

4. Tap the edit info button (accessibility identifier: `edit-info-button`) or the user's avatar/profile area.
5. Change the display name to "Updated QA Name".
6. Save or confirm the change.

### Verify name updated in app

7. Go back to the conversation view.
8. Send a new message from the app.
9. Verify the new display name "Updated QA Name" appears on the newly sent message.

### Verify name updated via CLI

10. Use the CLI to check the conversation's member profiles.
11. Verify the app user's display name has been updated to "Updated QA Name".

### Set profile photo

12. Open conversation info again.
13. Tap the avatar/profile area to open the profile editor.
14. Choose or set a profile photo. If the editor allows a photo URL, download a photo first: `curl -sL "https://picsum.photos/400/400" -o /tmp/profile-photo.jpg`. Otherwise use the photo picker in the app.
15. Save the change.
16. Verify the profile photo appears on the user's avatar in the conversation.

### Verify profile photo syncs via CLI

17. Use the CLI to check conversation profiles.
18. Verify the app user's profile shows an image URL (the photo was uploaded and synced).

### Per-conversation profile isolation

19. Navigate back to the conversations list.
20. Open "Profile Test B".
21. Verify the display name in "Profile Test B" is still the original name — NOT "Updated QA Name". Profile changes in one conversation must not affect other conversations.
22. Send a message in "Profile Test B" and verify the original name appears.

## Teardown

Explode both conversations via CLI.

## Pass/Fail Criteria

- [ ] Conversation info view can be opened
- [ ] Display name can be edited
- [ ] Updated name appears on new messages in the app
- [ ] Updated name is visible to other participants via CLI
- [ ] Profile photo can be set
- [ ] Profile photo appears on the user's avatar in the conversation
- [ ] Profile photo syncs to other participants via CLI
- [ ] Per-conversation isolation: changing profile in one conversation does not affect another
