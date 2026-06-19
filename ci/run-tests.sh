#!/bin/bash
set -euo pipefail

# CI test runner for ConvosCore
# Usage: ./run-tests.sh [--unit|--integration]
#   --unit        Run only unit tests (no backend required)
#   --integration Run only integration tests (requires XMTP backend)
#   (none)        Run all tests

TEST_TYPE="${1:-all}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$REPO_ROOT/ConvosCore"

# Filter out noisy XMTP Rust library logs (timestamps like 2024-01-01T...)
filter_xmtp_logs() {
    grep -v -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" || true
}

# Print a concise summary of Swift Testing failures from a captured run log.
# Swift Testing marks every failure line with the ✘ glyph (passes use ✔), so
# this surfaces the failed tests, failed suites, the recorded issues (with
# file:line + message), and the final run summary -- without scrolling the
# full ~19k-line output.
print_failure_summary() {
    local log="$1"
    echo ""
    echo "================== FAILED TEST SUMMARY =================="
    if ! grep -F '✘' "$log"; then
        echo "(no Swift Testing failure markers found; see full log above)"
    fi
    echo "========================================================"
}

cd "$CORE_DIR"

case "$TEST_TYPE" in
    --unit)
        echo "==> Running unit tests (no backend required)"
        echo ""

        echo "==> Running ConvosAppData tests..."
        swift test --package-path "$REPO_ROOT/ConvosAppData" 2>&1 | filter_xmtp_logs

        echo ""
        echo "==> Running ConvosInvites tests..."
        swift test --package-path "$REPO_ROOT/ConvosInvites" 2>&1 | filter_xmtp_logs
        ;;
    --integration)
        echo "==> Running integration tests"
        echo ""
        echo "Environment:"
        echo "  XMTP_NODE_ADDRESS=${XMTP_NODE_ADDRESS:-not set}"
        echo ""

        if [[ -z "${XMTP_NODE_ADDRESS:-}" ]]; then
            echo "Error: XMTP_NODE_ADDRESS environment variable is required for integration tests"
            exit 1
        fi

        # Build first to avoid parallel build issues
        echo "==> Building tests..."
        swift build --build-tests -q 2>&1 | filter_xmtp_logs

        echo ""
        echo "==> Running tests (with retry on failure)..."
        # Integration tests depend on an ephemeral XMTP backend where
        # operations can have highly variable latency. Retry once on
        # failure to reduce flake rate.
        MAX_ATTEMPTS=2
        ATTEMPT=1
        TEST_LOG="$(mktemp)"
        while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
            echo "==> Attempt $ATTEMPT/$MAX_ATTEMPTS"
            # `tee` mirrors output to the console and captures it so the failure
            # summary below can list which tests failed. `pipefail` (set above)
            # makes the `if` reflect `swift test`'s status, not `tee`'s.
            if swift test --skip-build 2>&1 | filter_xmtp_logs | tee "$TEST_LOG"; then
                break
            fi

            if [[ $ATTEMPT -eq $MAX_ATTEMPTS ]]; then
                echo ""
                echo "==> Tests failed after $MAX_ATTEMPTS attempts"
                print_failure_summary "$TEST_LOG"
                exit 1
            fi

            echo ""
            echo "==> Attempt $ATTEMPT failed, retrying..."
            echo ""
            ATTEMPT=$((ATTEMPT + 1))
        done
        ;;
    all|"")
        echo "==> Running all tests"
        echo ""

        # Build first
        echo "==> Building tests..."
        swift build --build-tests -q 2>&1 | filter_xmtp_logs

        echo ""
        echo "==> Running tests..."
        TEST_LOG="$(mktemp)"
        if ! swift test --skip-build 2>&1 | filter_xmtp_logs | tee "$TEST_LOG"; then
            print_failure_summary "$TEST_LOG"
            exit 1
        fi
        ;;
    *)
        echo "Unknown option: $TEST_TYPE"
        echo "Usage: $0 [--unit|--integration]"
        exit 1
        ;;
esac

echo ""
echo "==> Tests completed successfully"
