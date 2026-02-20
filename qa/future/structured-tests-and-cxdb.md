# Structured Tests & CXDB Integration

An intermediate step between "agent reads markdown and improvises" and "full Kilroy/Attractor pipeline." The goals:

1. **Convert test prose into structured, executable steps** so the agent does less interpretation and more execution
2. **Store test results, device logs, and findings in CXDB** so they persist across context windows
3. **Enable incremental runs** — resume after context reset, re-run failures only, compare across runs

## Problem

Today's QA flow:
```
Agent reads .md → interprets prose → calls sim tools → takes screenshots → fills context → hits limit
```

This breaks at ~5-8 tests per context window. The agent spends most of its tokens on:
- Re-reading test prose it's seen before
- Taking screenshots to verify things the accessibility tree could answer
- Holding intermediate state (conversation IDs, invite URLs, element coordinates) in context
- Repeating the same setup/teardown patterns

## Proposal: Structured Test Format

Convert each `.md` test into a structured format that separates **what to do** from **what to verify**. The agent still executes — it's not a dumb script runner — but the structure eliminates interpretation overhead and enables persistent state.

### Test Definition (YAML)

```yaml
# qa/tests/05-reactions.yaml
id: "05"
name: "Reactions"
depends_on: ["01"]  # needs onboarding complete
tags: ["messaging", "reactions", "core"]

prerequisites:
  - app_running: true
  - cli_initialized: true
  - shared_conversation: true  # agent ensures this, reusing from prior test or creating new

state:
  # Keys the agent populates during execution — persisted to CXDB
  - conversation_id: null
  - cli_text_msg_id: null
  - app_text_msg_id: null

setup:
  - action: cli_send_text
    args: { text: "React to this text" }
    save: cli_text_msg_id

  - action: cli_send_text
    args: { text: "🚀" }

  - action: cli_send_attachment
    args: { url: "https://picsum.photos/850/650" }

  - action: app_send_text
    args: { text: "React to this too" }
    save: app_text_msg_id

  - action: wait_for_element
    args: { label_contains: "React to this too" }

steps:
  - id: react_cli_text
    name: "CLI reaction on text message appears in app"
    actions:
      - cli_send_reaction: { msg: "$cli_text_msg_id", emoji: "👍" }
      - wait: 3
      - verify_element: { label_contains: "👍" }
    criteria: "cli_reaction_text_visible"

  - id: react_app_own
    name: "Double-tap own message adds heart"
    actions:
      - double_tap_element: { label_contains: "React to this too" }
      - wait: 2
      - verify_element: { label_contains: "❤️" }
    criteria: "app_react_own_message"

  - id: react_app_cli_msg
    name: "Double-tap CLI message adds heart"
    actions:
      - double_tap_element: { label_contains: "React to this text" }
      - wait: 2
      - verify_element: { label_contains: "❤️", near: "React to this text" }
      - cli_verify_reaction: { msg: "$cli_text_msg_id", emoji: "❤️" }
    criteria: "app_react_cli_message"

  # ... more steps

teardown:
  - action: explode_conversation
    args: { id: "$conversation_id" }

criteria:
  cli_reaction_text_visible:
    description: "CLI reaction on a text message appears in the app"
  app_react_own_message:
    description: "Double-tap on own message adds a heart reaction"
  app_react_cli_message:
    description: "Double-tap on CLI message adds a heart reaction"
  # ...
```

### What the Agent Does Differently

The agent doesn't need to *figure out* what to do. It reads the structured steps and translates each `action` into tool calls. Its intelligence is used for:

- **Error recovery** — if a step fails, decide whether to retry, skip, or abort
- **State management** — populate `state` keys and persist to CXDB
- **Judgment calls** — "did this element appear correctly?" when the check is ambiguous
- **Adaptation** — if the UI changed, find the new way to accomplish the step

This is a **guided agent**, not a script. The YAML is a plan, not a program.

## CXDB Schema

CXDB is a SQLite database (or similar) that persists across context windows. The agent reads/writes to it throughout execution.

### Tables

