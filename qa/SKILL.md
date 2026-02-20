---
name: qa
description: Run QA test scenarios for the Convos iOS app. Use when asked to run QA tests, verify app functionality, or execute test scenarios.
---

# QA Test Runner

Run end-to-end QA tests for the Convos iOS app using the iOS simulator tools and the convos CLI.

## Before Running Any Test

1. Read the QA rules document at `qa/RULES.md` in full. It contains general rules, tool references, app details, and conventions that apply to all tests.
2. Read the convos-cli skill at `.pi/skills/convos-cli/SKILL.md` for the full CLI command reference. Tests describe actions in natural language — use the skill file to find the right commands.
3. Verify the app is running on the simulator by taking a screenshot. If it's not running, build and launch it using the run skill at `.pi/skills/run/SKILL.md`.
4. Verify the convos CLI is initialized: run `convos identity list`. If it fails, run `convos init --env dev --force`.

## Available Tests

| Test | File | Description |
|------|------|-------------|
| 01 | `qa/tests/01-onboarding.md` | Fresh onboarding flow (requires simulator erase) |
| 02 | `qa/tests/02-send-receive-messages.md` | Send and receive text, emoji, and attachment messages |
| 03 | `qa/tests/03-invite-join-deep-link.md` | Join a conversation via deep link URL |
| 04 | `qa/tests/04-invite-join-paste.md` | Join a conversation by pasting invite URL in scan view |
| 05 | `qa/tests/05-reactions.md` | React to all message content types |
| 06 | `qa/tests/06-replies.md` | Reply to messages from app and CLI |
| 07 | `qa/tests/07-profile-update.md` | Update display name in a conversation |
| 08 | `qa/tests/08-lock-conversation.md` | Lock conversation and verify invites invalidated |
| 09 | `qa/tests/09-explode-conversation.md` | Explode (destroy) a conversation |
| 10 | `qa/tests/10-pin-conversation.md` | Pin and unpin conversations |
| 11 | `qa/tests/11-mute-conversation.md` | Mute and unmute conversations |
| 12 | `qa/tests/12-create-conversation-from-app.md` | Create conversation from app and invite others |
| 13 | `qa/tests/13-migration.md` | Database migration from main branch to current branch |
| 14 | `qa/tests/14-quickname.md` | Quickname setup, auto-apply, quick edit, My Info override, App Settings edit |
| 15 | `qa/tests/15-performance.md` | Performance baselines: conversation open, create, join timings |
| 16 | `qa/tests/16-conversation-filters.md` | Unread filter, clear filter, empty state, filter persistence |
| 17 | `qa/tests/17-swipe-actions.md` | Mark read/unread via swipe and context menu |
| 18 | `qa/tests/18-delete-all-data.md` | Delete all data flow, confirmation, progress, completion |
| 19 | `qa/tests/19-profile-photo.md` | Profile photo, group photo, sync to other participants |
| 20 | `qa/tests/20-send-receive-photos.md` | Send photos from app, receive from CLI, blur/reveal, context menu |
| 21 | `qa/tests/21-message-gestures.md` | All message gestures: double-tap, swipe reply, long-press menu, link tap, avatar tap |
| 22 | `qa/tests/22-rejoin-existing-conversation.md` | Rejoin existing conversation via deep link or paste in scanner |

## Running Tests

### Run a specific test

When asked to run a specific test (e.g., "run QA test 03"), read the test file and execute the steps in order. Report pass/fail for each criterion.

### Run all tests

When asked to run all tests, execute them in order. Tests 01 (onboarding) should run first since it resets the simulator. Subsequent tests build on a working app state.

Recommended order:
1. **13-migration** — migration test (runs on its own simulator, no side effects)
2. **01-onboarding** — establishes fresh app state
3. **12-create-conversation-from-app** — creates a conversation from the app
4. **03-invite-join-deep-link** — tests joining via deep link
5. **04-invite-join-paste** — tests joining via paste
6. **02-send-receive-messages** — tests messaging in a shared conversation
7. **21-message-gestures** — tests all message gestures (double-tap, swipe, long-press, link tap, avatar tap)
8. **05-reactions** — tests reactions (needs messages to react to)
9. **06-replies** — tests replies (needs messages to reply to)
10. **07-profile-update** — tests profile changes
11. **08-lock-conversation** — tests locking
12. **09-explode-conversation** — tests explosion (destructive, run late)
13. **10-pin-conversation** — tests pinning (needs multiple conversations)
14. **11-mute-conversation** — tests muting
15. **16-conversation-filters** — tests unread filter (needs conversations with mixed read states)
16. **17-swipe-actions** — tests mark read/unread swipe actions
17. **20-send-receive-photos** — tests photo send/receive, blur/reveal, context menu
18. **19-profile-photo** — tests profile and group photos
19. **15-performance** — performance baselines (run last, non-destructive)
20. **18-delete-all-data** — wipes all data (run very last, destructive)

### Reporting

After each test, output:

```
## Test XX: <Test Name>
Status: PASS / FAIL / PARTIAL

### Results
- [x] Criterion 1 — passed
- [ ] Criterion 2 — FAILED: <description of failure>
- [x] Criterion 3 — passed

### Notes
<Any observations, unexpected behavior, or infrastructure issues>

### Accessibility Improvements Needed
<List any UI elements that were hard to find — missing identifiers, coordinate-only taps, etc.>
```

After all tests complete, output a summary table:

```
## QA Summary
| Test | Status | Notes |
|------|--------|-------|
| 01 - Onboarding | PASS | |
| 02 - Messages | PARTIAL | Attachment display issue |
| ... | ... | ... |
```
