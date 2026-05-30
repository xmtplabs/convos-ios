# 37b - Agent Contact Consent And Block

Destructive follow-up to test 37, validating the consent-driven feed visibility the
refactor introduced. Runs last in the Agents-as-Contacts sequence, in the same app
session (no relaunch). See `36-agents-as-contacts.md` for the runbook.

## What this guards

| Behavior | Code | Step |
|---|---|---|
| Blocking an agent contact demotes its conversation to `.denied` and hides it from the feed | `ConversationConsentReconciler.fetchMismatchedTargets` (`blockedAt IS NOT NULL AND consent <> .denied` -> `.denied`) | `block_agent_demotes_consent` / `blocked_conversation_hidden_in_feed` |
| The block applies across all instances sharing the templateId | `Contact+CanonicalTemplate.dedupingAgentsByTemplate` block-OR (`blockedTemplateIds`) | `blocked_agent_still_in_browse` |
| A blocked agent stays in the browse list (so it can be unblocked) | `ContactsRepository` returns blocked rows; picker filters via `isPickable: !isBlocked` | `blocked_agent_still_in_browse` |
| **Unblocking does NOT promote `.denied` back to `.allowed`** (blocker-1 fix) | `fetchMismatchedTargets` only promotes `.unknown` -> `.allowed`, never `.denied` | `unblock_does_not_resurrect` |

## Notes

- This is the UI counterpart to the consent blocker-1 fix. The `unblock_does_not_resurrect`
  step exercises the exact state that a **deleted** conversation also lands in
  (delete writes `.denied`, contact may be non-blocked): the reconciler must not
  resurrect a `.denied` conversation via the non-blocked-contact promotion rule.
- Block/unblock is driven from the agent contact card: `contact-detail-block` ->
  confirm "Block" -> `contact-detail-unblock`, and the reverse. Feed visibility is
  observed by the agent-named conversation ("Trip Planner") appearing/disappearing
  from the home conversation list.
- Authoritative coverage of the reconciler logic is the ConvosCore unit suite:
  `ConversationConsentReconcilerTests.testPromotesUnknownButNotDeniedFromNonBlockedContact`
  and `testDemotesAllowedFromBlockedContact`. This test confirms the end-to-end UI
  wiring (block -> reconcile -> feed hide).
- The stale-stranger GC time-based branches (>7-day deletion, engaged-convo
  preservation under time-advance) are not UI-exercisable in one session; they are
  covered by `StaleStrangerGCTests` in the ConvosCore suite.
