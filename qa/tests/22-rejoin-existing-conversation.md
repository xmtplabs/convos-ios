# Test: Rejoin Existing Conversation via Invite

Verify that scanning or pasting an invite code for a conversation the user is already a member of navigates to that existing conversation instead of getting stuck.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- At least one conversation exists that the app user is already a member of.

## Setup

Use the CLI to create a conversation with a name like "Rejoin Test" and a profile name for the CLI user.

Generate an invite for the conversation and capture the invite URL.

Open the invite in the app via deep link and process the join request from the CLI so the app user joins the conversation.

Verify the conversation appears in the app and exchange a message to confirm membership.

Generate a second invite URL for the same conversation (to use in the rejoin tests).

Navigate back to the conversations list.

## Steps

### Rejoin via deep link

1. Open the second invite URL in the simulator using the deep link tool.
2. The app should recognize that the user is already in this conversation and show the conversation view (not remain stuck on a loading or scanner screen).
3. Verify the conversation name matches what was set in setup.
4. Dismiss the new conversation view to return to the conversations list.

### Rejoin via paste in scanner

5. Copy the second invite URL to the simulator's clipboard.
6. From the conversations list, tap the scan button in the bottom toolbar to open the scanner.
7. Tap the paste button (accessibility identifier "paste-invite-button").
8. The app should recognize that the user is already in this conversation and transition from the scanner to showing the conversation view.
9. Verify the conversation name matches what was set in setup.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] Deep link for existing conversation shows the conversation view (not a blank or stuck screen)
- [ ] Conversation name is visible after deep link rejoin
- [ ] Paste in scanner for existing conversation dismisses the scanner and shows the conversation view
- [ ] Conversation name is visible after paste rejoin
