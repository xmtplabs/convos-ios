# Leave a Group

Lets a member remove themselves from a group conversation -- a true self-removal, not just a local hide. This is a platform-agnostic behavior spec (iOS + Android parity).

## Behavior

Entry point: a **Leave** button on the Group Info screen -> confirmation -> the leave action.

The leave action:
1. Removes the current user from the group via the MLS self-removal primitive (`leaveGroup()`).
2. Optimistically hides the conversation locally -- marks it denied/hidden and stops its notifications immediately, so it disappears from the UI while the removal finalizes. The MLS remove-commit may be finalized asynchronously by an authorized client; the UX assumes success.

## Super-admin succession

A group must always keep at least one super admin. If the leaving member is the sole super admin:

1. Before leaving, transfer the super-admin role to another member -- the longest-tenured remaining member, preferring a human; fall back to an agent only if no human members remain.
2. If the transfer fails, abort the leave (never leave a group without a super admin).

## Pending state

The removal can stay pending until an authorized client finalizes the remove-commit. While pending, exclude the group from push subscriptions so the user stops receiving its notifications right away.

## Notes for implementers

- The optimistic hide reuses the same local hide + push-unsubscribe already used when declining/hiding a conversation; leaving simply adds the real `leaveGroup()` call on top.
- "Longest-tenured" uses local member join order (the protocol member exposes no join timestamp).
- Distinguishing a self-leave from being removed by an admin (for UI copy) is a follow-up.
