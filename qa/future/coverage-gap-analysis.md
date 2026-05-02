# QA Coverage Gap Analysis

Comparison of Notion QA plan (Release Candidate 1.0.6) against our automated test suite.

## Legend

- ✅ = Covered by existing automated test
- 🔧 = Partially covered, needs expansion
- ❌ = Not covered, needs new test or addition to existing test
- 🚫 = Cannot automate (requires physical device, multi-device, or hardware)

---

## Category: Message Reactions

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Double tap to like | Critical | 🔧 `05-reactions.md` | Add: double-tap gesture to react (we only test via long-press/CLI) |
| Remove reaction | Critical | ✅ `05-reactions.md` | Covered |
| View reactions drawer | Critical | ❌ | Add to `05-reactions.md`: long-press reaction count, verify drawer shows reactions |
| Reaction sync | Critical | ✅ `05-reactions.md` | Covered (CLI↔app) |
| Own message reaction | High | ❌ | Add to `05-reactions.md`: react to own sent message |
| Sender attribution in drawer | High | ❌ | Add to `05-reactions.md`: verify drawer shows sender names |
| Multiple reactions display | High | ❌ | Add to `05-reactions.md`: have CLI send 3+ different reactions, verify all show |

## Category: Pinned Conversations

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Pin conversation | Critical | ✅ `10-pin-conversation.md` | Covered |
| Unpin conversation | Critical | ✅ `10-pin-conversation.md` | Covered |
| Pin multiple (9 max) | High | ❌ | Add to `10-pin-conversation.md`: pin 5+ conversations, verify all appear |
| Pin persistence | High | ❌ | Add to `10-pin-conversation.md`: pin, kill app, relaunch, verify pins survive |
| Muted icon on pinned | High | ❌ | Add to `10-pin-conversation.md`: mute a conversation, pin it, verify muted icon shows on pinned tile |
| Empty pinned section | Medium | ❌ | Add to `10-pin-conversation.md`: unpin all, verify pinned section disappears |
| Title truncation | Medium | ❌ | Add to `10-pin-conversation.md`: pin conversation with very long name, verify truncation |
| Pinned section animation | Medium | 🚫 | Hard to verify animation via accessibility tree — skip or screenshot-diff |

## Category: Conversation Filters

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Unread filter | High | ❌ | **New test `16-conversation-filters.md`** |
| Muted filter | High | ❌ | Add to new filter test |
| Clear filter | High | ❌ | Add to new filter test |
| Empty filter state | Medium | ❌ | Add to new filter test |
| New message while filtered | Medium | ❌ | Add to new filter test |
| Filter persistence in session | Low | ❌ | Add to new filter test |

## Category: Swipe Actions

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Mute via swipe | High | 🔧 `11-mute-conversation.md` | Covered |
| Unmute via swipe | High | 🔧 `11-mute-conversation.md` | Covered |
| Mark as unread | High | ❌ | **New test `17-swipe-actions.md`** or add to existing |
| Mark as read | High | ❌ | Add to swipe actions test |

## Category: Lock Conversation

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Lock (super admin) | Critical | ✅ `08-lock-conversation.md` | Covered |
| Confirm lock action | Critical | 🔧 `08-lock-conversation.md` | Add: verify lock icon appears, invite link hidden |
| Lock state sync | Critical | 🔧 `08-lock-conversation.md` | We verify via app UI; add: verify lock icon visible in conversation info |
| Invite invalidation on lock | Critical | ✅ `08-lock-conversation.md` | Covered |
| Unlock conversation | Critical | ❌ | Add to `08-lock-conversation.md`: unlock after locking |
| New invite after unlock | High | ❌ | Add: generate new invite after unlock, verify it works |
| Old invite still invalid after unlock | High | ❌ | Add: verify old invite still doesn't work after unlock |
| Non-admin cannot lock | High | ❌ | Add: join as regular member, verify no lock option |
| Unlock state sync | High | ❌ | Add: unlock, verify other side sees unlocked state |

## Category: Encrypted Images & Privacy

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Set profile picture | Critical | ❌ | **Add to `07-profile-update.md`**: set profile photo, verify it displays |
| Set group photo | Critical | ❌ | **New test or add to existing**: set group photo in conversation info |
| Profile image update sync | High | ❌ | Add: change profile picture, verify CLI/other members see it |
| Public preview toggle on | High | ❌ | **New test `18-public-preview.md`** or add to conversation info test |
| Public preview toggle off | High | ❌ | Add to public preview test |
| Emoji avatar persistence | High | ❌ | Lower priority — hard to test without multi-device |
| Photo replaces emoji avatar | High | ❌ | Lower priority |

