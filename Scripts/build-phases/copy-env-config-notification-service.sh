#!/bin/bash
set -e

# Detect git commit SHA (CI env var takes priority, then git, then fallback)
GIT_SHA="${GITHUB_SHA:-${BITRISE_GIT_COMMIT:-}}"
if [ -z "$GIT_SHA" ]; then
    GIT_SHA=$(cd "${SRCROOT}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
else
    GIT_SHA="${GIT_SHA:0:7}"
fi

# Part 1: Generate Secrets.swift for Local builds (auto-detect IP)
if [ "$CONFIGURATION" = "Local" ]; then
    echo "🏠 Local build detected - generating secrets with auto-detected IP"

    SECRETS_FILE="${SRCROOT}/Convos/Config/Secrets.swift"

    LOCAL_IP=$(ifconfig | grep -E "inet [0-9]+" | grep -v "127\\." | grep -v "169\\.254\\." | grep -v "10\\." | grep -v "172\\.1[6-9]\\." | grep -v "172\\.2[0-9]\\." | grep -v "172\\.3[0-1]\\." | grep -v "192\\.168\\." | head -1 | awk '{print $2}')
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(ifconfig | grep -E "inet [0-9]+" | grep -v "127\\." | grep -v "169\\.254\\." | head -1 | awk '{print $2}')
    fi

    if [ -z "$LOCAL_IP" ]; then
        echo "❌ Could not detect local IP address"
        exit 1
    fi
    echo "✅ Detected local IP"
    mkdir -p "${SRCROOT}/Convos/Config"

    CONVOS_API_BASE_URL=""
    XMTP_CUSTOM_HOST=""
    FIREBASE_TOKEN=""

    if [ -f "${SRCROOT}/.env" ]; then
        CONVOS_API_BASE_URL=$(grep -v '^#' "${SRCROOT}/.env" | grep '^CONVOS_API_BASE_URL=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
        XMTP_CUSTOM_HOST=$(grep -v '^#' "${SRCROOT}/.env" | grep '^XMTP_CUSTOM_HOST=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
        FIREBASE_TOKEN=$(grep -v '^#' "${SRCROOT}/.env" | grep '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi

    cat > "$SECRETS_FILE" << EOF
import Foundation

// swiftlint:disable all
enum Secrets {
    static let CONVOS_API_BASE_URL = "${CONVOS_API_BASE_URL:-http://$LOCAL_IP:4000/api}"
    static let XMTP_CUSTOM_HOST = "${XMTP_CUSTOM_HOST:-$LOCAL_IP}"
    static let GATEWAY_URL = ""
    static let SENTRY_DSN = ""
    static let FIREBASE_APP_CHECK_DEBUG_TOKEN = "$FIREBASE_TOKEN"
    static let GIT_COMMIT_SHA = "$GIT_SHA"
}
// swiftlint:enable all
EOF
    echo "🏁 Generated Secrets.swift for Local"

# Part 2: Generate Secrets.swift for Dev builds (read Firebase token from .env)
elif [ "$CONFIGURATION" = "Dev" ]; then
    echo "🔧 Dev build detected - generating secrets from .env"

    SECRETS_FILE="${SRCROOT}/Convos/Config/Secrets.swift"
    mkdir -p "${SRCROOT}/Convos/Config"

    FIREBASE_TOKEN=""
    CONVOS_API_BASE_URL=""
    if [ -f "${SRCROOT}/.env" ]; then
        FIREBASE_TOKEN=$(grep -v '^#' "${SRCROOT}/.env" | grep '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)

        CONVOS_API_BASE_URL=$(grep -v '^#' "${SRCROOT}/.env" | grep '^CONVOS_API_BASE_URL=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi

    if [ -n "$FIREBASE_TOKEN" ]; then
        echo "✅ Found Firebase debug token in .env"
    else
        echo "⚠️  No Firebase debug token in .env - you may need to register tokens manually"
    fi

    cat > "$SECRETS_FILE" << EOF
import Foundation

// swiftlint:disable all
enum Secrets {
    static let CONVOS_API_BASE_URL = "$CONVOS_API_BASE_URL"
    static let XMTP_CUSTOM_HOST = ""
    static let GATEWAY_URL = ""
    static let SENTRY_DSN = ""
    static let FIREBASE_APP_CHECK_DEBUG_TOKEN = "$FIREBASE_TOKEN"
    static let GIT_COMMIT_SHA = "$GIT_SHA"
}
// swiftlint:enable all
EOF
    echo "🏁 Generated Secrets.swift for Dev"
fi

# Part 3: Copy config file to app bundle
if [[ "$CONFIG_FILE" = /* ]]; then
    CONFIG_SOURCE="$CONFIG_FILE"
else
    CONFIG_SOURCE="${SRCROOT}/Convos/Config/${CONFIG_FILE}"
fi

CONFIG_DEST="${CODESIGNING_FOLDER_PATH}/config.json"

if [ ! -f "$CONFIG_SOURCE" ]; then
    echo "error: Config file not found: $CONFIG_SOURCE (CONFIG_FILE=$CONFIG_FILE)"
    exit 1
fi

echo "📋 Copying config file to app bundle"
cp "$CONFIG_SOURCE" "$CONFIG_DEST"
echo "✅ Config copied successfully"
