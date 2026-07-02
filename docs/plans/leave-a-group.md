# Leave a Group

Lets a member remove themselves from a group conversation -- a true self-removal, not just a local hide. This is a platform-agnostic behavior spec (iOS + Android parity).

## Behavior

Entry point: a **Leave** button on the Group Info screen -> confirmation -> the leave action.

The leave action:
1. Removes the current user from the group via the MLS self-removal primitive (`leaveGroup()`).
2. Optimistically hides the conversation locally -- marks it denied/hidden and stops its notifications immediately, so it disappears from the UI while the removal finalizes. The MLS remove-commit may be finalized asynchronously by an authorized client; the UX assumes success.

## Super-admin succession and demotion

The protocol rejects `leaveGroup()` while the leaver is a super admin (super admins cannot be removed from a group). A group must also always keep at least one super admin. So, before leaving:

1. If the leaving member is the **sole** super admin, transfer the super-admin role to another member -- the longest-tenured remaining member, preferring a human; fall back to an agent only if no human members remain.
2. If the leaving member is a super admin (sole or not), demote them from super admin.
3. If the transfer or the demotion fails, abort the leave (never leave a group without a super admin, and never call `leaveGroup()` as a super admin -- the protocol rejects it).

Exception: a sole super admin with no other member to promote is effectively the last member; keep the role and let `leaveGroup()` resolve it (the protocol rejects a 1 -> 0 commit as a benign error and the local hide still applies).

## How the leave propagates (remote visibility)

`leaveGroup()` does not remove the member directly. It publishes a **leave-request message** into the group (content type `xmtp.org/leave_request`); the MLS remove-commit is created later by an authorized client (a super admin's device) when it processes the request. Until that commit lands, the leaver is still in the MLS roster on every device.

Clients therefore key the user-visible departure off the leave-request message, which arrives with normal message latency:

- **Transcript row**: ingest the leave-request as a membership-change update where the sender is both the initiator and the removed member. Render it as "<name> left" ("You left the convo" for the leaver's own devices).
- **Member list**: on ingest, drop the leaver from the local member rows and record a pending-leave marker for `(conversation, inbox)`. Membership re-syncs while the removal is pending must not resurrect the leaver: filter any synced roster against the pending-leave markers.
- **Marker lifecycle**: delete the marker once a synced roster no longer contains the inbox (the removal finalized), and delete it when a membership change re-adds the inbox (rejoin via invite after the removal finalized).

When the remove-commit finalizes, the resulting membership-change message reports the leaver in a dedicated "left" list, separate from admin-initiated removals. Do not render that finalization event: the leave-request already produced the visible row, and rendering both would duplicate the departure in the transcript.

## Self-leave vs admin removal (copy)

The two removal paths stay distinguishable end to end:

| Event | Signal | Copy (other members) | Copy (affected member) |
|---|---|---|---|
| Self-leave | leave-request message (sender == removed member) | "<name> left" | "You left the convo" |
| Admin removal | membership-change commit with removed members (initiator != removed member) | "<name> left · Removed by <initiator>" | "You were removed from the convo" |

A self-leave echo on the leaver's own devices must not set the "removed by someone else" state -- the leave flow already hid the conversation locally.

## Pending state

The removal can stay pending until an authorized client finalizes the remove-commit. While pending:

- Exclude the group from push subscriptions so the leaver stops receiving its notifications right away.
- Other members' devices already render the leaver as gone (see above); no UI should depend on the finalization time.

## Notes for implementers

- The optimistic hide reuses the same local hide + push-unsubscribe already used when declining/hiding a conversation; leaving simply adds the real `leaveGroup()` call on top.
- "Longest-tenured" uses local member join order (the protocol member exposes no join timestamp).
- The protocol's roster query does not filter pending leavers -- the pending-leave marker layer is what keeps member lists consistent between the request and the finalization.
- The conversation must stay fully usable for the remaining members after the creator leaves. No query or hydration path may require the creator to still be a member: dropping the creator's member row must degrade to a placeholder creator identity, never hide the conversation.
- If the group is already gone when the leave runs (another admin removed the user first, or the local group was purged), treat it as success: skip the protocol calls and complete the local hide.
- Only real, committed members are eligible super-admin successors. Presentation-only placeholders (for example optimistic agent members still provisioning) have no network identity and must be excluded from the candidate list.
- Leaving applies to groups only; the affordance is hidden for DMs (the protocol rejects a DM leave).
