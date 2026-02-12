# Test: Update Profile in Conversation

Verify that a user can update their display name within a conversation, and that the change is reflected for other participants.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in a shared conversation.

## Setup

Ensure the app user has a display name set. Send at least one message from the app so the display name is visible in the conversation.

## Steps

### View current profile

1. Note the current display name shown on messages sent from the app user.

### Open conversation info

2. Tap the conversation info button (the toolbar button at the top of the conversation).
3. The conversation info view should appear. Verify it shows the conversation name, members, and other details.

### Edit profile

4. Look for the way to edit the user's own profile or display name. This may be through the edit info button, or by tapping the user's avatar/profile area.
5. Change the display name to something new, like "Updated QA Name".
6. Save or confirm the change.

### Verify name updated in app

7. Go back to the conversation view.
8. Send a new message from the app.
9. Verify the new display name appears on the newly sent message.

### Verify name updated via CLI

10. Use the CLI to check the conversation's member profiles.
11. Verify the app user's display name has been updated to the new name.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] Conversation info view can be opened
- [ ] Display name can be edited
- [ ] Updated name appears on new messages in the app
- [ ] Updated name is visible to other participants via CLI
