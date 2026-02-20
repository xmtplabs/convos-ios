#!/bin/bash
# cxdb.sh — QA execution database helper
# Usage: ./cxdb.sh <command> [args...]
#
# The agent calls this from bash to manage test runs, results, and state.
# All data persists in qa/cxdb/qa.sqlite across context windows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$SCRIPT_DIR/qa.sqlite"
SCHEMA="$SCRIPT_DIR/schema.sql"

# Initialize DB if it doesn't exist
init_db() {
    if [ ! -f "$DB" ]; then
        sqlite3 "$DB" < "$SCHEMA"
        echo "Created $DB"
    fi
}

# Always ensure DB exists
init_db

cmd="${1:-help}"
shift || true

case "$cmd" in

    # --- Run management ---

    new-run)
        # Create a new test run. Prints the run ID.
        # Usage: cxdb.sh new-run <simulator_udid> <build_commit> <device_type> [notes]
        local_udid="${1:?simulator_udid required}"
        local_commit="${2:?build_commit required}"
        local_device="${3:-iPhone}"
        local_notes="${4:-}"
        local_id=$(python3 -c "import uuid; print(uuid.uuid4().hex[:12])")
        sqlite3 "$DB" "INSERT INTO test_runs (id, simulator_udid, build_commit, device_type, notes) VALUES ('$local_id', '$local_udid', '$local_commit', '$local_device', '$local_notes');"
        echo "$local_id"
        ;;

    finish-run)
        # Mark a run as finished. Status derived from test results.
        # Usage: cxdb.sh finish-run <run_id>
        local_run="${1:?run_id required}"
        local_failed=$(sqlite3 "$DB" "SELECT COUNT(*) FROM test_results WHERE run_id='$local_run' AND status IN ('fail','error');")
        local_passed=$(sqlite3 "$DB" "SELECT COUNT(*) FROM test_results WHERE run_id='$local_run' AND status='pass';")
        local_pending=$(sqlite3 "$DB" "SELECT COUNT(*) FROM test_results WHERE run_id='$local_run' AND status IN ('pending','running');")
        if [ "$local_failed" -gt 0 ] && [ "$local_pending" -gt 0 ]; then
            local_status="partial"
        elif [ "$local_failed" -gt 0 ]; then
            local_status="failed"
        elif [ "$local_pending" -gt 0 ]; then
            local_status="partial"
        else
            local_status="passed"
        fi
        sqlite3 "$DB" "UPDATE test_runs SET status='$local_status', finished_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='$local_run';"
        echo "$local_status (passed=$local_passed failed=$local_failed pending=$local_pending)"
        ;;

    active-run)
        # Get the most recent running/partial run, if any.
        sqlite3 "$DB" "SELECT id FROM test_runs WHERE status IN ('running','partial') ORDER BY started_at DESC LIMIT 1;"
        ;;

    # --- Test results ---

    start-test)
        # Record start of a test. Prints the test_result ID.
        # Usage: cxdb.sh start-test <run_id> <test_id> <test_name>
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        local_name="${3:?test_name required}"
        local_id=$(python3 -c "import uuid; print(uuid.uuid4().hex[:12])")
        sqlite3 "$DB" "INSERT INTO test_results (id, run_id, test_id, test_name, status, started_at) VALUES ('$local_id', '$local_run', '$local_test', '$local_name', 'running', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
        echo "$local_id"
        ;;

    finish-test)
        # Mark a test as finished.
        # Usage: cxdb.sh finish-test <test_result_id> <pass|fail|skip|error> [error_message] [notes]
        local_trid="${1:?test_result_id required}"
        local_status="${2:?status required}"
        local_err="${3:-}"
        local_notes="${4:-}"
        local_start=$(sqlite3 "$DB" "SELECT started_at FROM test_results WHERE id='$local_trid';")
        sqlite3 "$DB" "UPDATE test_results SET status='$local_status', finished_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'), duration_ms=CAST((julianday('now') - julianday('$local_start')) * 86400000 AS INTEGER), error_message=$([ -n "$local_err" ] && echo "'$local_err'" || echo "NULL"), notes=$([ -n "$local_notes" ] && echo "'$local_notes'" || echo "NULL") WHERE id='$local_trid';"
        echo "ok"
        ;;

    test-status)
        # Get status of a test in a run.
        # Usage: cxdb.sh test-status <run_id> <test_id>
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        sqlite3 "$DB" "SELECT status FROM test_results WHERE run_id='$local_run' AND test_id='$local_test' ORDER BY started_at DESC LIMIT 1;"
        ;;

    pending-tests)
        # List test_ids that haven't run yet in this run (based on what's been started).
        # Usage: cxdb.sh pending-tests <run_id> <all_test_ids_comma_separated>
        local_run="${1:?run_id required}"
        local_all="${2:?all test IDs comma-separated}"
        # Get completed test IDs
        local_done=$(sqlite3 "$DB" "SELECT test_id FROM test_results WHERE run_id='$local_run' AND status IN ('pass','skip');")
        # Print IDs from all that aren't in done
        echo "$local_all" | tr ',' '\n' | while read -r tid; do
            if ! echo "$local_done" | grep -qx "$tid"; then
                echo "$tid"
            fi
        done
        ;;

    # --- Criteria ---

    record-criterion)
        # Record a criterion result.
        # Usage: cxdb.sh record-criterion <test_result_id> <criteria_key> <pass|fail|skip> <description> [evidence]
        local_trid="${1:?test_result_id required}"
        local_key="${2:?criteria_key required}"
        local_status="${3:?status required}"
        local_desc="${4:?description required}"
        local_evidence="${5:-}"
        local_id=$(python3 -c "import uuid; print(uuid.uuid4().hex[:12])")
        sqlite3 "$DB" "INSERT INTO criteria_results (id, test_result_id, criteria_key, status, description, evidence) VALUES ('$local_id', '$local_trid', '$local_key', '$local_status', '$(echo "$local_desc" | sed "s/'/''/g")', '$(echo "$local_evidence" | sed "s/'/''/g")');"
        echo "ok"
        ;;

    # --- State ---

    set-state)
        # Set a state key for a test (or use test_id="_run" for run-level state).
        # Usage: cxdb.sh set-state <run_id> <test_id> <key> <value>
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        local_key="${3:?key required}"
        local_val="${4:-}"
        if [ "$local_test" = "_run" ]; then
            sqlite3 "$DB" "INSERT OR REPLACE INTO run_state (run_id, key, value, updated_at) VALUES ('$local_run', '$local_key', '$(echo "$local_val" | sed "s/'/''/g")', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
        else
            sqlite3 "$DB" "INSERT OR REPLACE INTO test_state (run_id, test_id, key, value, updated_at) VALUES ('$local_run', '$local_test', '$local_key', '$(echo "$local_val" | sed "s/'/''/g")', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
        fi
        echo "ok"
        ;;

    get-state)
        # Get a state value.
        # Usage: cxdb.sh get-state <run_id> <test_id> <key>
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        local_key="${3:?key required}"
        if [ "$local_test" = "_run" ]; then
            sqlite3 "$DB" "SELECT value FROM run_state WHERE run_id='$local_run' AND key='$local_key';"
        else
            sqlite3 "$DB" "SELECT value FROM test_state WHERE run_id='$local_run' AND test_id='$local_test' AND key='$local_key';"
        fi
        ;;

    all-state)
        # Dump all state for a run.
        # Usage: cxdb.sh all-state <run_id>
        local_run="${1:?run_id required}"
        echo "=== Run State ==="
        sqlite3 -header -column "$DB" "SELECT key, value FROM run_state WHERE run_id='$local_run';"
        echo ""
        echo "=== Test State ==="
        sqlite3 -header -column "$DB" "SELECT test_id, key, value FROM test_state WHERE run_id='$local_run' ORDER BY test_id, key;"
        ;;

    # --- Logs ---

    log-error)
        # Record an error log entry.
        # Usage: cxdb.sh log-error <run_id> <test_id> <timestamp> <source> <message> <is_xmtp:0|1>
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        local_ts="${3:?timestamp required}"
        local_src="${4:?source required}"
        local_msg="${5:?message required}"
        local_xmtp="${6:-0}"
        local_app=$( [ "$local_xmtp" = "1" ] && echo "0" || echo "1" )
        sqlite3 "$DB" "INSERT INTO log_entries (run_id, test_id, timestamp, level, source, message, is_xmtp_error, is_app_error) VALUES ('$local_run', '$local_test', '$local_ts', 'error', '$local_src', '$(echo "$local_msg" | sed "s/'/''/g")', $local_xmtp, $local_app);"
        echo "ok"
        ;;

    # --- Findings ---

    log-bug)
        # Record a bug finding.
        # Usage: cxdb.sh log-bug <run_id> <test_id> <severity> <title> [description]
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        local_sev="${3:?severity required}"
        local_title="${4:?title required}"
        local_desc="${5:-}"
        sqlite3 "$DB" "INSERT INTO bug_findings (run_id, test_id, title, description, severity) VALUES ('$local_run', '$local_test', '$(echo "$local_title" | sed "s/'/''/g")', '$(echo "$local_desc" | sed "s/'/''/g")', '$local_sev');"
        echo "ok"
        ;;

    log-a11y)
        # Record an accessibility finding.
        # Usage: cxdb.sh log-a11y <run_id> <test_id> <element_purpose> <recommendation>
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        local_purpose="${3:?element_purpose required}"
        local_rec="${4:?recommendation required}"
        sqlite3 "$DB" "INSERT INTO accessibility_findings (run_id, test_id, element_purpose, recommendation) VALUES ('$local_run', '$local_test', '$(echo "$local_purpose" | sed "s/'/''/g")', '$(echo "$local_rec" | sed "s/'/''/g")');"
        echo "ok"
        ;;

    log-perf)
        # Record a performance measurement.
        # Usage: cxdb.sh log-perf <run_id> <test_id> <metric_name> <value_ms> <target_ms>
        local_run="${1:?run_id required}"
        local_test="${2:?test_id required}"
        local_metric="${3:?metric_name required}"
        local_val="${4:?value_ms required}"
        local_target="${5:?target_ms required}"
        local_passed=$( python3 -c "print(1 if $local_val <= $local_target else 0)" )
        sqlite3 "$DB" "INSERT INTO perf_measurements (run_id, test_id, metric_name, value_ms, target_ms, passed) VALUES ('$local_run', '$local_test', '$local_metric', $local_val, $local_target, $local_passed);"
        echo "ok"
        ;;

    # --- Reporting ---

    summary)
        # Print run summary.
        # Usage: cxdb.sh summary <run_id>
        local_run="${1:?run_id required}"
        echo "=== Run $local_run ==="
        sqlite3 -header -column "$DB" "SELECT status, build_commit, device_type, started_at, finished_at FROM test_runs WHERE id='$local_run';"
        echo ""
        echo "=== Test Results ==="
        sqlite3 -header -column "$DB" "SELECT test_id, test_name, status, duration_ms, error_message FROM test_results WHERE run_id='$local_run' ORDER BY test_id;"
        echo ""
        local_bugs=$(sqlite3 "$DB" "SELECT COUNT(*) FROM bug_findings WHERE run_id='$local_run';")
        local_a11y=$(sqlite3 "$DB" "SELECT COUNT(*) FROM accessibility_findings WHERE run_id='$local_run';")
        local_app_errors=$(sqlite3 "$DB" "SELECT COUNT(*) FROM log_entries WHERE run_id='$local_run' AND is_app_error=1;")
        local_xmtp_errors=$(sqlite3 "$DB" "SELECT COUNT(*) FROM log_entries WHERE run_id='$local_run' AND is_xmtp_error=1;")
        echo "Bugs: $local_bugs | Accessibility: $local_a11y | App errors: $local_app_errors | XMTP errors: $local_xmtp_errors"
        ;;

    report-md)
        # Generate a markdown report for a run.
        # Usage: cxdb.sh report-md <run_id>
        local_run="${1:?run_id required}"

        # Header
        sqlite3 "$DB" "SELECT '# QA Run ' || id || ' — ' || started_at FROM test_runs WHERE id='$local_run';"
        echo ""
        sqlite3 "$DB" "SELECT '**Status:** ' || status || '  ' || char(10) || '**Commit:** ' || build_commit || '  ' || char(10) || '**Device:** ' || device_type || '  ' || char(10) || '**Simulator:** ' || simulator_udid FROM test_runs WHERE id='$local_run';"
        echo ""
        echo "---"
        echo ""

        # Summary table
        echo "## Summary"
        echo ""
        echo "| Test | Status | Duration | Notes |"
        echo "|------|--------|----------|-------|"
        sqlite3 -separator '|' "$DB" "SELECT '| ' || test_id || ' - ' || test_name, CASE status WHEN 'pass' THEN '✅' WHEN 'fail' THEN '❌' WHEN 'skip' THEN '⏭️' WHEN 'error' THEN '💥' ELSE '⏳' END, COALESCE(duration_ms || 'ms', '-'), COALESCE(error_message, COALESCE(notes, '')) || ' |' FROM test_results WHERE run_id='$local_run' ORDER BY test_id;"
        echo ""

        # Per-test criteria
        echo "## Details"
        echo ""
        sqlite3 "$DB" "SELECT tr.test_id, tr.test_name, tr.status FROM test_results tr WHERE tr.run_id='$local_run' ORDER BY tr.test_id;" | while IFS='|' read -r tid tname tstatus; do
            echo "### $tid: $tname ($tstatus)"
            echo ""
            sqlite3 -separator '|' "$DB" "SELECT CASE cr.status WHEN 'pass' THEN '- [x]' WHEN 'fail' THEN '- [ ] **FAIL:**' ELSE '- [ ] SKIP:' END, cr.description, COALESCE(' — ' || cr.evidence, '') FROM criteria_results cr JOIN test_results tr ON cr.test_result_id=tr.id WHERE tr.run_id='$local_run' AND tr.test_id='$tid';" | while IFS='|' read -r mark desc ev; do
                echo "$mark $desc$ev"
            done
            echo ""
        done

        # Bugs
        local_bugs=$(sqlite3 "$DB" "SELECT COUNT(*) FROM bug_findings WHERE run_id='$local_run';")
        if [ "$local_bugs" -gt 0 ]; then
            echo "## Bugs Found"
            echo ""
            sqlite3 "$DB" "SELECT '- **[' || severity || ']** ' || title || ': ' || COALESCE(description, '') FROM bug_findings WHERE run_id='$local_run';"
            echo ""
        fi

        # Accessibility
        local_a11y=$(sqlite3 "$DB" "SELECT COUNT(*) FROM accessibility_findings WHERE run_id='$local_run';")
        if [ "$local_a11y" -gt 0 ]; then
            echo "## Accessibility Improvements Needed"
            echo ""
            sqlite3 "$DB" "SELECT '- **' || element_purpose || '**: ' || recommendation FROM accessibility_findings WHERE run_id='$local_run';"
            echo ""
        fi

        # Performance
        local_perf=$(sqlite3 "$DB" "SELECT COUNT(*) FROM perf_measurements WHERE run_id='$local_run';")
        if [ "$local_perf" -gt 0 ]; then
            echo "## Performance"
            echo ""
            echo "| Metric | Value | Target | Status |"
            echo "|--------|-------|--------|--------|"
            sqlite3 -separator '|' "$DB" "SELECT '| ' || metric_name, value_ms || 'ms', target_ms || 'ms', CASE passed WHEN 1 THEN '✅' ELSE '❌' END || ' |' FROM perf_measurements WHERE run_id='$local_run';"
            echo ""
        fi
        ;;

    history)
        # Show recent runs.
        # Usage: cxdb.sh history [limit]
        local_limit="${1:-10}"
        sqlite3 -header -column "$DB" "SELECT id, status, device_type, build_commit, started_at FROM test_runs ORDER BY started_at DESC LIMIT $local_limit;"
        ;;

    compare)
        # Compare two runs — show regressions and fixes.
        # Usage: cxdb.sh compare <run_id_old> <run_id_new>
        local_old="${1:?old run_id required}"
        local_new="${2:?new run_id required}"
        echo "=== Regressions (passed → failed) ==="
        sqlite3 -header -column "$DB" "
            SELECT o.test_id, o.test_name, o.status AS old_status, n.status AS new_status
            FROM test_results o
            JOIN test_results n ON o.test_id = n.test_id
            WHERE o.run_id='$local_old' AND n.run_id='$local_new'
              AND o.status='pass' AND n.status IN ('fail','error')
            ORDER BY o.test_id;
        "
        echo ""
        echo "=== Fixes (failed → passed) ==="
        sqlite3 -header -column "$DB" "
            SELECT o.test_id, o.test_name, o.status AS old_status, n.status AS new_status
            FROM test_results o
            JOIN test_results n ON o.test_id = n.test_id
            WHERE o.run_id='$local_old' AND n.run_id='$local_new'
              AND o.status IN ('fail','error') AND n.status='pass'
            ORDER BY o.test_id;
        "
        ;;

    sql)
        # Run arbitrary SQL. For agent flexibility.
        # Usage: cxdb.sh sql "SELECT ..."
        sqlite3 -header -column "$DB" "$1"
        ;;

    reset)
        # Delete the database and recreate. Use with caution.
        rm -f "$DB"
        init_db
        echo "Database reset"
        ;;

    help|*)
        echo "cxdb.sh — QA execution database"
        echo ""
        echo "Run management:"
        echo "  new-run <udid> <commit> [device] [notes]    Create a new run"
        echo "  finish-run <run_id>                         Finish a run"
        echo "  active-run                                  Get current running/partial run"
        echo ""
        echo "Test results:"
        echo "  start-test <run_id> <test_id> <name>        Start a test"
        echo "  finish-test <result_id> <status> [err] [notes]  Finish a test"
        echo "  test-status <run_id> <test_id>              Get test status"
        echo "  pending-tests <run_id> <id1,id2,...>         List unfinished tests"
        echo ""
        echo "Criteria:"
        echo "  record-criterion <result_id> <key> <status> <desc> [evidence]"
        echo ""
        echo "State:"
        echo "  set-state <run_id> <test_id> <key> <value>  Save state (use _run for run-level)"
        echo "  get-state <run_id> <test_id> <key>          Get state"
        echo "  all-state <run_id>                          Dump all state"
        echo ""
        echo "Logging:"
        echo "  log-error <run_id> <test_id> <ts> <src> <msg> [is_xmtp:0|1]"
        echo "  log-bug <run_id> <test_id> <severity> <title> [desc]"
        echo "  log-a11y <run_id> <test_id> <purpose> <recommendation>"
        echo "  log-perf <run_id> <test_id> <metric> <value_ms> <target_ms>"
        echo ""
        echo "Reporting:"
        echo "  summary <run_id>                            Print summary"
        echo "  report-md <run_id>                          Generate markdown report"
        echo "  history [limit]                             Show recent runs"
        echo "  compare <old_run> <new_run>                 Compare two runs"
        echo ""
        echo "Other:"
        echo "  sql \"<query>\"                               Run arbitrary SQL"
        echo "  reset                                       Delete and recreate DB"
        ;;
esac
