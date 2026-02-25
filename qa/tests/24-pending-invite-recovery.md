# Test: Pending Invite Recovery After Navigation

Verify that when a joiner navigates away from a pending invite conversation, the invite is still detected and the conversation transitions to active after the inviter approves.

## Prerequisites

- The app is running and past onboarding on the simulator (this is the joiner's device).
- The `convos` CLI is available for creating the inviter identity and processing join requests.
- Two separate identities are needed: the inviter (CLI) and the joiner (simulator).

## Setup

1. Using the CLI, create a new conversation as the inviter and generate an invite link.
2. Note the invite URL for the joiner to scan.

## Steps

### Join via invite and navigate away

1. Open the invite URL in the simulator as a deep link.
2. The app should show the new conversation view with a "Verifying" state or QR code.
3. Wait a few seconds for the join request DM to be sent (check logs for `join_request_sent` event).
4. Navigate back to the conversations list (tap back or swipe).
5. Open a different conversation (or create a new one) so the pending invite's inbox is no longer the active view.

### Approve the invite while joiner is away

6. Using the CLI on the inviter's identity, process pending join requests to approve the joiner.
7. Verify via CLI that the joiner was added to the conversation (member count should be 2).

### Verify recovery

8. Navigate back to the conversations list.
9. The previously pending conversation should now appear as a normal (non-pending) conversation with the correct name.
10. Tap on the conversation to open it.
11. The conversation should be fully functional — the bottom bar should be enabled, messages should be sendable.

### Verify via background/foreground cycle (additional recovery path)

12. If step 9 still shows pending, background the app and bring it back to foreground.
13. After foregrounding, the conversation should transition to active within a few seconds.

## Teardown

Explode both conversations (the test conversation and any helper conversation) using the CLI or app UI.

## Pass/Fail Criteria

- [ ] Join request is sent successfully (log event `invite.join_request_sent`)
- [ ] Navigating away from the pending conversation does not cause errors
- [ ] After the inviter approves, the joiner's conversation transitions from pending to active
- [ ] The conversation is fully functional after recovery (messages can be sent)
- [ ] The transition happens without requiring the user to re-scan the invite code
- [ ] The recovery works even if the app was backgrounded during approval

## Accessibility Improvements Needed

- None identified yet — this test primarily validates backend sync behavior rather than UI elements.
