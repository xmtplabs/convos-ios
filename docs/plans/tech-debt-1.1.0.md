# Technical Debt Paydown Plan: Post-1.1.0 Release

**Created:** 2026-02-24  
**Context:** Between 1.0.6 and 1.1.0, we shipped 80 commits with 35K lines added. This plan identifies accumulated technical debt and prioritizes paydown work.

## Summary

| Priority | Task | Effort | Status |
|----------|------|--------|--------|
| 1 | [Document inbox lifecycle state machine](#1-document-inbox-lifecycle-state-machine) | S | ✅ Done (PR #525) |
| 2 | [Extract explosion handling from ConversationViewModel](#2-extract-explosion-handling-from-conversationviewmodel) | S | ✅ Done (PR #526) |
| 3 | [Extract photo handling from ConversationViewModel](#3-extract-photo-handling-from-conversationviewmodel) | M | ❌ Dropped (not worth the risk) |
| 4 | [Audit UnusedConversationCache for edge cases](#4-audit-unusedconversationcache-for-edge-cases) | M | ✅ Done (no issues found) |
| 5 | [Add integration tests for inbox state transitions](#5-add-integration-tests-for-inbox-state-transitions) | M | ✅ Done (already covered) |
| 6 | [Review Agent POC architecture](#6-review-agent-poc-architecture) | L | 🔲 TODO |

---

## High Priority Areas

### 1. Document inbox lifecycle state machine

**Effort:** Small  
**Files:** `InboxLifecycleManager.swift`, `InboxStateMachine.swift`, `ConversationStateMachine.swift`

**Problem:**  
The inbox/conversation state management has become complex with multiple interacting state machines. Between 1.0.6 and 1.1.0, we had 6+ fixes related to:
- LRU eviction edge cases
- Pending invite lifecycle
- Duplicate MessagingService creation (fixed, reverted, re-fixed)
- Protection window timing issues

**Deliverable:**  
Create `docs/adr/0XX-inbox-lifecycle-architecture.md` with:
- State diagram showing inbox states (sleeping, awake, pending invite)
- Sequence diagram for common flows (wake, sleep, evict, create)
- Documentation of protection windows and their purpose
- Edge cases and their handling

**Success criteria:**  
A new engineer can understand the inbox lifecycle by reading the ADR.

---

### 2. Extract explosion handling from ConversationViewModel

**Effort:** Small  
**Files:** `ConversationViewModel.swift` (1186 lines)

**Problem:**  
`ConversationViewModel` has become a god object handling too many concerns. Explosion (time bomb) handling is self-contained and can be extracted.

**Current explosion-related code in ConversationViewModel:**
- `expiresAt` property observation
- `scheduleExplosion()` method
- `cancelExplosion()` method
- Explosion countdown UI state
- `ExplodeConvoSheet` presentation logic

**Deliverable:**  
Create `ConversationExplosionViewModel` or `ExplosionCoordinator` that:
- Owns explosion scheduling logic
- Manages countdown state
- Exposes simple API to parent ViewModel

**Success criteria:**  
- ConversationViewModel reduced by ~50-100 lines
- Explosion logic is testable in isolation
- No behavior changes

---

### 3. Extract photo handling from ConversationViewModel

**Effort:** Medium  
**Files:** `ConversationViewModel.swift`, related photo views

**Status:** ❌ **Dropped - not worth the risk**

**Assessment (2026-02-24):**
- Would only save ~100-150 lines (1186 → ~1050)
- Photo state is intertwined with conversation state (e.g., `selectedAttachmentImage` affects `sendButtonEnabled`)
- Risk of introducing bugs in a working feature outweighs the benefit
- Unlike explosion handling (self-contained state machine), photo handling has unclear boundaries

**Conclusion:** The juice isn't worth the squeeze.

---

## Medium Priority Areas

### 4. Audit UnusedConversationCache for edge cases

**Effort:** Medium  
**Files:** `UnusedConversationCache.swift` (955 lines)

**Status:** ✅ **Audit complete - no issues found**

**Audit findings (2026-02-24):**
- Test coverage is comprehensive (~1300 lines across 3 test files)
- Race conditions prevented by Swift actor isolation
- Edge cases handled defensively (orphan cleanup, stale data detection, graceful degradation)
- No bug fixes in git history since component was added
- Unlike InboxLifecycleManager issues (LRU eviction, pending invites), this component is focused and stable

**Conclusion:** No changes needed. The "similar caching issues" we saw were actually different problems in InboxLifecycleManager.

---

### 5. Add integration tests for inbox state transitions

**Effort:** Medium  
**Files:** Test suite

**Status:** ✅ **Already comprehensively covered**

**Audit findings (2026-02-24):**

Existing test coverage (4,341 lines):
- `InboxLifecycleManagerTests` (1,596 lines) - Wake/sleep, LRU, pending invites, rebalance, race conditions
- `InboxStateMachineTests` (869 lines) - Register, authorize, stop, delete, background/foreground
- `ConversationStateMachineTests` (1,876 lines) - Create, join, useExisting, message queuing
- `SleepingInboxMessageCheckerIntegrationTests` - Real XMTP with Docker

The "flaky test" fixes were about test quality, not coverage gaps:
- `b42e206` - Test interference from shared notification IDs (isolation issue)
- `535705e` - Clock skew with XMTP backend (timing issue)
- `5829ad9` - Fixed delays instead of polling (timing issue)

**Conclusion:** No additional tests needed. Coverage is comprehensive and flakiness has been fixed.

---

### 6. Review Agent POC architecture

**Effort:** Large  
**Files:** Agent UI views, `ConversationViewModel.swift` (assistant join logic)

**Status:** 🔲 **Deferred - still behind feature flag**

**Note:** This refers to the "Add assistant to conversation" feature (#476, #503), not the QA automation server (which was confusingly named `AgentServer` and has been renamed to `QAAutomationServer` in PR #527).

**Problem:**  
The assistant/agent feature was added as a POC behind a debug flag. Before removing the flag:
- Architecture needs review
- Security implications need assessment
- Integration with existing systems needs validation

**Deliverable:**  
- Architecture review document
- Security assessment
- Decision: ship, iterate, or remove

**Success criteria:**  
Clear go/no-go decision with documented rationale

---

## Evidence of Debt (Reference)

### Files with highest churn (fixes):
- `InboxLifecycleManager.swift` - 6+ related fixes
- `ConversationStateMachine.swift` - multiple state fixes
- Pending invite handling - scattered across PRs

### Largest files (complexity risk):
1. `MessagesLayoutStateController.swift` - 1369 lines
2. `ConversationViewModel.swift` - 1186 lines  
3. `ImageCache.swift` - 1172 lines
4. `InboxStateMachine.swift` - 1104 lines
5. `MessagesCollectionLayout.swift` - 1081 lines

### Features shipped in 1.1.0:
- Photos (send/receive with encryption)
- Replies
- Scheduled explosion (time bomb)
- Persistent photo cache
- Asset renewal
- Pending invites in home view
- Agent POC
- Reactions v2 codec
- Accessibility improvements

---

## Retrospective (2026-02-24)

**Final tally: 2 of 6 items required work**

| Item | Outcome |
|------|---------|
| 1. Document inbox lifecycle | ✅ Done - Added state diagrams to ADR 003 (PR #525) |
| 2. Extract explosion handling | ✅ Done - Created ExplosionCoordinator (PR #526) |
| 3. Extract photo handling | ❌ Dropped - Risk outweighs benefit |
| 4. Audit UnusedConversationCache | ✅ Already good - comprehensive test coverage |
| 5. Inbox state integration tests | ✅ Already good - 4,341 lines of tests exist |
| 6. Review Agent POC | 🔲 Deferred - still behind feature flag |

**Bonus:** Renamed `AgentServer` → `QAAutomationServer` (PR #527) to fix confusing naming.

**Lessons learned:**
1. "Churn" in git history doesn't always indicate technical debt - sometimes it's just iteration
2. Existing test coverage was better than assumed
3. Refactoring for the sake of smaller files can introduce more risk than it solves
4. Audit before acting - most "debt" items turned out to be non-issues
