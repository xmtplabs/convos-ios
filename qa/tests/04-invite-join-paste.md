# Test: Join Conversation via Paste in Scan View

Verify that the app can join a conversation by pasting an invite URL in the scan/join view.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

Use the CLI to create a conversation with a name like "Paste Invite Test" and a profile name for the CLI user.

Generate an invite for the conversation and capture the invite URL.

## Steps

### Copy the invite URL to the clipboard

1. Copy the invite URL to the simulator's clipboard. You can do this by running:
   `xcrun simctl pbcopy booted` and piping the invite URL to it.

### Open the scan view and paste

2. From the conversations list, tap the scan button in the bottom toolbar.
3. The scan/join view should appear with a camera viewfinder and a paste button in the top-right corner.
4. Tap the paste button (clipboard icon, accessibility identifier "paste-invite-button").
5. The app should process the pasted invite and begin the join flow.

### Process the join request

6. From the CLI, process the join request for the conversation using watch mode with a timeout.
7. Wait for the join to be processed.

### Verify the app is in the conversation

8. The app should transition into the conversation view. Conversations should appear **instantly** after the join request is processed — there is no expected delay. If the conversation does not appear within a few seconds of the CLI confirming the join was processed, that is a bug.
9. Verify the conversation name matches what was set in setup.

### Exchange a message to confirm

10. Send a message from the CLI and verify it appears in the app.
11. Send a reply from the app and verify it appears via CLI.

## Teardown

Explode the conversation via CLI.

## Pass/Fail Criteria

- [ ] Scan view opens from the conversations list
- [ ] Paste button is present and tappable
- [ ] Pasting a valid invite URL triggers the join flow
- [ ] Join request is sent and can be processed by the CLI
- [ ] App enters the conversation after joining
- [ ] Messages can be exchanged after joining
