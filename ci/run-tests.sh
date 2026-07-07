#!/bin/bash
set -euo pipefail

# CI test runner for ConvosCore
# Usage: ./run-tests.sh [--unit|--integration]
#   --unit        Run only unit tests (no backend required)
#   --integration Run only integration tests (requires XMTP backend)
#   (none)        Run all tests
#
# Output design:
#   - Full (XMTP-stripped) output for each step is captured to $CI_LOG_DIR and
#     uploaded as a CI artifact, so nothing is lost.
#   - The live console shows a reduced view (passing tests and start markers are
#     dropped) wrapped in collapsible GitHub `::group::` sections.
#   - On any failure, a concise summary of compile errors, failed tests, and
#     crashes is printed at the very end and written to the GitHub run-summary
#     panel ($GITHUB_STEP_SUMMARY). No more hunting through thousands of lines.

TEST_TYPE="${1:-all}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$REPO_ROOT/ConvosCore"

CI_LOG_DIR="${CI_LOG_DIR:-$REPO_ROOT/ci-test-logs}"
mkdir -p "$CI_LOG_DIR"

# Filter out noisy XMTP Rust library logs (timestamps like 2024-01-01T...).
# Applied before capture so neither the saved log nor the console carries them;
# the full XMTP logs go to CONVOS_TEST_XMTP_LOG_DIR separately.
filter_xmtp_logs() {
    grep -v -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" || true
}

# Reduce the live console view: drop passing Swift Testing lines (✔), the
# per-test "started" markers (◇), and any leftover timestamped logs. Failures
# (✘), `error:` lines, and structural output are kept. The saved log keeps
# everything (minus XMTP noise) for the artifact.
filter_console() {
    grep -v -E \
        -e '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
        -e '✔' \
        -e '◇' \
        -e 'Test .* started' \
    || true
}

# Run a command, capturing full output to a log file and streaming a reduced
# view to the console inside a collapsible group. Returns the command's status
# (not tee's / grep's, which always succeed).
run_capture() {
    local log="$1"
    local label="$2"
    shift 2
    local rc=0
    echo "::group::$label"
    "$@" 2>&1 | filter_xmtp_logs | tee "$log" | filter_console || rc=${PIPESTATUS[0]}
    echo "::endgroup::"
    return "$rc"
}

