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

> The "rejoin via paste in scanner" path was removed with the in-app scan
> view in the #910 home-shell rework (see `04-invite-join-paste.md`). Joining
> is now via the device camera or a deep-link URL, so only the deep-link
> rejoin is covered here. Re-add a paste step if the scan button returns.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] Deep link for existing conversation shows the conversation view (not a blank or stuck screen)
- [ ] Conversation name is visible after deep link rejoin
- [ ] Navigating back from the rejoined conversation returns to the list
