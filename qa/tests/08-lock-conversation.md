# Test: Lock Conversation and Verify Invites Invalidated

Verify that locking a conversation prevents new members from joining, and that invites generated before locking no longer work.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

Use the CLI to create a conversation and add the app as a member via the invite flow. The CLI user should be the super admin (creator) of the conversation.

After the app joins, generate a new invite URL from the CLI. Save this invite URL — it will be tested after locking.

## Steps

### Verify the pre-lock invite works (optional sanity check)

1. Confirm that the conversation is not locked. Check the conversation info in the app — there should be no lock icon.

### Generate an invite before locking

2. Use the CLI to generate an invite for the conversation. Save the invite URL or slug.

### Lock the conversation from the CLI

3. Use the CLI to lock the conversation.
4. Wait a few seconds for the lock state to sync.

### Verify lock state in the app

5. In the app, check the conversation view. A lock icon should appear in the top toolbar area.
6. Open conversation info and verify the lock state is reflected (the lock toggle should be on, or the share button should be unavailable).

### Verify the pre-lock invite no longer works

7. Reset the CLI state (remove existing identities) so you can act as a new user trying to join.
8. Re-initialize the CLI for dev environment.
9. Attempt to join the conversation using the invite URL that was generated before locking.
10. The join attempt should fail or be rejected. The invite should not work because the conversation is locked.

### Verify no new invite can be shared from the app

11. In the app, check the conversation info view. The convo code section should show "None" or the share functionality should be disabled.

### Unlock and verify (optional)

12. If the app user is a super admin, unlock the conversation from the conversation info view by toggling the lock.
13. Verify the lock icon disappears and new invites can be generated.

## Teardown

Explode the conversation via CLI (re-initialize with the original identity if needed).

## Pass/Fail Criteria

- [ ] Conversation can be locked via CLI
- [ ] Lock state syncs to the app (lock icon appears)
- [ ] Invites generated before locking do not work after the conversation is locked
- [ ] The app prevents sharing new invites when the conversation is locked
- [ ] Conversation info reflects the locked state
