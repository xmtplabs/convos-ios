---
name: qa-writer
description: Write new QA test sequences for the Convos iOS app. Use when asked to create, draft, or add a new QA test.
---

# QA Test Writer

Create new end-to-end QA test sequences for the Convos iOS app.

## Before Writing a Test

1. Read `qa/RULES.md` in full — it defines conventions, tool usage, error handling, and formatting that all tests must follow.
2. Read `.pi/skills/convos-cli/SKILL.md` for the full CLI command reference — tests reference CLI actions by description, not exact commands.
3. Scan existing tests in `qa/tests/` to understand the style, structure, and level of detail used.
4. Read the relevant source code to understand:
   - What accessibility identifiers exist for the feature being tested (grep for `accessibilityIdentifier` in the relevant views).
   - What the expected UI flow looks like (read the View and ViewModel files).
   - What log output to expect (grep for `Log.info`, `Log.error` in the relevant code).

## Test File Structure

Every test file follows this structure:

```markdown
# Test: <Descriptive Name>

<One-line summary of what this test verifies.>

## Prerequisites

<What state the app/simulator/CLI must be in before running.>

## Setup

<Any data creation or configuration needed before the test steps.>

## Steps

### <Section Name>

1. <Step description — what to do and what to expect.>
2. <Next step.>

### <Next Section>

3. <Continuing step numbers across sections.>

## Teardown

<How to clean up test data — explode conversations, reset state.>

## Pass/Fail Criteria

- [ ] <Criterion 1 — a specific, verifiable assertion>
- [ ] <Criterion 2>

## Accessibility Improvements Needed

<List any UI elements that were hard to find during testing — missing identifiers, elements only reachable by coordinate tap, etc. This section drives accessibility fixes.>
```

## Writing Guidelines

### Be descriptive, not prescriptive

Describe **what** to do and **what to expect**, not the exact tool calls. The QA runner agent knows the tools — it needs to know the intent.

```markdown
<!-- ✅ Good -->
1. Open the invite URL in the simulator as a deep link.
2. The app should show the conversation view with the conversation name.

<!-- ❌ Bad -->
1. Call sim_open_url with url="https://dev.convos.org/v2?i=..."
2. Call sim_wait_for_element with identifier="conversation-name"
```

### Exception: tricky patterns

When a step involves a known-tricky pattern (ephemeral UI, background processes, timing), **do** include the specific technique. Reference the relevant RULES.md section.

```markdown
<!-- ✅ Good — calls out the tricky pattern -->
4. Start `process-join-requests --watch` in a background process, then
   immediately use `sim_tap_id` with retries to catch the quickname pill
   (per ephemeral UI rules in RULES.md).
```

### Step numbering

Number steps sequentially across all sections. This makes it easy to reference steps in pass/fail criteria and failure reports (e.g., "failed at step 7").

### Pass/fail criteria

Each criterion must be:
- **Specific**: "Conversation name 'Test Group' appears in the header" not "conversation loads"
- **Verifiable**: Can be checked via accessibility tree, screenshot, CLI output, or logs
- **Independent**: Each criterion tests one thing — don't combine multiple assertions

### Cover the full lifecycle

Every test should include:
1. **Setup**: Create test data (conversations, messages, invites)
2. **Action**: Perform the feature being tested
3. **Verification**: Check the result in the app AND via CLI/logs
4. **Teardown**: Clean up (explode conversations, remove test data)

### Reference RULES.md for common patterns

Don't repeat rules — reference them:
- Invite processing → "Process the join request (per invite ordering rules in RULES.md)"
- Ephemeral UI → "Tap the quickname pill (per ephemeral UI rules in RULES.md)"
- Log monitoring → "Check for errors (per log monitoring rules in RULES.md)"
- XMTP errors → "Note any XMTP errors but judge pass/fail by app state (per RULES.md)"

### Performance tests

If the test measures timing, specify:
- What `[PERF]` log lines to look for
- How many runs to take (typically 3)
- What the target thresholds are
- The results table format

### Known limitations

Document any known limitations or gotchas at the point where they matter:
- Messages sent before join are hidden by design
- CLI commands that don't support certain flags
- Elements that auto-dismiss (reference ephemeral UI rules)

## Registering the Test

After creating the test file at `qa/tests/XX-name.md`:

1. Add it to the test table in `qa/SKILL.md` under "Available Tests"
2. If it has ordering dependencies, note where it fits in the "Run all tests" sequence
3. Use the next available test number

## Example: Minimal Test

```markdown
# Test: Pin Conversation

Verify that conversations can be pinned and unpinned, and that pinned conversations appear in the pinned section.

## Prerequisites

- The app is running and past onboarding.
- At least two conversations exist in the conversations list.

## Steps

### Pin a conversation

1. Long-press on a conversation in the list to open the context menu.
2. Tap "Pin" in the context menu.
3. The conversation should move to the pinned section at the top of the list.

### Verify pinned state persists

4. Navigate away (open settings) and return to the conversations list.
5. The conversation should still be in the pinned section.

### Unpin the conversation

6. Long-press on the pinned conversation.
7. Tap "Unpin" in the context menu.
8. The conversation should move back to the regular list.

## Teardown

No cleanup needed — pinning is non-destructive.

## Pass/Fail Criteria

- [ ] Context menu shows "Pin" option for unpinned conversations
- [ ] Pinned conversation appears in the pinned section
- [ ] Pinned state persists across navigation
- [ ] Context menu shows "Unpin" option for pinned conversations
- [ ] Unpinning moves the conversation back to the regular list
```
