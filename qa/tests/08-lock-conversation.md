# Test: Lock and Unlock Conversation

Verify that locking a conversation prevents new members from joining, invites are invalidated, non-admins cannot lock, and unlocking restores invite generation while old invites remain invalid.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

Use the CLI to create a conversation with a name like "Lock Test" and add the app as a member via the invite flow. The CLI user should be the super admin (creator).

After the app joins, generate a new invite URL from the CLI. Save this URL for testing after lock.

## Steps

### Verify pre-lock state

1. In the app, open the conversation and verify no lock icon appears in the toolbar.
2. Open conversation info and verify the lock toggle is off.

### Generate an invite before locking

3. Use the CLI to generate an invite. Save the invite URL.

### Lock the conversation from the CLI

4. Use the CLI to lock the conversation.
5. Wait a few seconds for the lock state to sync.

### Verify lock state syncs to the app

6. In the app, verify a lock icon appears in the conversation toolbar area.
7. Open conversation info and verify the lock toggle is on or the share button is unavailable.
8. Verify the conversation info reflects the locked state (e.g., no invite section, or "locked" label).

### Verify the pre-lock invite no longer works

9. Reset the CLI state (`rm -rf ~/.convos/identities ~/.convos/db`).
10. Re-initialize the CLI for dev.
11. Attempt to join using the saved pre-lock invite URL.
12. The join attempt should fail or be rejected because the conversation is locked.

### Verify non-admin cannot lock

13. The app user (who joined as a regular member) should check conversation info. Verify the lock option is either not visible or shows an explanation that only super admins can lock.

### Unlock the conversation

14. Re-initialize the CLI with the original creator identity (or use a second CLI identity that is the super admin).
15. Use the CLI to unlock the conversation.
16. Wait a few seconds for the unlock state to sync.

### Verify unlock state syncs to the app

17. In the app, verify the lock icon disappears from the toolbar.
18. Open conversation info and verify the lock toggle is off and sharing is available again.

### Verify old invite still invalid after unlock

19. Attempt to join using the same pre-lock invite URL (from step 3).
20. The join should still fail — unlocking does not restore previously invalidated invites.

### Verify new invite works after unlock

21. Use the CLI to generate a new invite after unlocking.
22. Reset CLI state again and re-initialize.
23. Join using the new invite URL.
24. The join should succeed — the conversation is unlocked and the new invite is valid.

## Teardown

Explode the conversation via CLI (re-initialize with the creator identity if needed).

## Pass/Fail Criteria

- [ ] Pre-lock state: no lock icon, lock toggle off
- [ ] Lock state syncs to the app (lock icon appears in toolbar)
- [ ] Conversation info reflects locked state
- [ ] Pre-lock invite does not work after locking
- [ ] App prevents sharing new invites when locked
- [ ] Non-admin cannot lock (option not available or explanation shown)
- [ ] Unlock state syncs to the app (lock icon disappears)
- [ ] Old invite still invalid after unlock
- [ ] New invite works after unlock
