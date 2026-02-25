# Test: Profile and Group Photos

Verify that profile photos and group photos can be set, display correctly, and sync to other participants.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in a shared conversation.

## Setup

Create a conversation via CLI with a name like "Photo Test" and a profile name. Join from the app via invite. Ensure at least one message has been exchanged so both participants are visible.

## Steps

### Set profile photo from app

1. Open the conversation in the app.
2. Open conversation info (tap the info button in the toolbar).
3. Tap on the user's own avatar or the edit profile area.
4. Set a profile photo. If the app offers a photo picker, use it. The photo should load and display on the avatar.
5. Save the profile changes.

### Verify profile photo displays in app

6. Return to the conversation view.
7. Send a message from the app.
8. Verify the profile photo appears on the user's avatar next to their messages (instead of the default initials/emoji avatar).

### Verify profile photo syncs to CLI

9. Use the CLI to check conversation profiles (`convos conversation profiles <id>`).
10. Verify the app user's profile shows an image URL — this confirms the photo was uploaded and synced over XMTP.

### Set group photo

11. Open conversation info again.
12. Tap on the group avatar/photo area at the top of the conversation info view.
13. Set a group photo (similar flow to profile photo).
14. Save the change.

### Verify group photo displays

15. Verify the group photo appears in the conversation info header.
16. Navigate to the conversations list.
17. Verify the group photo appears on the conversation's avatar in the list.

### Verify group photo syncs to CLI

18. Use the CLI to check the conversation details.
19. Verify the conversation has an image URL set.

### Update profile photo

20. Open conversation info and change the profile photo to a different image.
21. Save the change.
22. Verify the new photo replaces the old one on the user's avatar in the conversation.
23. Use the CLI to verify the updated photo URL.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] Profile photo can be set from the app
- [ ] Profile photo displays on the user's avatar in the conversation
- [ ] Profile photo syncs to other participants (visible via CLI)
- [ ] Group photo can be set from conversation info
- [ ] Group photo displays in conversation info header
- [ ] Group photo displays in the conversations list avatar
- [ ] Group photo syncs to other participants (visible via CLI)
- [ ] Profile photo can be updated and the new photo replaces the old one
