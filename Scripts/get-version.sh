#!/usr/bin/env bash
set -e

# Use xcodebuild to get MARKETING_VERSION - most reliable as it uses Xcode's own logic
BUILD_SETTINGS=$(xcodebuild -project Convos.xcodeproj -showBuildSettings 2>/dev/null)

# Extract all MARKETING_VERSION values and get unique ones
VERSIONS=$(echo "$BUILD_SETTINGS" | \
           grep 'MARKETING_VERSION = ' | \
           sed 's/.*MARKETING_VERSION = //' | \
           sort -u)

VERSION_COUNT=$(echo "$VERSIONS" | grep -c .)

if [ "$VERSION_COUNT" -eq 0 ]; then
  echo "❌ Error: MARKETING_VERSION not found" >&2
  exit 1
fi

if [ "$VERSION_COUNT" -gt 1 ]; then
  echo "❌ Error: Version mismatch detected. All targets must have the same version:" >&2
  echo "$VERSIONS" | while read -r v; do echo "  • $v" >&2; done
  exit 1
fi

echo "$VERSIONS"
