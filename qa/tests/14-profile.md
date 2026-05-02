# Test: Global Profile + Activate-Sync

Verify the global profile model end-to-end:

1. The user's global profile (display name + avatar) auto-applies to **new** conversations.
2. Editing the global profile in App Settings → My Info propagates to **existing** conversations the next time each one becomes active (activate-sync).
3. The avatar shown in an old conversation does not flicker through the stale cached photo when the global has just changed.

The "Tap to chat as X" pill, the standalone Quickname preset, the post-save "new you in every convo" sheet, and the per-conversation "Use" override button no longer exist.

## Prerequisites

- The app is running and a global profile is already set (run test 01 first if not).
- The convos CLI is initialized for the dev environment.

## Steps

### Part 1: Global profile auto-applies to new conversations

1. Note the current global profile name and avatar (visible in App Settings → My Info).
2. Create a new conversation via the CLI with a name like "Profile Test A" and a profile name for the CLI user.
3. Generate an invite and open it as a deep link in the app. Wait 2–3 seconds for the join request to send.
4. Run the CLI `process-join-requests` command and let it complete. The conversation reaches `.ready` in the app silently — there is no "Tap to chat" pill to dismiss.
5. Verify the composer placeholder shows "Chat as &lt;global display name&gt;" and the avatar next to the composer is the global avatar.
6. Send a message from the app and verify the sent message renders with the global display name and avatar.
7. Use the CLI to inspect the conversation profiles. The app user's profile should show the global display name and an avatar URL.

### Part 2: Edit the global profile from App Settings

8. From the conversations list, tap the Convos settings button (top-left) to open App Settings.
9. Verify the "My info" row shows the lanyard icon, the text "My info", and the current global display name and avatar on the right side. There is **no** footer about "Private unless you choose to share" or "stored on your device".
10. Tap the "My info" row. The My Info view opens.
11. Change the global display name to "Updated QA Name".
12. Optionally change the avatar via the photo picker. The picker pre-selects the current avatar.
13. Navigate back to App Settings. The "My info" row should now show "Updated QA Name" and the new avatar.

### Part 3: Updated global propagates to a NEW conversation

14. Create another conversation via the CLI with a name like "Profile Test B".
15. Generate an invite and open it as a deep link. Wait 2–3 seconds.
16. Run `process-join-requests` and let it complete.
17. Verify the composer placeholder shows "Chat as Updated QA Name" and the new avatar.
18. Send a message and verify it renders with the new name and avatar.
19. Use the CLI to verify the app user's profile in this conversation shows "Updated QA Name" and an avatar URL.

### Part 4: Activate-sync propagates to an EXISTING conversation

This is the new behavior introduced with the global profile model. Existing conversations pick up the new global the next time they become active.

20. Open conversation "Profile Test A" (created in Part 1).
21. Verify the avatar on the user's own messages updates to the new avatar **without flickering through the old cached avatar**. (The in-memory global is shown immediately while the per-conversation row syncs in the background.)
22. Verify the composer placeholder updates to "Chat as Updated QA Name".
23. Send a message and verify it renders with the new name and avatar.
24. Use the CLI to inspect "Profile Test A" profiles. Verify the app user's profile has been updated to the new name and that the avatar URL has changed (new upload).
25. The "Only visible to you" sender preview avatar (when a message is in-flight) should also show the new avatar — not the old one.

### Part 5: Per-conversation override is preserved (regression check)

26. From "Profile Test A", open the conversation info view.
27. Tap the user's own avatar/profile area to enter the per-conversation editor and change ONLY the per-conversation display name to "A-only Name". Save.
28. Verify the composer in "Profile Test A" now shows "Chat as A-only Name".
29. Open App Settings → My Info and confirm the global is **still** "Updated QA Name" — the per-conversation edit must not have overwritten the global.
30. Open "Profile Test B" and verify it still shows "Chat as Updated QA Name" — the per-conversation edit must not have leaked to other conversations.

## Teardown

Explode all conversations created during this test via the CLI.

## Pass/Fail Criteria

### Part 1 — Auto-apply to new conversations

- [ ] No "Tap to chat" pill appears (the pill UI is gone)
- [ ] Composer shows "Chat as &lt;global display name&gt;" and the global avatar in a fresh conversation
- [ ] Sent messages render with the global display name and avatar
- [ ] CLI shows the global profile (name + avatar URL) in the conversation member profiles

### Part 2 — Edit global from App Settings

- [ ] App Settings "My info" row reflects the current global profile
- [ ] No "Private unless you choose to share" footer is shown
- [ ] My Info view edits the global profile
- [ ] App Settings row updates immediately after saving

### Part 3 — New conversation picks up updated global

- [ ] Composer shows the updated global name + avatar in the next new conversation
- [ ] CLI shows the updated profile in that conversation

### Part 4 — Activate-sync for existing conversations

- [ ] Existing conversation's composer updates to the new global name
- [ ] Avatar updates to the new global without flickering through the stale cached photo
- [ ] CLI shows the updated profile in the existing conversation after activation
- [ ] The "Only visible to you" sender-preview avatar shows the new avatar

### Part 5 — Per-conversation override preserved

- [ ] Editing display name from conversation info only affects that conversation
- [ ] Global profile in App Settings is unchanged
- [ ] Other conversations still show the global name
