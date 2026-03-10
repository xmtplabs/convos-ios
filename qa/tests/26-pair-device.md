# Test: Pair Device

Verify that two devices can pair via the Vault pairing flow with pin + emoji verification, and that after pairing, conversations from both devices are synced across both devices.

## Prerequisites

- Two iOS Simulators are available, referred to as **Device A** and **Device B**.
- Both simulators have been erased (`xcrun simctl erase`) to ensure completely fresh state — no prior app data, keychain, or vault identity.
- The app is freshly installed on both simulators.
- Both simulators have Reduce Motion enabled and animations disabled (per RULES.md simulator preparation).

## Setup

### Prepare simulators

1. Erase both simulators, boot them, and install a fresh build of the app on each.
2. Launch the app on both simulators. Both should show the empty-state onboarding screen ("Pop-up private convos").

### Create initial conversation and complete onboarding on Device A

3. On **Device A**, tap the compose button to start a new conversation.
4. Complete onboarding if prompted (quickname setup, notification permission — dismiss or complete quickly).
5. Send a message (e.g., "Setup from A") so the first conversation is created on the network.
6. Navigate back to the conversations list.

### Seed conversations on Device A

7. On **Device A**, navigate to Settings (`app-settings-button`) → Debug.
8. In the "QA Seed Data" section, select "5" from the conversations picker.
9. Tap "Seed Conversations" and wait for the progress to show 5/5 with a checkmark.
10. Navigate back to the conversations list. Verify at least 5 "Seed" conversations appear.

### Populate seed conversations with varied content via CLI

11. Read seed events from Device A's logs: `sim_log_events(udid=DEVICE_A_UDID, event_filter="qa.seed_conversation")`. Extract the conversation IDs and invite URLs.
12. For each seed conversation, use the CLI to join and send varied messages:
    - Join: `convos conversations join <slug> --profile-name "QA Bot"`
    - Wait for the app to process the join request (the `InviteJoinRequestsManager` streams join requests automatically). Check logs for `member.joined` events.
    - Send text: `convos conversation send-text <id> "Hello from QA Bot"`
    - Get the message ID from the send output, then send a reaction: `convos conversation send-reaction <id> <msg-id> add "👍"`
    - Send a reply: `convos conversation send-reply <id> <msg-id> "This is a reply"`
    - Send a URL: `convos conversation send-text <id> "Check out https://example.com/test"`
    - Send a photo: `curl -L -o /tmp/qa-photo.jpg https://picsum.photos/400/300 && convos conversation send-attachment <id> /tmp/qa-photo.jpg`
13. Verify messages are received on Device A. Wait a few seconds, then check the conversations list — seed conversations should show recent message previews.

### Create initial conversation and complete onboarding on Device B

14. On **Device B**, tap the compose button to start a new conversation.
15. Complete onboarding if prompted.
16. Send a message (e.g., "Setup from B") so the first conversation is created on the network.
17. Navigate back to the conversations list.

### Seed conversations on Device B

18. On **Device B**, navigate to Settings → Debug.
19. In the "QA Seed Data" section, select "3" from the conversations picker.
20. Tap "Seed Conversations" and wait for the progress to show 3/3 with a checkmark.
21. Navigate back to the conversations list. Verify at least 3 "Seed" conversations appear.

### Populate seed conversations on Device B with varied content via CLI

22. Read seed events from Device B's logs: `sim_log_events(udid=DEVICE_B_UDID, event_filter="qa.seed_conversation")`. Extract the conversation IDs and invite URLs.
23. For each seed conversation, join via CLI and send at least 2 messages each (text + reaction or reply).
24. Verify messages are received on Device B.

### Record conversation counts

25. Count conversations on Device A (should be ~6: 1 manual + 5 seeded). Save this count.
26. Count conversations on Device B (should be ~4: 1 manual + 3 seeded). Save this count.
27. The expected post-pairing count on both devices = Device A count + Device B count.

## Steps

### Initiate pairing on Device A

28. On **Device A**, tap the settings button (`app-settings-button`).
29. Tap the "Devices" row (`devices-row`).
30. The Devices screen should show only the current device (with "This device" label).
31. Tap "Add new device" (`add-device-button`).
32. The pairing sheet should appear with title "Pair new device" and a blurred QR code.
33. Long-press the "Hold to reveal" button (`hold-to-reveal-button`) to reveal the QR code.

### Extract the pairing URL

34. Read the pairing URL from the app event log using `sim_log_events(udid=DEVICE_A_UDID, event_filter="vault.pairing_url_created")`. The URL is in the `url=` parameter of the event line.
35. Verify the URL has the format `https://dev.convos.org/pair/<slug>?expires=<unix_timestamp>&name=<device_name>`.

### Open pairing URL on Device B

36. On **Device B**, open the pairing URL as a deep link using `sim_open_url`.
37. The joiner pairing sheet should appear with title "Request to pair".
38. The sheet should show a connecting/loading state briefly, then the text should read `"<Device A name>" is requesting to pair. Paired devices sync all conversations.`

