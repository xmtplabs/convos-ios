# Test: Explode Conversation

Verify that exploding a conversation removes it for all participants under the **single-inbox remove-all-then-leave** model. The creator broadcasts the `ExplodeSettings` message, removes every other member from the MLS group, then leaves the group themselves. Receivers drop the conversation locally on whichever signal arrives first.

> **Single-inbox model (C9, ADR 004 amendment).** This test no longer asserts keychain-entry destruction or XMTP-database deletion — both are correct in the per-conversation-identity world (ADR 002, now superseded), but in the single-inbox world destroying the inbox would wipe the user's entire account. The new pass criteria are: (a) other members are removed from the MLS group, (b) the creator is no longer a member of the group on the network, and (c) the conversation disappears from every participant's local UI.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app user is the **super admin** (conversation creator) so they have permission to remove members and the dedicated explode UI is visible.
- The CLI is joined to the conversation as a regular member, with at least one exchanged message.

## Setup

1. Create a conversation from the app so the app user is the super admin.
2. Generate an invite from the app and have the CLI join via `convos conversation join --invite <slug>`.
3. Exchange at least 2 messages (one from the app, one from the CLI) so the group has content.
4. Confirm the conversation lists 2 members from both the app and the CLI before proceeding.

## Steps

### Open conversation info

1. From the conversation view in the app, open the conversation info screen.
2. Scroll down to find the "Explode now" option. It should be visible because the app user is the super admin.

### Trigger explode

3. Tap "Explode now".
4. A confirmation dialog should appear asking to confirm the destructive action.
5. Confirm the explosion.

### Verify the creator-side flow ran

6. The app plays the explosion animation and navigates back to the conversations list.
7. The exploded conversation **does not appear** in the app's conversations list. (Mechanism: `ConversationExplosionWriter` set `expiresAt = Date()` locally; `ConversationsRepository` filters on `expiresAt > Date()`. The DB row may still exist but is invisible to the UI.)
8. Capture device logs (or use the simulator log query) for the marker `Creator left exploded group: <conversationId>`. Its presence confirms `group.leaveGroup()` succeeded. If only `Failed leaving group after explosion ... Falling back to denied consent` is present, the leave operation hit a network error and fell back to the legacy `updateConsentState(.denied)` path — that's still acceptable but flag it for follow-up.

### Verify member removal on the network

9. Use the CLI to list this conversation's members: `convos conversation members <conversationId>`.
   - Expected: the CLI is no longer in the member list (the creator removed it before leaving).
   - Expected: the creator (app user) is no longer in the member list (the creator left).
   - Expected total members: **0**, or the call may fail with "conversation not found" / "not a member" since the CLI was removed before the read.

### Verify the receiver-side flow on the CLI

10. Use the CLI to list its own conversations: `convos conversations list`.
    - Expected: the exploded conversation does not appear, or appears with an "expired" marker depending on the CLI's current display semantics.
11. Send a message from the CLI to the exploded conversation — `convos conversation send-text <conversationId> "test"`.
    - Expected: the send fails (no longer a member of the group).

### Verify no keychain or account-level damage

12. Open a different conversation from the app (the test setup should have ensured at least one other conversation exists; if not, create one before steps 1-5). Confirm:
    - The conversation opens normally.
    - The user can still send and receive messages.
    - The user's profile / Quickname is unchanged.
    - This confirms the explode did **not** destroy the user's identity — it only removed them from the one exploded group.

## Two-simulator variant (Device B as joiner observing explosion)

When time allows, run a second pass of this test with two simulators:

1. Simulator A is the creator (everything above is performed against A).
2. Simulator B is a separate joiner that joined via invite (instead of the CLI).
3. While Simulator B has the conversation open, trigger the explode on A.
4. Verify on B:
   - The conversation disappears from B's conversations list (mechanism: B receives either the `ExplodeSettings` message or the MLS "removed" event, whichever arrives first; both result in the conversation being filtered out).
   - B's other conversations are unaffected.
   - B's profile / Quickname is unchanged.

## Teardown

The exploded conversation is already cleaned up at the network level. No further cleanup is needed for the test conversation. Any other conversations created during setup can be left in place or exploded individually.

## Pass/Fail Criteria

- [ ] "Explode now" option is visible in conversation info for super admins
- [ ] Confirmation dialog appears before exploding
- [ ] Explosion animation plays after confirming
- [ ] Conversation is removed from the app's conversations list
- [ ] Device logs show `Creator left exploded group` (or, on degraded paths, the fallback `Failed leaving group ... denied consent` message)
- [ ] Other members are removed from the MLS group (CLI member list confirms)
- [ ] CLI participant cannot send to the exploded conversation
- [ ] User's other conversations and profile are unaffected (proves no keychain destruction)
- [ ] *(two-simulator variant)* Joiner sees the conversation disappear from their list
