# 37b - Agent Contact Block And Unblock

Block/unblock for an agent contact built via the in-app agent-builder. Runs after
test 37. See `36-agents-as-contacts.md` for the runbook + prerequisites.

## What this guards

| Behavior | Code | Step |
|---|---|---|
| Block writes the block; card shows Blocked + Unblock | `ContactsWriter` blockedAt + `ContactDetailView` | `block_agent_writes_and_flips` |
| A blocked agent stays in the browse list (so it can be unblocked) | `ContactsRepository` returns blocked rows | `blocked_agent_stays_in_browse` |
| Unblock restores the contact (card flips back to Block) | `ContactsWriter` clears blockedAt | `unblock_restores` |

## Important: consent demotion is creator-based (validated live)

Blocking an agent built via the agent-builder writes the block and removes the agent
from the add-to-conversation picker (`isPickable: !isBlocked`), **but does not hide the
conversation** - because the conversation was created by **you** (the agent is a
member, not the creator). The block dialog says so explicitly: *"They won't be able to
start new conversations with you. Existing shared groups are unaffected."*

So the consent feed-demotion (`.allowed -> .denied`) and the blocker-1
no-resurrect-on-unblock apply only when you block the **creator** of a conversation
(an unsolicited inbound / a DM the other party created). That path is validated by:

- `ConversationConsentReconcilerTests.testDemotesAllowedFromBlockedContact` and
  `testPromotesUnknownButNotDeniedFromNonBlockedContact` (unit).
- **Test 40b** (two simulators): Device B blocks Device A (the conversation creator);
  B's conversation demotes to `.denied` and leaves the feed, and unblocking does not
  resurrect it.

This test (37b) therefore covers only the block-itself mechanics, which were validated
live on the local stack (block -> "Blocked" badge + Unblock affordance -> Unblock ->
back to Block) with an agent-builder agent ("King's Tutor").
