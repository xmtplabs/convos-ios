# Test: Multi-Device Create Conversation Sync

Verify that when a new conversation is created on one paired device, it appears on the other device, and that messages sent from either device appear correctly on both.

## Prerequisites

- Two iOS Simulators are available, referred to as **Device A** and **Device B**.
- Both devices have been paired via the Vault pairing flow (test 26 or equivalent).
- Both devices are past onboarding and showing the conversations list (not inside any settings screen or sheet).
- Both simulators have Reduce Motion enabled and animations disabled (per RULES.md simulator preparation).

## Setup

### Verify pairing is active and return to conversations list

1. On **Device A**, open Settings (`app-settings-button`) → Devices (`devices-row`).
2. Verify both devices appear in the devices list (one marked "This device").
3. Navigate back to the conversations list: tap back from Devices, then dismiss Settings (tap the X / Cancel button).
4. Confirm **Device A** is showing the conversations list (the compose button `compose-button` should be visible).

5. On **Device B**, if any sheet is showing (joiner pairing, settings, etc.), dismiss it. Confirm **Device B** is showing the conversations list.

## Steps

### Create a conversation on Device A and verify it appears on Device B

6. On **Device A**, tap the compose button (`compose-button`) to start a new conversation.
7. Wait for the conversation view to load (the message input field `message-text-field` should appear).
8. Type "Sync test from A" in the message input field (`message-text-field`) and send it (`send-message-button`).
9. Verify the `message.sent` event fires on Device A using `sim_log_events` with `event_filter="message.sent"`.
10. Navigate back to the conversations list on **Device A**. The new conversation should appear (look for "New Convo" or the conversation list item).

11. On **Device B**, check the conversations list. The new conversation from Device A should appear within 30 seconds. Use `sim_find_elements` to search for conversation list items periodically.
12. Once the conversation appears on **Device B**, tap it to open it.
13. Verify the conversation loads and shows "Sync test from A" in the message list. Use `sim_find_elements` to search for the message text.

### Send a message from Device B and verify it appears as the sender on Device B

14. On **Device B**, inside the synced conversation, type "Reply from B" in the message input field and send it.
15. Verify the `message.sent` event fires on Device B using `sim_log_events`.
16. On **Device B**, verify "Reply from B" appears in the conversation as a sent message (right-aligned / sender style). Use `sim_find_elements` or `sim_screenshot` to confirm.

### Verify the message from Device B arrives on Device A

17. On **Device A**, open the conversation (tap it in the conversations list if not already open).
18. Verify "Reply from B" appears in the message list on Device A. Use `sim_find_elements` to search for the message text. This message should appear as a received message (left-aligned / receiver style) since it came from Device B's XMTP installation.

### Send a message from Device A and verify it appears as the sender on Device A

19. On **Device A**, inside the conversation, type "Reply from A" in the message input field and send it.
20. Verify "Reply from A" appears on **Device A** as a sent message (right-aligned / sender style).

### Verify the message from Device A arrives on Device B

21. On **Device B**, verify "Reply from A" appears in the conversation message list within a few seconds. Use `sim_find_elements` to confirm.

### Create a conversation on Device B and verify it appears on Device A

22. On **Device B**, navigate back to the conversations list and tap the compose button to start a new conversation.
23. Wait for the conversation view to load, then type "Created on B" and send it.
24. Navigate back to the conversations list on **Device B**. The new conversation should appear.

25. On **Device A**, navigate to the conversations list.
26. The conversation created on Device B should appear within 30 seconds. Check periodically with `sim_find_elements`.
27. Once found, tap the conversation to open it and verify "Created on B" is visible in the message list.

## Teardown

No specific cleanup needed. Conversations can be left for subsequent tests or the simulators can be erased.

## Pass/Fail Criteria

- [ ] Conversation created on Device A appears in Device A's conversations list
- [ ] Conversation created on Device A appears on Device B within 30 seconds
- [ ] Opening the synced conversation on Device B shows the message "Sync test from A"
- [ ] Message sent from Device B ("Reply from B") appears as a sent message on Device B
- [ ] Message sent from Device B ("Reply from B") appears on Device A
- [ ] Message sent from Device A ("Reply from A") appears as a sent message on Device A
- [ ] Message sent from Device A ("Reply from A") appears on Device B
- [ ] Conversation created on Device B appears on Device B's conversations list
- [ ] Conversation created on Device B appears on Device A within 30 seconds
- [ ] Opening the synced conversation on Device A shows the message "Created on B"

## Notes

- Both devices must be on the conversations list (not inside settings/devices) before creating conversations. The conversations list uses GRDB observation to show new conversations reactively — being on a different screen may delay visibility.
- Conversation sync relies on the Vault's key sharing mechanism. When a new conversation is created, the GRDB inbox observation detects the unshared inbox and sends the key via the Vault group. The other device receives the key, imports it, wakes the inbox via InboxLifecycleManager, and requests XMTP device sync.
- Messages between paired devices travel through XMTP's MLS group — they are not relayed through the Vault. Each device has its own XMTP installation for each conversation inbox, so messages appear as "sent" on the originating device and "received" on the other.
- If a conversation doesn't appear after 30 seconds, check the device's logs for "Vault: found X unshared inbox(es)" and "Vault: sharing key for inbox" entries to verify key sharing fired.

## Accessibility Improvements Needed

- None identified — this test uses standard conversation list and compose flow identifiers.
