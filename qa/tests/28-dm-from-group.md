# Test: DM from Group

Verify that a member can enable DMs in a group conversation and another member can initiate a DM from within that group. Uses two simulators to test both the sender and receiver sides.

## Prerequisites

- Two simulators running the app, both past onboarding (Device A and Device B).
- The convos CLI is initialized for the dev environment.
- A shared group conversation exists with both devices as members and the CLI as a third member.

## Setup

Two simulators required (see multi-simulator rules in RULES.md).

1. Create a conversation via CLI named "DM Test Group" with profile name "CLI Bot".
2. Generate an invite for the conversation.
3. Have Device A join the conversation via paste-in-scanner. Process the join request from CLI.
4. Generate a new invite (the first may be single-use or the tag may have rotated).
5. Have Device B join the conversation via paste-in-scanner. Process the join request from CLI.
6. Verify both devices are in the conversation (CLI shows 3 members).
7. Send a message from CLI: "Hello everyone" — verify it appears on both devices.

## Steps

### Enable DMs on Device B (the receiver)

8. On Device B, navigate to the conversation info screen (tap the conversation header/toolbar button).
9. Scroll to the "Personal preferences" section.
10. Find the "Allow DMs" toggle (accessibility identifier: `allow-dms-toggle`).
11. Verify the toggle is currently OFF.
12. Tap the toggle to enable DMs.
13. Verify the toggle is now ON.
14. Go back to the conversation.

### Verify "Send DM" button appears on Device A

15. On Device A, navigate to the conversation info screen.
16. Tap on Device B's member row to open their member profile (ConversationMemberView).
17. Verify a "Send DM" button appears (accessibility identifier: `send-dm-button`).
18. Note: If the `allows_dms` profile update hasn't synced yet, wait a few seconds and re-open the member profile.

### Send DM from Device A to Device B

19. Tap the "Send DM" button on Device A.
20. Device A should navigate back (the DM request is sent via the back channel).
21. Check Device A's app logs for "DM request sent" confirmation.

### Verify DM conversation appears on Device B

22. On Device B, navigate to the conversations list.
23. Wait for a new conversation to appear (the DM conversation created by Device B's client after processing the convo request).
24. Verify the new conversation appears in the list (it will be marked as unread).
25. Open the new conversation on Device B.
26. Verify it is a 2-member conversation (Device A and Device B's fresh identities).

### Verify DM is a normal locked conversation

27. On Device B, open the conversation info for the DM conversation.
28. Verify the conversation shows 2 members.
29. Verify the conversation is locked (the lock toggle should be ON or the add-member option should not be available).

### Verify DMs button hidden when DMs disabled

30. On Device B, go back to the "DM Test Group" conversation info.
31. Toggle "Allow DMs" OFF.
32. On Device A, open Device B's member profile in "DM Test Group" again.
33. Verify the "Send DM" button is no longer visible.

## Teardown

Explode the "DM Test Group" conversation via CLI. The DM conversation will remain (it's a separate conversation with separate identities). Shut down and delete Device B simulator.

## Pass/Fail Criteria

- [ ] Allow DMs toggle appears in conversation settings and defaults to OFF
- [ ] Toggling Allow DMs ON sends a ProfileUpdate (check via log events)
- [ ] Send DM button appears on member profile when target has DMs enabled
- [ ] Tapping Send DM sends a convo request via back channel (check app logs)
- [ ] DM conversation appears on Device B after processing the request
- [ ] DM conversation is locked (no new members can be added)
- [ ] DM conversation has exactly 2 members
- [ ] Send DM button disappears when target disables DMs
