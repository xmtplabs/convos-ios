# 40b - DM Block Demotes Creator's Conversation (two simulators)

The consent-driven feed-visibility test, validated where it applies: **blocking the
CREATOR** of a conversation. Runs after test 40, reusing the A<->B DM (Device A is the
creator, Device B is the joiner, each is the other's contact). Two simulators.

## What this guards

| Behavior | Code | Step |
|---|---|---|
| Blocking the conversation creator demotes it to `.denied` and hides it from the feed | `ConversationConsentReconciler.fetchMismatchedTargets` (`blockedAt IS NOT NULL AND consent <> .denied` -> `.denied`) | `device_b_block_alice` / `device_b_conversation_demoted` |
| **Unblocking does NOT promote `.denied` back to `.allowed`** (blocker-1 fix) | reconciler only promotes `.unknown` -> `.allowed` | `device_b_unblock_does_not_resurrect` |

## Why this test exists (and how it differs from 37b)

The consent reconciler is **creator-based**. Blocking a non-creator member (e.g. an
agent you built, in a conversation you created) writes the block but leaves the
conversation - "existing shared groups are unaffected" (see test 37b). The demotion
only fires when the blocked contact is the conversation's **creator**.

In the DM from test 40, **Device A created** the conversation, so:
- Device B blocking **Alice** (the creator) demotes B's conversation to `.denied`
  (leaves B's feed).
- Unblocking Alice does NOT resurrect it (the demoted `.denied` stays; only `.unknown`
  is ever promoted). This is the blocker-1 fix - the same path that stops a deleted
  conversation (delete writes `.denied`) from coming back.

This is the UI counterpart to `ConversationConsentReconcilerTests`. See
`40-dm-members-as-contacts.md` for the two-simulator runbook + App Check prereqs.

## Status

Validated green end-to-end on two simulators against the local stack, reusing test
40's A<->B DM (Device A "Alice" is the creator). All four criteria passed:

- **Baseline**: Device B's feed showed the Alice conversation.
- **Block the creator**: Device B blocked Alice; her card flipped to Blocked/Unblock
  and she stayed in B's browse list (Contacts count unchanged) so she can be unblocked.
- **Demotion**: the Alice conversation left Device B's feed (only the unrelated "New
  Convo" draft remained) - demoted to `.denied` because the blocked contact is the
  conversation's creator. This is the demotion that does NOT fire when blocking a
  non-creator member (test 37b).
- **No resurrection on unblock**: unblocking Alice flipped the card back to Block but
  the conversation stayed absent from the feed - the reconciler only promotes
  `.unknown -> .allowed`, never `.denied` (the blocker-1 fix).

Confirms `ConversationConsentReconciler.fetchMismatchedTargets` end to end and matches
`ConversationConsentReconcilerTests`.
