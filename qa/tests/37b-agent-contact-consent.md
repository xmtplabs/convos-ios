# 37b - Agent Contact Consent And Block

Destructive follow-up validating consent-driven feed visibility, using the **in-app
agent-builder** agent (no CLI, no invites). Runs last in the Agents-as-Contacts
sequence. See `36-agents-as-contacts.md` for the runbook + prerequisites.

## What this guards

| Behavior | Code | Step |
|---|---|---|
| Blocking an agent contact demotes its conversation to `.denied` and hides it from the feed | `ConversationConsentReconciler.fetchMismatchedTargets` (`blockedAt IS NOT NULL AND consent <> .denied` -> `.denied`) | `block_agent_demotes_consent` / `blocked_conversation_hidden_in_feed` |
| A blocked agent stays in the browse list (so it can be unblocked) | `ContactsRepository` returns blocked rows; picker filters via `isPickable: !isBlocked` | `blocked_agent_still_in_browse` |
| **Unblocking does NOT promote `.denied` back to `.allowed`** (blocker-1 fix) | `fetchMismatchedTargets` only promotes `.unknown` -> `.allowed`, never `.denied` | `unblock_does_not_resurrect` |

## Notes

- Uses an agent built in test 36/37 (e.g. "King's Tutor") that is a visible contact.
  Block/unblock is driven from its contact card: `contact-detail-block` -> confirm
  "Block" -> `contact-detail-unblock`, and the reverse. Feed visibility is observed by
  the agent-named conversation appearing/disappearing from the home list
  (`conversation-list-item-*`).
- `unblock_does_not_resurrect` is the UI counterpart to the consent blocker-1 fix and
  the same code path that prevents a **deleted** conversation (delete writes `.denied`)
  from being resurrected by the non-blocked-contact promotion rule.
- Authoritative reconciler coverage:
  `ConversationConsentReconcilerTests.testPromotesUnknownButNotDeniedFromNonBlockedContact`
  and `testDemotesAllowedFromBlockedContact`. The stale-stranger GC time branches are
  covered by `StaleStrangerGCTests`.
