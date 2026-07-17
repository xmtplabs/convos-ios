# Test: App Icon Badge Count

Verify that the app icon badge increments when messages arrive while backgrounded, clears when the app is opened, and does not increment for reactions.

## Prerequisites

- The app is running and past onboarding on the primary simulator.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in at least one shared conversation.
- Notification permission has been granted.

## Setup

1. Ensure the app has at least two conversations with the CLI as a participant in each.
2. Open the app and verify no badge is visible on the home screen.

## Steps

### Badge clears on app open

3. Background the app by pressing the Home button.
4. From the CLI, send a text message to one of the conversations.
5. Wait 3-5 seconds for the NSE to process and deliver the notification.
6. Check the app icon badge on the home screen — it should show "1".
7. Tap the Convos app icon to open the app.
8. The badge should clear to 0 immediately — without needing to open the unread conversation.
9. Background the app again and verify no badge is visible.

### Badge increments with multiple messages

10. Background the app.
11. From the CLI, send a message to the first conversation.
12. Wait 3-5 seconds.
13. From the CLI, send a message to the second conversation.
14. Wait 3-5 seconds.
15. Check the badge — it should show "2".
16. Open the app. Badge clears to 0.

### Multiple messages to same conversation

17. Background the app.
18. From the CLI, send 3 messages to the same conversation in quick succession.
19. Wait 5 seconds.
20. Check the badge — it should show "3" (each delivered notification increments the count).
21. Open the app. Badge clears.

### Reactions do not increment badge

22. Background the app.
23. From the CLI, send a text message to a conversation.
24. Wait for the notification.
25. Check the badge — should show "1".
26. From the CLI, send a reaction (e.g., "👍") to that message.
27. Wait for the reaction notification.
28. Check the badge — should still show "1" (reaction did not increment).
29. Open the app. Badge clears.

### Badge persists across app termination

30. Background the app.
31. From the CLI, send a message.
32. Wait for the notification.
33. Force-terminate the app: `xcrun simctl terminate $UDID org.convos.ios-preview`.
34. Check the badge — should still show "1" (NSE set it independently).
35. Launch the app. Badge clears to 0.

## Teardown

No specific teardown needed.

## Pass/Fail Criteria

- [ ] Badge shows 0 (no badge) when app is opened
- [ ] Badge clears to 0 on foreground without requiring user to read conversations
- [ ] Badge increments when messages arrive while backgrounded
- [ ] Badge shows correct count for multiple messages
- [ ] Reactions do not increment the badge
- [ ] Badge persists after app termination
- [ ] Badge clears on next app launch after termination

## Notes

- The NSE badge path requires real push notification delivery, which does not work on the iOS Simulator. These tests must be verified on a physical device for the NSE path.
- On the simulator, the badge-on-background path (app sets badge when entering background based on unread count) can be tested with messages received via the XMTP stream while the app is in the foreground, then backgrounding.