## Category: Delete All Data

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Initiate delete all | High | ❌ | **New test `19-delete-all-data.md`** |
| Delete in progress indicator | High | ❌ | Add to delete test |
| Delete completion | Critical | ❌ | Add: verify returns to onboarding |
| No stuck deleting state | Critical | ❌ | Add: verify no lingering state |

## Category: Notifications

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Tap notification clears it | Critical | 🚫 | Simulator push notifications require setup — defer |
| Sender name in preview | High | 🚫 | Requires push notification infrastructure |
| Multiple notifications cleared | High | 🚫 | Requires push notification infrastructure |
| No notification for active convo | Critical | 🚫 | Requires push notification infrastructure |
| No notification on home screen | Critical | 🚫 | Requires push notification infrastructure |
| Cold launch from notification | High | 🚫 | Requires push notification + app kill + relaunch |

## Category: Performance

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Message list scroll | High | 🔧 `15-performance.md` | We measure open time; add: scroll performance check (send 100+ messages, scroll up/down, check for hitches) |
| Conversation list scroll | High | ❌ | Add to `15-performance.md`: create 20+ conversations, scroll rapidly |
| Avatar loading during scroll | High | ❌ | Add: scroll through conversations with different avatars |

## Category: Profile

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Profile onboarding | High | ✅ `14-profile.md` + `01-onboarding.md` | Covered |
| "Tap to use Profile" flow | High | 🔧 `14-profile.md` | Covered but known bug — profile pill doesn't appear on invite join |
| Set Profile | High | ✅ `14-profile.md` | Covered |

## Category: Regression - Profile

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Set Profile applies to new convos | High | ✅ `14-profile.md` | Covered |
| Per-conversation profile isolation | High | ❌ | **Add to `07-profile-update.md`**: change name in one convo, verify other convo still shows old name |

## Category: Conversation Capacity

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Join request to full convo | High | 🚫 | Requires 50+ members — impractical for automated test |
| Full conversation warning | High | 🚫 | Same |
| Capacity display | Medium | ❌ | Add to conversation info test: verify member count shown |

## Category: Edge Cases

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| Upgrade migration | Critical | ✅ `13-migration.md` | Covered |
| Large conversation (50+ members) | Medium | 🚫 | Impractical for automated test |
| Network loss during operation | Medium | 🚫 | Simulator can't easily toggle network mid-operation |

## Category: UI Polish

| Notion Test | Priority | Our Coverage | Action |
|---|---|---|---|
| QR scan functionality | High | ❌ | Can't scan QR from simulator, but can test paste flow (already `04-invite-join-paste.md`) |

---

## Recommended New Tests (Priority Order)

### New test files to create

| # | Test | Covers | Notion Items |
|---|---|---|---|
| 16 | `16-conversation-filters.md` | Unread/muted filters, clear, empty state, persistence | 6 items |
| 17 | `17-swipe-actions.md` | Mark read/unread via swipe | 2 items |
| 18 | `18-delete-all-data.md` | Initiate, progress, completion, no stuck state | 4 items |
| 19 | `19-profile-photo.md` | Set profile picture, set group photo, sync | 3 items |

### Expand existing tests

| Test | Items to Add |
|---|---|
| `05-reactions.md` | Double-tap to react, own message reaction, reactions drawer, sender attribution, multiple reactions display |
| `07-profile-update.md` | Per-conversation profile isolation |
| `08-lock-conversation.md` | Unlock, new invite after unlock, old invite still invalid after unlock, non-admin cannot lock |
| `10-pin-conversation.md` | Pin multiple (9 max), pin persistence across app restart, muted icon on pinned, empty pinned section, title truncation |
| `15-performance.md` | Message list scroll performance, conversation list scroll performance |

### Cannot automate (defer)

- Notifications (6 items) — requires push notification infrastructure on simulator
- Conversation capacity (2 items) — requires 50+ members
- Network loss (1 item) — can't toggle network mid-operation
- QR scan (1 item) — can't scan QR on simulator (paste flow already covered)
- Large conversation (1 item) — impractical member count
- Animation verification (1 item) — accessibility tree can't verify animations

---

## Summary

| Status | Count |
|---|---|
| Already covered | 18 |
| Needs expansion of existing test | 17 |
| Needs new test | 15 |
| Cannot automate | 12 |
| **Total from Notion** | **62** |

**Biggest wins (most coverage per effort):**
1. Expand `05-reactions.md` — 5 new criteria
2. Expand `08-lock-conversation.md` — 4 new criteria (unlock flow)
3. New `16-conversation-filters.md` — 6 criteria, all new coverage
4. Expand `10-pin-conversation.md` — 5 new criteria
5. New `18-delete-all-data.md` — 4 criteria, critical flow not covered at all
