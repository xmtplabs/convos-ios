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

cd "$CORE_DIR"

case "$TEST_TYPE" in
    --unit)
        echo "==> Running unit tests (no backend required)"
        echo ""
        swift test --filter "Base64URL|DataHex|Compression|Custom Metadata" 2>&1 | filter_xmtp_logs
        ;;
    --integration)
        echo "==> Running integration tests"
        echo ""
        echo "Environment:"
        echo "  XMTP_NODE_ADDRESS=${XMTP_NODE_ADDRESS:-not set}"
        echo "  XMTP_IS_SECURE=${XMTP_IS_SECURE:-not set}"
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
        while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
            echo "==> Attempt $ATTEMPT/$MAX_ATTEMPTS"
            if swift test --skip-build 2>&1 | filter_xmtp_logs; then
                break
            fi

            if [[ $ATTEMPT -eq $MAX_ATTEMPTS ]]; then
                echo ""
                echo "==> Tests failed after $MAX_ATTEMPTS attempts"
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
        swift test --skip-build 2>&1 | filter_xmtp_logs
        ;;
    *)
        echo "Unknown option: $TEST_TYPE"
        echo "Usage: $0 [--unit|--integration]"
        exit 1
        ;;
esac

echo ""
echo "==> Tests completed successfully"
