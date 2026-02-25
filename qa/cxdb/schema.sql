-- CXDB: QA execution database
-- Persists test results, state, logs, and findings across context windows.
-- The agent reads/writes via `sqlite3` CLI from bash.

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- A single execution of the full suite or a subset
CREATE TABLE IF NOT EXISTS test_runs (
    id TEXT PRIMARY KEY,
    started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    finished_at TEXT,
    status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'passed', 'failed', 'partial', 'aborted')),
    simulator_udid TEXT,
    build_commit TEXT,
    device_type TEXT,
    app_bundle_id TEXT DEFAULT 'org.convos.ios-preview',
    notes TEXT
);

-- Result for each test within a run
CREATE TABLE IF NOT EXISTS test_results (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES test_runs(id),
    test_id TEXT NOT NULL,
    test_name TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'pass', 'fail', 'skip', 'error')),
    started_at TEXT,
    finished_at TEXT,
    duration_ms INTEGER,
    error_message TEXT,
    notes TEXT
);

-- Individual criteria pass/fail within a test
CREATE TABLE IF NOT EXISTS criteria_results (
    id TEXT PRIMARY KEY,
    test_result_id TEXT NOT NULL REFERENCES test_results(id),
    criteria_key TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'pass', 'fail', 'skip')),
    evidence TEXT,
    screenshot_path TEXT
);

-- Persisted state from test execution (conversation IDs, message IDs, invite URLs, etc.)
-- Survives context resets so the next session can resume.
CREATE TABLE IF NOT EXISTS test_state (
    run_id TEXT NOT NULL,
    test_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (run_id, test_id, key)
);

-- Shared state across tests within a run (e.g., conversation IDs reused between tests)
CREATE TABLE IF NOT EXISTS run_state (
    run_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (run_id, key)
);

-- Device/app logs captured during test execution
CREATE TABLE IF NOT EXISTS log_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    test_id TEXT,
    timestamp TEXT,
    level TEXT CHECK (level IN ('info', 'warning', 'error')),
    source TEXT,
    message TEXT,
    is_xmtp_error BOOLEAN DEFAULT 0,
    is_app_error BOOLEAN DEFAULT 0
);

-- Accessibility issues found during testing
CREATE TABLE IF NOT EXISTS accessibility_findings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    test_id TEXT,
    element_purpose TEXT,
    what_was_tried TEXT,
    what_worked TEXT,
    recommendation TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- App-level bugs found during testing
CREATE TABLE IF NOT EXISTS bug_findings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    test_id TEXT,
    title TEXT NOT NULL,
    description TEXT,
    severity TEXT CHECK (severity IN ('critical', 'major', 'minor')),
    log_evidence TEXT,
    screenshot_path TEXT,
    filed_issue_url TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Performance measurements
CREATE TABLE IF NOT EXISTS perf_measurements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    test_id TEXT,
    metric_name TEXT NOT NULL,
    value_ms REAL,
    target_ms REAL,
    passed BOOLEAN,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- App events captured from [EVENT] log lines during test execution
CREATE TABLE IF NOT EXISTS app_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    test_id TEXT,
    timestamp TEXT,
    event_name TEXT NOT NULL,
    event_data TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Index for common queries
CREATE INDEX IF NOT EXISTS idx_test_results_run ON test_results(run_id);
CREATE INDEX IF NOT EXISTS idx_test_results_status ON test_results(run_id, status);
CREATE INDEX IF NOT EXISTS idx_criteria_results_test ON criteria_results(test_result_id);
CREATE INDEX IF NOT EXISTS idx_log_entries_run ON log_entries(run_id, test_id);
CREATE INDEX IF NOT EXISTS idx_log_entries_errors ON log_entries(run_id, is_app_error) WHERE is_app_error = 1;
CREATE INDEX IF NOT EXISTS idx_perf_measurements_run ON perf_measurements(run_id);
CREATE INDEX IF NOT EXISTS idx_app_events_run ON app_events(run_id, test_id);
CREATE INDEX IF NOT EXISTS idx_app_events_name ON app_events(run_id, event_name);
