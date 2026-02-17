# Test: Join Conversation via Deep Link

Verify that the app can join a conversation by opening an invite URL as a deep link.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

Use the CLI to create a conversation with a name like "Deep Link Test" and a profile name for the CLI user.

Generate an invite for the conversation and capture the invite URL.

## Steps

### Open the invite deep link

1. Open the invite URL in the simulator using the deep link tool. The URL format is `https://dev.convos.org/v2?i=<slug>`.
2. The app should intercept the deep link and show a join flow. Wait for the join view or conversation view to appear.
3. If a join button is visible, tap it.

### Process the join request

4. From the CLI, process the join request for the conversation. Use the watch mode with a reasonable timeout since the timing of the app's join request may vary.
5. Wait for the join to be processed successfully.

### Verify the app is in the conversation

6. The app should transition into the conversation view after being admitted.
7. Verify the conversation name appears in the UI.

### Exchange a message to confirm membership

8. Use the CLI to send a message like "Welcome via deep link!".
9. Wait a few seconds, then verify the message appears in the app.
10. Send a reply from the app to confirm two-way communication works.
11. Verify the app's reply appears via CLI.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] Deep link URL opens the app and triggers the join flow
- [ ] App sends a join request that the CLI can process
- [ ] App enters the conversation after the join is processed
- [ ] Conversation name is displayed correctly
- [ ] Messages can be exchanged after joining
