---
description: Author a new QA test for the Convos iOS app (both structured YAML + markdown documentation).
---

# /qa-writer

Write a new QA test end-to-end: structured YAML that agents execute, matching markdown for humans, and suite-registry updates.

## Usage

Describe what the test should cover. Examples:

```
/qa-writer test for conversation archive flow
/qa-writer verify that muted conversations still receive badge updates
/qa-writer regression test for the quickname banner on joined conversations (test 14 FAIL)
```

## Before writing

1. **Read the contract and conventions:**
   - `qa/skills/qa-writer/SKILL.md` — full style guide for test authoring (descriptive-not-prescriptive language, step numbering, pass/fail criteria, teardown, lifecycle coverage).
   - `qa/RULES.md` — the runner-side contract the test must fit into (error classification, ephemeral UI, invite ordering, pasteboard safety).
   - `qa/tests/structured/README.md` — structured YAML action vocabulary and verify/criteria semantics.
   - `qa/TOOLS-CLAUDE.md` — translation table from pi's `sim_*` vocabulary to Claude-side tooling. Write YAMLs against pi vocabulary — the translation is the runner's job, not the test author's.
2. **Scan neighbors.** Read 2–3 existing tests from `qa/tests/structured/` in the feature area you're writing about. Match their level of detail, naming, and idioms.
3. **Inspect the source.** `grep -rn accessibilityIdentifier` in the relevant views to find stable ids. `grep -rn 'Logger\.' Convos/ ConvosCore/` to find `[EVENT]` and error signals the test can assert on.
4. **Pick the test id.** `ls qa/tests/structured/ | grep -oE '^[0-9]+[a-z]?' | sort -u | tail -5` — use the next free number. Suffix with a letter (e.g., `23b`) only for tightly-related follow-ups to an existing test.

## What to write

Produce three things in this order:

### 1. `qa/tests/structured/<id>-<kebab-name>.yaml`

The executable form. Fields:

```yaml
id: "<id>"
name: "<Human Name>"
description: >
  Two-to-four-sentence summary of what the test verifies and why.
tags: [<area>, <feature>, ...]
depends_on: ["<id>"]            # tests that must pass first
estimated_duration_s: <int>     # realistic wall-clock; informs orchestrator budget

prerequisites:
  app_running: true
  cli_initialized: true
  shared_conversation: true     # or false if the test sets up its own
  screen: conversations_list    # or conversation_detail, settings, profile_editor

state:
  <key>: null                   # things the test populates and persists to CXDB

setup:
  - action: <from vocabulary>
    args: { ... }
    save: <state_key>

steps:
  - id: <snake_case>
    name: "<Human-readable step name>"
    actions:
      - <action>: { ... }
      - wait_for_element: { ... }
    verify:
      - <check>: { ... }
    criteria: <criterion_key>
    note: >
      Optional hint about tricky behavior the agent should know.

teardown:
  - action: explode_conversation
    args: { id: "$conversation_id" }
    optional: true              # transient CLI errors on teardown are common

criteria:
  <criterion_key>:
    description: "<Verifiable assertion>"
```

Use the action vocabulary in `qa/tests/structured/README.md` "Action Vocabulary". Pick verify checks (`element_exists`, `element_count_gte`, `element_near`, `cli_output_contains`, `clipboard_contains`, `expect_event`) that match the assertion shape.

### 2. `qa/tests/<id>-<kebab-name>.md`

The human-readable form — same structure as existing `qa/tests/*.md` per `qa/skills/qa-writer/SKILL.md`. Write this second; it's a narrative of the YAML.

### 3. Registry updates

- Add the test to the "Available Tests" table in `qa/SKILL.md` and `.pi/skills/qa/SKILL.md` (both tables should match).
- If the test has ordering dependencies (destructive, shared-state sensitive, or depends on another), update the canonical order in `.claude/commands/qa.md` "Ordering and parallelism".

## Writing principles

Taken from `qa/skills/qa-writer/SKILL.md` — these are the ones that matter most:

- **Descriptive, not prescriptive.** Say "Tap the compose button and wait for the new conversation view." Don't say "Call `tap` with accessibilityId `compose-button`, then loop on `ui_find_element` for `message-text-field`." The runner knows its tools.
- **Exception: tricky patterns.** For ephemeral UI, background processing, multi-sim coordination, or timing-sensitive flows, *do* call out the specific pattern and reference the RULES section.
- **Every criterion must be specific, verifiable, and independent.** "Conversation name 'Test Group' appears in the header" — not "the conversation loads correctly."
- **Reference RULES, don't repeat it.** "Process the join request (per invite ordering rules in RULES.md)" instead of restating the sequence.
- **Always include teardown.** Mark it `optional: true` if CLI teardown commonly hits transient errors.
- **Performance tests** specify `[PERF]` log patterns to match, number of runs (typically 3), target thresholds, and result table format.

## After writing

1. Run the test: `/qa <id>`. The first run usually surfaces vocabulary gaps, wrong accessibility ids, or missed edge cases.
2. Update the YAML until it's reliable. Don't leave a flaky test in the suite — either fix it, mark criteria `known_issue: "<description>"`, or document a `note:`.
3. Add an entry to `qa/tests/structured/README.md` "Validated Tests" when it's green.
