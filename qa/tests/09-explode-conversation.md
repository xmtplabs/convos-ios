# Test: Explode Conversation

Verify that exploding a conversation removes it for all participants and destroys the conversation data.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in a shared conversation. The app user should be the super admin (conversation creator) so they have permission to explode.

## Setup

Create a conversation from the app (so the app user is the super admin). Have the CLI join via invite.

Exchange a few messages so the conversation has content.

## Steps

### Open conversation info

1. From the conversation view in the app, open the conversation info.
2. Scroll down to find the "Explode now" option. It should be visible to super admins.

### Trigger explode

3. Tap "Explode now".
4. A confirmation dialog should appear asking to confirm the destructive action.
5. Confirm the explosion.

### Verify explosion in app

6. The app should show an explosion animation or transition.
7. After the animation, the conversation should be removed or the app should navigate back to the conversations list.
8. Verify the exploded conversation no longer appears in the conversations list.

### Verify explosion via CLI

9. Use the CLI to list conversations. The exploded conversation should no longer appear or should be marked as destroyed.
10. Attempting to send a message to the exploded conversation should fail.

## Teardown

No cleanup needed — the conversation is already destroyed.

## Pass/Fail Criteria

- [ ] "Explode now" option is visible in conversation info for super admins
- [ ] Confirmation dialog appears before exploding
- [ ] Explosion animation plays after confirming
- [ ] Conversation is removed from the app's conversations list
- [ ] Conversation is no longer accessible via CLI
