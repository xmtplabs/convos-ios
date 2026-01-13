#!/bin/bash
# Claude Code pre-commit hook
# Runs SwiftLint and SwiftFormat on staged Swift files

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 Running pre-commit checks..."

# Get staged Swift files
STAGED_SWIFT_FILES=$(git diff --cached --name-only --diff-filter=d | grep '\.swift$' || true)

if [ -z "$STAGED_SWIFT_FILES" ]; then
    echo -e "${GREEN}✓ No Swift files staged, skipping checks${NC}"
    exit 0
fi

echo "📝 Checking ${STAGED_SWIFT_FILES}"

# Check if SwiftFormat is available
if command -v swiftformat &> /dev/null; then
    echo "🎨 Running SwiftFormat..."
    echo "$STAGED_SWIFT_FILES" | xargs swiftformat

    # Re-add formatted files
    echo "$STAGED_SWIFT_FILES" | xargs git add
else
    echo -e "${YELLOW}⚠ SwiftFormat not found, skipping formatting${NC}"
fi

# Check if SwiftLint is available
if command -v swiftlint &> /dev/null; then
    echo "🔎 Running SwiftLint..."

    # Run SwiftLint with auto-fix on staged files
    LINT_ERRORS=0
    for file in $STAGED_SWIFT_FILES; do
        if [ -f "$file" ]; then
            swiftlint lint --fix --path "$file" 2>/dev/null || true

            # Check for remaining errors
            if ! swiftlint lint --quiet --path "$file" 2>/dev/null; then
                LINT_ERRORS=$((LINT_ERRORS + 1))
                echo -e "${RED}✗ Lint errors in: $file${NC}"
            fi
        fi
    done

    # Re-add files after auto-fix
    echo "$STAGED_SWIFT_FILES" | xargs git add

    if [ $LINT_ERRORS -gt 0 ]; then
        echo -e "${RED}✗ SwiftLint found errors that couldn't be auto-fixed${NC}"
        echo "Run 'swiftlint' to see details"
        exit 1
    fi

    echo -e "${GREEN}✓ SwiftLint passed${NC}"
else
    echo -e "${YELLOW}⚠ SwiftLint not found, skipping lint check${NC}"
fi

echo -e "${GREEN}✓ Pre-commit checks passed${NC}"
exit 0