### Device A shows generated pin

39. On **Device A**, the pairing sheet should transition from the QR code to a pin display state. Wait for `pairing-pin-display` to appear.
40. The sheet should show `Share this code with "<Device B name>" to continue pairing.` with a 6-digit pin displayed below.
41. Read the pin from the accessibility tree (`pairing-pin-display`).

### Device B enters pin

42. On **Device B**, the sheet should have transitioned to pin entry. Wait for `pin-entry-field` to appear.
43. The sheet should read `Enter the code shown on "<Device A name>" to finish pairing.`
44. Type the 6-digit pin (read from step 41) into the pin entry field.
45. The "Submit" button (`submit-pin-button`) should become enabled once all 6 digits are entered.
46. Tap "Submit".

### Verify emoji fingerprint on both devices

47. On **Device B**, the sheet should transition to show 3 emoji (`pairing-emoji-fingerprint`). Title changes to "Confirm pairing". Text reads `Make sure these emoji match on "<Device A name>".` with "Waiting for confirmation..." below.
48. On **Device A**, the sheet should also transition to show the same 3 emoji (`pairing-emoji-fingerprint`). Title changes to "Confirm pairing". Text reads `Make sure these emoji match on "<Device B name>" before confirming.`
49. Verify the emoji shown on both devices are identical.

### Confirm pairing on Device A

50. Tap "Confirm" (`confirm-emoji-button`) on **Device A**.
51. The sheet should transition to the "syncing" state showing "Pairing..." with a rotating sync icon.
52. After a few seconds, the sheet should transition to the "completed" state. The title should change to "Device added" and show a checkmark icon with Device B's name.
53. Tap "Got it" (`got-it-button`) to dismiss the pairing sheet.

### Verify Device A shows both devices

54. The Devices screen should now show two devices in the list.
55. One device should have the "This device" label (Device A).
56. The other device should show Device B's simulator name.

### Verify conversation sync on Device A

57. Navigate back to the conversations list on **Device A** (tap the back button from Devices → Settings, then dismiss settings).
58. Wait up to 60 seconds for the VaultImportSyncDrainer to process imported inboxes. The conversations list should grow as inboxes are synced.
59. The conversations list should contain all conversations from both devices — the total should equal Device A's original count + Device B's original count (saved in steps 25-27).
60. Verify at least one "Seed" conversation from Device B appears.

### Verify conversation sync on Device B

61. On **Device B**, dismiss the pairing sheet if it's still showing (tap "Got it" if available).
62. Navigate to the conversations list on **Device B**.
63. Wait up to 60 seconds for sync. The conversations list should grow as inboxes are imported.
64. The conversations list should contain the same total count as Device A.
65. Verify at least one "Seed" conversation from Device A appears.

### Verify message content survived sync

66. On **Device A**, tap on one of Device B's seed conversations.
67. Wait for messages to load. Verify that messages from the CLI QA Bot are visible (text, reactions, replies, photos, or links — at least some content should appear).
68. Navigate back to the conversations list.

69. On **Device B**, tap on one of Device A's seed conversations.
70. Wait for messages to load. Verify that messages from the CLI QA Bot are visible.
71. Navigate back to the conversations list.

### Verify no leaked unused conversations

72. Neither device should show any extra "New Convo" entries or other conversations that weren't explicitly created by the user or the seed process. Unconsumed unused conversations (pre-created by the app for quick-start) must not be shared during pairing.

### Post-pairing: Create conversation on Device A, verify sync to Device B

73. On **Device A** (conversations list), tap the compose button (`compose-button`) to start a new conversation.
74. Wait for the conversation view to load (`message-text-field` should appear).
75. Type "Post-pair from A" in the message input field and send it (`send-message-button`).
76. Verify the `message.sent` event fires on Device A using `sim_log_events(event_filter="message.sent")`.
77. Navigate back to the conversations list on **Device A**. The new conversation should appear.

78. On **Device B**, check the conversations list. The new conversation should appear within 60 seconds. Watch for it by checking `sim_find_elements` or taking screenshots periodically.
79. Once the conversation appears on **Device B**, tap it to open it.
80. Verify "Post-pair from A" is visible in the messages.
81. Navigate back to the conversations list on **Device B**.

### Post-pairing: Create conversation on Device B, verify sync to Device A

82. On **Device B**, tap the compose button to start a new conversation.
83. Type "Post-pair from B" in the message input field and send it.
84. Navigate back to the conversations list on **Device B**.

85. On **Device A**, check the conversations list. The new conversation from Device B should appear within 60 seconds.
86. Once it appears, tap it to open it and verify "Post-pair from B" is visible in the messages.
87. Navigate back to the conversations list on **Device A**.

### Post-pairing: Delete conversation on Device A, verify removal from Device B

