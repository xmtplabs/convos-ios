#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Read version from VERSION file
VERSION=$(cat VERSION | tr -d '[:space:]')
echo "CLI Version: $VERSION"

# Export for Bitrise (creates envman variable if available)
if command -v envman &> /dev/null; then
    envman add --key CLI_VERSION --value "$VERSION"
    envman add --key CLI_TAG --value "cli-v$VERSION"
fi

# Configuration (can be overridden via environment)
DEFAULT_IDENTITY="Developer ID Application: XMTP, Inc. (FY4NZR34Z3)"
IDENTITY="${CODE_SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
BUILD_CONFIG="${1:-debug}"
NOTARIZE="${NOTARIZE:-false}"

# Build the CLI
echo "Building convos CLI ($BUILD_CONFIG)..."
if [ "$BUILD_CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

BINARY_PATH=".build/$BUILD_CONFIG/convos"

# Keychain diagnostics (helps debug CI issues)
echo "=== Keychain diagnostics ==="
echo "Keychain search list:"
security list-keychains
echo ""
echo "Available codesigning identities:"
security find-identity -v -p codesigning
echo "=== End diagnostics ==="

# Sign the binary
echo "Signing binary with: $IDENTITY"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$BINARY_PATH"
echo "Signed: $BINARY_PATH"

# Notarize if requested (requires APPLE_ID, TEAM_ID, APP_SPECIFIC_PASSWORD env vars)
if [ "$NOTARIZE" = "true" ]; then
    echo "Notarizing..."
    cd .build/$BUILD_CONFIG
    zip -j convos.zip convos
    xcrun notarytool submit convos.zip \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_SPECIFIC_PASSWORD" \
        --wait
    rm convos.zip
    echo "Notarization complete!"
fi

echo "Build complete: $BINARY_PATH"