```sql
-- A single execution of the full suite or a subset
CREATE TABLE test_runs (
    id TEXT PRIMARY KEY,          -- uuid
    started_at TEXT,
    finished_at TEXT,
    status TEXT,                   -- running, passed, failed, partial
    simulator_udid TEXT,
    build_commit TEXT,
    device_type TEXT,              -- iPhone, iPad
    notes TEXT
);

-- Result for each test within a run
CREATE TABLE test_results (
    id TEXT PRIMARY KEY,
    run_id TEXT REFERENCES test_runs(id),
    test_id TEXT,                  -- "05" from the yaml
    test_name TEXT,
    status TEXT,                   -- pass, fail, skip, error
    started_at TEXT,
    finished_at TEXT,
    duration_ms INTEGER,
    error_message TEXT,
    notes TEXT
);

-- Individual criteria pass/fail within a test
CREATE TABLE criteria_results (
    id TEXT PRIMARY KEY,
    test_result_id TEXT REFERENCES test_results(id),
    criteria_key TEXT,             -- "cli_reaction_text_visible"
    description TEXT,
    status TEXT,                   -- pass, fail, skip
    evidence TEXT,                 -- what the agent observed
    screenshot_path TEXT           -- only when visual verification needed
);

-- Persisted state from test execution (conversation IDs, message IDs, etc.)
CREATE TABLE test_state (
    run_id TEXT,
    test_id TEXT,
    key TEXT,
    value TEXT,
    PRIMARY KEY (run_id, test_id, key)
);

-- Device/app logs captured during test execution
CREATE TABLE log_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    test_id TEXT,                  -- which test was running when this was captured
    timestamp TEXT,
    level TEXT,                    -- info, warning, error
    source TEXT,                   -- Convos, ConvosCore, XMTP
    message TEXT,
    is_xmtp_error BOOLEAN,        -- classified per RULES.md
    is_app_error BOOLEAN
);

-- Accessibility issues found during testing
CREATE TABLE accessibility_findings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    test_id TEXT,
    element_purpose TEXT,          -- "compose button in bottom toolbar"
    what_was_tried TEXT,           -- "sim_tap_id('compose-button')"
    what_worked TEXT,              -- "coordinate tap at (386, 910)"
    recommendation TEXT            -- "add accessibilityIdentifier to toolbar item"
);

-- App-level bugs found during testing
CREATE TABLE bug_findings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    test_id TEXT,
    title TEXT,
    description TEXT,
    severity TEXT,                 -- critical, major, minor
    log_evidence TEXT,
    screenshot_path TEXT,
    filed_issue_url TEXT           -- Linear issue URL once filed
);

-- Performance measurements
CREATE TABLE perf_measurements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    test_id TEXT,
    metric_name TEXT,              -- "open_few_msgs", "new_convo_ready"
    value_ms REAL,
    target_ms REAL,
    passed BOOLEAN
);
```

### How the Agent Uses CXDB

**At session start:**
```
1. Read the latest test_run — is there an incomplete run to resume?
2. If yes: load test_state, find which tests still need to run
3. If no: create a new test_run
```

**During each test:**
```
1. Create a test_result row (status: running)
2. Load any state from prior tests in this run (conversation IDs, etc.)
3. Execute steps, writing criteria_results as each completes
4. Capture log_entries from sim_log_tail
5. Save state keys to test_state
6. Update test_result status when done
```

**After context reset (new session picks up):**
```
1. Read incomplete test_run
2. See which tests passed vs pending
3. Load state (conversation IDs still valid if app wasn't relaunched)
4. Continue from where it left off
```

**After full run:**
```
1. Generate summary report from CXDB
2. Compare with previous runs (regression detection)
3. File bugs for new failures
4. Update test_run status
```

## Migration Path

### Step 1: Create CXDB and the runner (this week)
- Create the SQLite database schema
- Write a `qa/runner.py` (or shell script) that initializes the DB
- The agent uses simple SQL (via `sqlite3` CLI) to read/write — no ORM needed
- Convert 2-3 tests to YAML as proof of concept

### Step 2: Convert all tests to YAML (next week)
- Convert all 19 tests to structured YAML
- Keep the .md files as human-readable documentation (generated from YAML)
- Agent reads YAML for execution, .md for context when it needs to understand *why*

### Step 3: Run-over-run comparison
- After each full run, compare criteria_results with the previous run
- Auto-detect regressions: "test 05 passed last run but failed this run"
- Track flake rate per criteria across runs

### Step 4: Connect to Kilroy (later)
- When ready for full Attractor pipelines, CXDB is already populated
- Kilroy can read from the same DB or its own — the schema is compatible
- Test execution becomes a node in a larger pipeline graph

## What This Buys Us Now

1. **Resume across context resets** — the #1 problem today. Agent picks up where it left off.
2. **Faster runs** — structured steps = less interpretation = fewer tokens = more tests per context window
3. **Persistent findings** — bugs, accessibility issues, performance data survive across sessions
4. **Historical comparison** — "this test has failed 3 of the last 5 runs" vs "it failed just now"
5. **Incremental execution** — re-run only failures, or only tests tagged "core"
6. **Foundation for automation** — task runner daemon (Phase 2) can trigger runs and check CXDB for results

## Open Questions

- **YAML vs JSON vs something else?** YAML is human-friendly for test definitions. JSON works too. Could even use a Swift DSL eventually, but that's over-engineering for now.
- **Where does CXDB live?** `qa/cxdb.sqlite` in the repo (gitignored) or `~/.convos-qa/cxdb.sqlite` on the machine? Repo-local is simpler but doesn't survive `git clean`. Machine-global survives but needs path management.
- **Screenshots in CXDB?** Store paths to screenshots on disk, not blobs in SQLite. Screenshots go in `qa/reports/screenshots/<run_id>/`.
- **Should the agent write SQL directly?** Yes, via `sqlite3` CLI from bash. It's simple, universal, and the agent is good at SQL. No need for a wrapper library.