# Build a concise failure summary from a captured log: compile errors, failed
# tests/issues (✘), and crash markers with the tests that were in flight. Prints
# to the console (at the end, where it is easy to find) and appends a markdown
# panel to $GITHUB_STEP_SUMMARY when running in GitHub Actions.
emit_failure_summary() {
    local log="$1"
    local label="${2:-Tests}"

    local compile_errors compile_error_locations test_failures crash_lines crash_suspects=""
    # Any compiler/macro/linker diagnostic, deduped. Matches `file.swift:l:c:
    # error:`, `macro expansion ...: error:`, and linker `error:` lines -- not
    # just the file:line:col form (a macro-expansion error reports the message
    # on a line with no `.swift:` prefix, which the old grep missed).
    compile_errors="$(grep -hE ': error: ' "$log" 2>/dev/null | sort -u || true)"
    # Source locations tied to those errors: direct `error:` sites plus the
    # `note: ... originates here` line a macro error points at (the user's real
    # call site). Path trimmed to repo-relative for readability.
    compile_error_locations="$(grep -hE '\.swift:[0-9]+:[0-9]+: (error:|note: .*originates here)' "$log" 2>/dev/null \
        | grep -hoE '[A-Za-z0-9_/.-]+\.swift:[0-9]+:[0-9]+' | sed -E 's#.*/convos-ios/##' | sort -u || true)"
    # Swift Testing failures carry the ✘ glyph; XCTest failures use
    # "Test Case '...' failed" / ": error: -[Suite test]". Catch both.
    test_failures="$(grep -hE "✘|Test Case .* failed|Test Suite .* failed|: error: -\[" "$log" 2>/dev/null || true)"
    crash_lines="$(grep -hE 'Fatal error|fatalError|Crashed|exited abnormally|signal SIG' "$log" 2>/dev/null || true)"
    if [[ -n "$crash_lines" ]]; then
        crash_suspects="$(comm -23 \
            <(grep -oE 'Test "[^"]+" started' "$log" | sort -u) \
            <(grep -oE 'Test "[^"]+" (passed|failed)' "$log" | sed -E 's/ (passed|failed)$/ started/' | sort -u) \
            2>/dev/null || true)"
    fi

    echo ""
    echo "================== FAILURE SUMMARY: $label =================="
    if [[ -n "$compile_errors" ]]; then
        echo "-- compile errors --"
        echo "$compile_errors"
    fi
    if [[ -n "$compile_error_locations" ]]; then
        echo "-- at --"
        echo "$compile_error_locations"
    fi
    if [[ -n "$test_failures" ]]; then
        echo "-- failed tests / recorded issues --"
        echo "$test_failures"
    fi
    if [[ -n "$crash_lines" ]]; then
        echo "-- crash --"
        echo "$crash_lines"
        if [[ -n "$crash_suspects" ]]; then
            echo "-- in flight when it crashed (suspects) --"
            echo "$crash_suspects"
        fi
    fi
    if [[ -z "$compile_errors$compile_error_locations$test_failures$crash_lines" ]]; then
        echo "(no recognized failure markers; see full log)"
    fi
    echo "Full log: $log"
    echo "============================================================"

    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### ❌ ${label} failed"
            if [[ -n "$compile_errors" ]]; then
                echo ""
                echo "**Compile errors**"
                echo '```'
                echo "$compile_errors"
                if [[ -n "$compile_error_locations" ]]; then
                    echo ""
                    echo "at:"
                    echo "$compile_error_locations"
                fi
                echo '```'
            fi
            if [[ -n "$test_failures" ]]; then
                echo ""
                echo "**Failed tests / recorded issues**"
                echo '```'
                echo "$test_failures"
                echo '```'
            fi
            if [[ -n "$crash_lines" ]]; then
                echo ""
                echo "**Crash**"
                echo '```'
                echo "$crash_lines"
                if [[ -n "$crash_suspects" ]]; then
                    echo ""
                    echo "In flight when it crashed:"
                    echo "$crash_suspects"
                fi
                echo '```'
            fi
            echo ""
            echo "_Full logs are attached as a workflow artifact._"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

emit_success_summary() {
    local label="$1"
    echo ""
    echo "==> $label completed successfully"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "### ✅ ${label} passed" >> "$GITHUB_STEP_SUMMARY"
    fi
}

cd "$CORE_DIR"

case "$TEST_TYPE" in
    --unit)
        echo "==> Running unit tests (no backend required)"
        failed=0

        APPDATA_LOG="$CI_LOG_DIR/convosappdata-tests.log"
        if ! run_capture "$APPDATA_LOG" "ConvosAppData tests" \
            swift test --package-path "$REPO_ROOT/ConvosAppData"; then
            emit_failure_summary "$APPDATA_LOG" "ConvosAppData tests"
            failed=1
        fi

        INVITES_LOG="$CI_LOG_DIR/convosinvites-tests.log"
        if ! run_capture "$INVITES_LOG" "ConvosInvites tests" \
            swift test --package-path "$REPO_ROOT/ConvosInvites"; then
            emit_failure_summary "$INVITES_LOG" "ConvosInvites tests"
            failed=1
        fi

        if [[ "$failed" -ne 0 ]]; then
            exit 1
        fi
        emit_success_summary "Unit tests"
        ;;
    --integration)
        echo "==> Running integration tests"
        echo "  XMTP_NODE_ADDRESS=${XMTP_NODE_ADDRESS:-not set}"

        if [[ -z "${XMTP_NODE_ADDRESS:-}" ]]; then
            echo "Error: XMTP_NODE_ADDRESS environment variable is required for integration tests"
            exit 1
        fi

        # Build first to avoid parallel build issues. A compile failure here is a
        # common cause of "the job failed but there is no test summary" -- so
        # summarize the build log before exiting.
        BUILD_LOG="$CI_LOG_DIR/integration-build.log"
        if ! run_capture "$BUILD_LOG" "Build tests" swift build --build-tests; then
            emit_failure_summary "$BUILD_LOG" "Build"
            exit 1
        fi

        # Integration tests depend on an ephemeral XMTP backend where operations
        # can have highly variable latency. Retry once on failure to reduce flake.
        MAX_ATTEMPTS=2
        ATTEMPT=1
        while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
            TEST_LOG="$CI_LOG_DIR/integration-tests-attempt-$ATTEMPT.log"
            if run_capture "$TEST_LOG" "Integration tests (attempt $ATTEMPT/$MAX_ATTEMPTS)" \
                swift test --skip-build; then
                emit_success_summary "Integration tests"
                break
            fi

            if [[ $ATTEMPT -eq $MAX_ATTEMPTS ]]; then
                echo "==> Tests failed after $MAX_ATTEMPTS attempts"
                emit_failure_summary "$TEST_LOG" "Integration tests"
                exit 1
            fi

            echo "==> Attempt $ATTEMPT failed, retrying..."
            ATTEMPT=$((ATTEMPT + 1))
        done
        ;;
    all|"")
        echo "==> Running all tests"

        BUILD_LOG="$CI_LOG_DIR/build.log"
        if ! run_capture "$BUILD_LOG" "Build tests" swift build --build-tests; then
            emit_failure_summary "$BUILD_LOG" "Build"
            exit 1
        fi

        TEST_LOG="$CI_LOG_DIR/tests.log"
        if ! run_capture "$TEST_LOG" "Tests" swift test --skip-build; then
            emit_failure_summary "$TEST_LOG" "Tests"
            exit 1
        fi
        emit_success_summary "Tests"
        ;;
    *)
        echo "Unknown option: $TEST_TYPE"
        echo "Usage: $0 [--unit|--integration]"
        exit 1
        ;;
esac

echo ""
echo "==> Done"
