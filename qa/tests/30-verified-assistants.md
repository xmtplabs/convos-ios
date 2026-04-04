# Test: Verified Assistants

Verify that verified Convos assistants display correctly with verification badges, proper labeling, and that unverified agents show distinct UI treatment.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

Use the CLI to create a conversation and generate an invite. Open the invite in the app via deep link. Process the join request from the CLI.

After the app joins, use the app to add an "Instant assistant" from the add-to-conversation menu on a second conversation created from the app.

## Steps

### Join a conversation with a verified assistant already present

1. On the app (device 1), create a new conversation and add an Instant assistant via the add-to-conversation menu.
2. Wait for the assistant to join and send its first message.
3. Copy the invite link from the add-to-conversation menu.
4. On a second device or simulator, open the invite URL as a deep link.
5. After joining, verify the "Assistant is present" cell appears between "Earlier messages are hidden for privacy" and "You joined as ..." with the assistant's avatar and the "See its skills" button.
6. Tap "Assistant is present" to open the member profile view.
7. Verify the profile view shows "Get skills" and "Learn about assistants" buttons.

### Join a conversation with an unverified agent (CLI bot)

8. Use the CLI to create a conversation and generate an invite.
9. Open the invite in the app via deep link. Process the join request from the CLI.
10. After joining, verify the "Agent is present" cell appears (not "Assistant is present").
11. Verify there is no "See its skills" button below the "Agent is present" text.
12. Tap "Agent is present" to open the member profile view.
13. Verify the profile view does NOT show "Get skills" or "Learn about assistants" buttons — only "Block and leave".

### Verified assistant sender label

14. In the conversation with the verified assistant, check the assistant's messages.
15. The sender label above the assistant's messages should be in the Lava (orange-red) color.
16. The assistant's avatar should show the verification badge.

### Unverified agent sender label

17. In the conversation with the CLI bot, have the CLI send a text message.
18. The sender label above the CLI bot's messages should be in a muted/tertiary color (not Lava).

## Teardown

Explode both test conversations from the CLI.

## Pass/Fail Criteria

- [ ] "Assistant is present" cell appears for verified assistants with avatar and "See its skills" button
- [ ] "Agent is present" cell appears for unverified agents without "See its skills" button
- [ ] Tapping the present info cell opens the member profile view
- [ ] Verified assistant profile shows "Get skills" and "Learn about assistants"
- [ ] Unverified agent profile only shows "Block and leave"
- [ ] Verified assistant sender label uses Lava color
- [ ] Unverified agent sender label uses muted color
