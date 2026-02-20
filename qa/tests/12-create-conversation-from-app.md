# Test: Create Conversation from App and Invite via Share

Verify that a conversation can be created from the app, an invite can be generated and shared, and another participant can join.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Steps

### Create a new conversation

1. From the conversations list, tap the compose button.
2. A new conversation view should appear.
3. Enter a conversation name like "App Created Test".
4. Send a first message like "Hello from the creator".

### Generate and share an invite

5. Look for the share/invite button in the conversation toolbar (the share icon).
6. Tap the share button to open the invite share view.
7. The share view should display a QR code and an invite URL.
8. Copy or note the invite URL from the share view.

### Join from CLI

9. Use the CLI to join the conversation using the invite URL from the app.
10. From the app side, process the join request — or if the app auto-processes it, wait for the new member to appear.
11. Note: since the app is the creator, it needs to process join requests. Check if the app shows any indication of a pending join request and handle it.

### Verify membership

12. After the CLI joins, verify the member count in conversation info increases.
13. Use the CLI to send a message and verify it appears in the app.
14. Send a message from the app and verify it appears via CLI.

## Teardown

Explode the conversation from the app (since the app is the super admin).

## Pass/Fail Criteria

- [ ] New conversation can be created from the app
- [ ] Conversation name is set correctly
- [ ] Share/invite button opens the invite share view
- [ ] Invite view shows a QR code and invite URL
- [ ] CLI can join using the invite URL
- [ ] Messages can be exchanged between app and CLI after joining
