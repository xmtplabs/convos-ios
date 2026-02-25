# Technical Debt Paydown Plan: Post-1.1.0 Release

**Created:** 2026-02-24  
**Context:** Between 1.0.6 and 1.1.0, we shipped 80 commits with 35K lines added. This plan identifies accumulated technical debt and prioritizes paydown work.

## Summary

| Priority | Task | Effort | Status |
|----------|------|--------|--------|
| 1 | [Document inbox lifecycle state machine](#1-document-inbox-lifecycle-state-machine) | S | ✅ Done (PR #525) |
| 2 | [Extract explosion handling from ConversationViewModel](#2-extract-explosion-handling-from-conversationviewmodel) | S | ✅ Done (PR #526) |
| 3 | [Extract photo handling from ConversationViewModel](#3-extract-photo-handling-from-conversationviewmodel) | M | 🔲 TODO |
| 4 | [Audit UnusedConversationCache for edge cases](#4-audit-unusedconversationcache-for-edge-cases) | M | ✅ Done (no issues found) |
| 5 | [Add integration tests for inbox state transitions](#5-add-integration-tests-for-inbox-state-transitions) | M | 🔲 TODO |
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

**Problem:**  
Photo sending/receiving was a major 1.1.0 feature that added significant complexity to ConversationViewModel:
- Photo picker state
- Upload progress tracking
- Photo message composition
- Photo preferences (blur, visibility)

**Deliverable:**  
Create `ConversationMediaViewModel` that:
- Manages photo picker presentation
- Tracks upload progress
- Handles photo preferences
- Coordinates with `PhotoAttachmentService`

**Success criteria:**  
- ConversationViewModel reduced by ~100-150 lines
- Photo logic testable in isolation
- Clear separation of concerns

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

**Problem:**  
Multiple test flakiness fixes indicate our inbox state tests may not adequately cover real-world scenarios:
- "Fix flaky CI tests"
- "Fix sleeping inbox test flakiness due to clock skew"
- "Fix test interference from shared notification IDs"

**Deliverable:**  
- Create integration test suite for inbox lifecycle
- Test multi-inbox scenarios (wake A, sleep B, evict C)
- Test edge cases (rapid wake/sleep, concurrent operations)
- Use deterministic time for clock-sensitive tests

**Success criteria:**  
- No flaky inbox-related tests for 2 weeks
- Coverage of all documented state transitions

---

### 6. Review Agent POC architecture

**Effort:** Large  
**Files:** `AgentServer.swift` (970 lines), agent UI

**Problem:**  
The agent feature was added as a POC behind a debug flag. Before removing the flag:
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
