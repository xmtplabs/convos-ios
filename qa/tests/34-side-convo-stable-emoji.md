# Test: Side Convo Invite and Stable Conversation Emoji (Two Simulators)

Verify that the Side convo flow creates a linked conversation with a stable emoji across devices, and that the sent invite preview preserves the side convo metadata for the receiver.

## Prerequisites

- **Two simulators required.** Use Device A as the sender and Device B as the receiver.
- Both simulators are booted with the app installed and launched.
- Both simulators are past onboarding and able to exchange messages.
- Device A and Device B are already in at least one shared conversation that can be used to send the side convo invite.

## Setup

1. Open the shared conversation on both devices.
2. Initialize log markers for both devices.
3. Confirm both devices are synced and no warning/error logs are appearing beyond known infrastructure noise (per log monitoring rules in `qa/RULES.md`).

## Steps

### Create a side convo from Device A

1. On Device A, open the media buttons bar.
2. Verify the **Side convo** button is visible.
3. Tap the Side convo button.
4. Verify a side convo preview card appears in the composer.
5. Record the emoji shown in the side convo preview card on Device A.
6. Enter a side convo name such as `Stable Emoji QA`.
7. Without dismissing the card, verify the side convo preview still shows the same emoji after editing the name.

### Send the side convo invite

8. Tap Send on Device A.
9. Verify the side convo invite appears immediately in Device A's message list.
10. Verify the sent side convo cell on Device A shows the same emoji recorded in step 5.
11. On Device B, wait for the invite message to arrive.
12. Verify the received invite cell shows the same emoji as Device A's sent cell.
13. Verify the received invite cell shows the side convo name `Stable Emoji QA`.

### Join and compare the created conversation across both devices

14. On Device B, tap the received side convo invite.
15. Wait for Device B to enter the linked conversation or complete verification and then enter it.
16. Verify the linked conversation header on Device B shows `Stable Emoji QA`.
17. Record the emoji/avatar shown for the linked conversation on Device B.
18. On Device A, tap the sent side convo invite to open the same linked conversation.
19. Verify the linked conversation header on Device A shows `Stable Emoji QA`.
20. Verify the emoji/avatar shown for the linked conversation on Device A matches the emoji recorded on Device B.
21. Verify the emoji/avatar shown in the linked conversation on Device A also matches the original emoji recorded in step 5.

### Verify the linked conversation is functional

22. On Device B, send a message such as `hello from device b in side convo`.
23. On Device A, verify that message appears in the linked conversation.
24. On Device A, send a reply such as `hello from device a in side convo`.
25. On Device B, verify the reply appears.
26. Navigate back to the conversations list on both devices.
27. Verify the linked conversation appears in the conversations list on both devices with the same emoji/avatar.

## Teardown

- Explode the linked side convo from Device A or leave it only if the test run explicitly needs it for subsequent scenarios.
- Return both devices to the original shared conversation or the conversations list.

## Pass/Fail Criteria

- [ ] The Side convo button opens a composer preview card
- [ ] Editing the side convo name does not change the preview emoji on Device A
- [ ] The sent invite cell on Device A shows the same emoji as the composer preview
- [ ] The received invite cell on Device B shows the same emoji as Device A
- [ ] The received invite cell on Device B shows the side convo name `Stable Emoji QA`
- [ ] After joining, both devices show the same emoji/avatar for the linked conversation
- [ ] The linked conversation emoji/avatar matches the original composer preview emoji from Device A
- [ ] The linked conversation name is `Stable Emoji QA` on both devices
- [ ] Two-way messaging works inside the linked conversation
- [ ] The conversations list shows the linked conversation with the same emoji/avatar on both devices

## Accessibility Improvements Needed

- Confirm the side convo preview card exposes the conversation name field and any emoji/avatar container with stable identifiers or labels.
- If the invite cell emoji or linked conversation header emoji cannot be reliably found by identifier or label, add a note with the exact element that required fallback inspection.
