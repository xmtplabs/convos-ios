# Test: DM from Group

Verify that two members in a group conversation can initiate a DM with each other when both have DMs enabled.

## Prerequisites

- Two simulators running the app, both past onboarding (Device A and Device B).
- The convos CLI is initialized for the dev environment.

## Setup

Two simulators required (see multi-simulator rules in RULES.md).

1. Create a conversation via CLI named "DM Test" with profile name "CLI Bot".
2. Generate an invite and have Device A join via paste-in-scanner. Process the join request.
3. Generate a new invite and have Device B join via paste-in-scanner. Process the join request.
4. Verify CLI shows 3 members.
5. Send a message from CLI: "Hello everyone" — verify it appears on both devices so we know streams are active.

## Steps

### Both users enable DMs

6. On Device A, open conversation info (tap the conversation header).
7. Scroll to "Allow DMs" toggle (accessibility identifier: `allow-dms-toggle`). Verify it defaults to OFF.
8. Toggle it ON. Verify it turns green.
9. Go back to the conversation.
10. Repeat steps 6-9 on Device B.

### Device A sends DM to Device B

11. On Device A, open conversation info.
12. Tap the members row to open the members list.
13. Tap on Device B's member row (the "Somebody" that is not "You" and not "CLI Bot").
14. Verify the "Send DM" button appears (accessibility identifier: `send-dm-button`) with footer "Start a private conversation with Somebody".
15. Tap "Send DM".
16. Check Device A's app logs for "Sent convo request" and "DM request sent" messages.

### DM conversation appears on Device B

17. On Device B, navigate to the conversations list.
18. Wait up to 15 seconds for a new conversation to appear (it will be the DM, showing the other member's name or "Somebody").
19. Verify the new conversation has an unread indicator.
20. Open the new conversation on Device B.
21. Device B sends a message in the DM: "Hey from the DM!"
22. Verify the message appears in the conversation.

### DM conversation appears on Device A

23. On Device A, navigate to the conversations list.
24. Wait for the DM conversation to appear (it arrives via stream when Device B creates it and adds Device A).
25. Open the DM conversation on Device A.
26. Verify Device B's message "Hey from the DM!" is visible.
27. Device A sends a reply: "Got your DM!"
28. On Device B, verify "Got your DM!" appears in the DM conversation.

### Verify DM is a separate conversation

29. On either device, go back to the conversations list.
30. Verify both "DM Test" (the original group) and the DM conversation are listed as separate entries.
31. Open the DM conversation info on Device B. Verify it shows 2 members.

### Verify Send DM shows existing DM on repeat

32. On Device A, go back to "DM Test" group conversation.
33. Open conversation info, members list, tap Device B's member profile.
34. Tap "Send DM" again.
35. Verify Device A is navigated to the existing DM conversation (not a new one). The previously exchanged messages ("Hey from the DM!", "Got your DM!") should be visible.

### Verify Send DM hidden when DMs disabled

36. On Device B, go back to "DM Test" group conversation.
37. Open conversation info. Toggle "Allow DMs" OFF.
38. On Device A, open Device B's member profile in "DM Test" again.
39. Verify the "Send DM" button is no longer visible.

## Teardown

Explode the "DM Test" conversation via CLI. Shut down and delete both simulators.

## Pass/Fail Criteria

- [ ] Allow DMs toggle defaults to OFF and can be toggled ON
- [ ] Send DM button appears when target member has DMs enabled
- [ ] Tapping Send DM sends a convo request (verified via app logs)
- [ ] DM conversation appears on Device B with unread indicator
- [ ] Messages can be exchanged in the DM conversation (bidirectional)
- [ ] DM conversation appears on Device A after Device B creates it
- [ ] DM and original group are separate conversations in the list
- [ ] DM conversation has exactly 2 members
- [ ] Tapping Send DM again navigates to existing DM (no duplicate)
- [ ] Send DM button hidden when target disables DMs