88. Record the total conversation count on **Device A** before deletion.
89. On **Device A**, long-press on the conversation that was just created from A ("Post-pair from A" or its "New Convo" list entry) to open the context menu.
90. Tap "Delete" (`context-menu-delete`) in the context menu.
91. A confirmation action sheet should appear. Tap "Delete" to confirm.
92. Verify the conversation is removed from Device A's conversations list.

93. On **Device B**, check the conversations list. The deleted conversation should disappear within 60 seconds — "Delete for me" propagates to all paired devices via the Vault.
94. Verify the conversation is no longer in Device B's conversations list.

### Post-pairing: Delete conversation on Device B, verify removal from Device A

95. On **Device B**, long-press on the conversation created from B ("Post-pair from B") to open the context menu.
96. Tap "Delete", then confirm deletion in the action sheet.
97. Verify the conversation is removed from Device B's conversations list.

98. On **Device A**, check the conversations list. The deleted conversation should disappear within 60 seconds.
99. Verify the conversation is no longer in Device A's conversations list.

### Final state verification

100. Both devices should have the same conversation count, equal to the post-pairing total minus the 2 deleted conversations.
101. All seed conversations from both devices should still be present and unaffected by the deletions.

## Teardown

No specific cleanup needed — the simulators were started fresh for this test and can be erased for the next test.

## Pass/Fail Criteria

### Pairing
- [ ] Seed conversations created successfully on Device A (5 conversations with checkmark)
- [ ] CLI QA Bot joined seed conversations and sent varied message types
- [ ] Seed conversations created successfully on Device B (3 conversations with checkmark)
- [ ] Device A shows single-device state before pairing
- [ ] Pairing sheet opens with blurred QR code and "Pair new device" title
- [ ] Pairing URL has correct format with `&name=` parameter
- [ ] Device B shows joiner sheet with Device A's name after opening URL
- [ ] Device A generates and displays a 6-digit pin after receiving join request
- [ ] Device B shows pin entry field to enter Device A's pin
- [ ] Both devices show matching 3-emoji fingerprint after pin submission
- [ ] Pairing completes after emoji confirmation — Device A shows "Device added"
- [ ] Devices list on Device A shows both devices (one marked "This device")
- [ ] Device A's conversations list contains all conversations from both devices (count matches)
- [ ] Device B's conversations list contains all conversations from both devices (count matches)
- [ ] Both devices have the same conversation count — no unconsumed unused conversations leaked
- [ ] Synced conversations contain messages (text, reactions, replies, photos from CLI QA Bot)

### Post-pairing: Create
- [ ] Conversation created on Device A appears on Device B within 60 seconds
- [ ] Message "Post-pair from A" is visible when opening the synced conversation on Device B
- [ ] Conversation created on Device B appears on Device A within 60 seconds
- [ ] Message "Post-pair from B" is visible when opening the synced conversation on Device A

### Post-pairing: Delete
- [ ] Deleting a conversation on Device A removes it from Device A's list
- [ ] The deleted conversation disappears from Device B within 60 seconds
- [ ] Deleting a conversation on Device B removes it from Device B's list
- [ ] The deleted conversation disappears from Device A within 60 seconds
- [ ] After both deletions, both devices have the same conversation count
- [ ] Seed conversations are unaffected by the deletions

## Notes

- The seed conversations feature is in Debug settings (non-production only). It creates real conversations using the app's normal flow, generates invites, and emits QA events.
- QA events for seed data follow the format: `[EVENT] app.seed_conversation index=1 id=<conv_id> name=Seed_1 invite_url=<url>`. Read with `sim_log_events(event_filter="qa.seed_conversation")`.
- The CLI `convos conversation send-attachment` command handles inline photos under 1MB. Use `curl -L -o /tmp/qa-photo.jpg https://picsum.photos/400/300` to download a random photo.
- The `InviteJoinRequestsManager` automatically processes join requests via streaming — no manual processing step needed after CLI joins.
- The VaultImportSyncDrainer processes imported inboxes one at a time in the foreground. With ~8 conversations to import, this may take 60-90 seconds after pairing completes. The conversations list updates reactively as each inbox is synced.
- The pairing URL is extracted from the `vault.pairing_url_created` QA event in the app log. Do not use the share sheet "Copy" button — it is unreliable due to iOS share sheet accessibility limitations.
- The emoji fingerprint is derived from `SHA256(sorted(inboxA, inboxB) + pin)` — both devices compute it independently, so matching emoji proves both devices are talking to each other (not an attacker).
- Each simulator generates its own unique vault identity on first launch, so cloned simulators must be erased first to avoid "memberCannotBeSelf" errors from XMTP.
- Pre-pairing message sync depends on XMTP history sync completing its 3-step roundtrip, which may take longer than the test window. The test focuses on conversation metadata sync (names, counts) rather than asserting specific pre-pairing message content.
- "Delete for me" propagates to all paired devices via a `ConversationDeletedContent` message sent through the Vault group. The other device receives it via vault streaming and deletes the conversation locally.
- Post-pairing conversation sync relies on the GRDB inbox observation detecting unshared inboxes and the VaultImportSyncDrainer waking imported inboxes one at a time.
