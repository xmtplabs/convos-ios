#!/bin/bash
set -e

source "${SRCROOT}/Scripts/secrets-utils.sh"
GIT_SHA=$(get_git_commit_sha "${SRCROOT}")

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
    AGENT_DEBUG_JWKS=""
    POSTHOG_API_KEY=""

    if [ -f "${SRCROOT}/.env" ]; then
        CONVOS_API_BASE_URL=$(grep -v '^#' "${SRCROOT}/.env" | grep '^CONVOS_API_BASE_URL=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
        XMTP_CUSTOM_HOST=$(grep -v '^#' "${SRCROOT}/.env" | grep '^XMTP_CUSTOM_HOST=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
        AGENT_DEBUG_JWKS=$(grep -v '^#' "${SRCROOT}/.env" | grep '^AGENT_DEBUG_JWKS=' | cut -d'=' -f2- | sed -e "s/^'//" -e "s/'$//" || true)
        POSTHOG_API_KEY=$(grep -v '^#' "${SRCROOT}/.env" | grep '^POSTHOG_API_KEY=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi
    # Resolve the XMTP host the same way Scripts/generate-secrets-local.sh does:
    # USE_CONFIG means "no custom host, use the network the config selects", and
    # must stay genuinely empty because the app treats any non-empty value as a
    # local node to dial. Unset falls back to the auto-detected LAN IP as before.
    if [ "$XMTP_CUSTOM_HOST" = "USE_CONFIG" ]; then
        XMTP_HOST_RESOLVED=""
    else
        XMTP_HOST_RESOLVED="${XMTP_CUSTOM_HOST:-$LOCAL_IP}"
    fi
    # Firebase debug token: cached .env first, else 1Password ("Convos" vault); empty in CI.
    FIREBASE_TOKEN="$(resolve_firebase_debug_token "${SRCROOT}/.env")"

    ESCAPED_AGENT_DEBUG_JWKS=$(swift_escape "$AGENT_DEBUG_JWKS")

    cat > "$SECRETS_FILE" << EOF
import Foundation

// swiftlint:disable all
enum Secrets {
    static let CONVOS_API_BASE_URL = "${CONVOS_API_BASE_URL:-http://$LOCAL_IP:4000/api}"
    static let XMTP_CUSTOM_HOST = "${XMTP_HOST_RESOLVED}"
    static let GATEWAY_URL = ""
    static let SENTRY_DSN = ""
    static let POSTHOG_API_KEY = "$POSTHOG_API_KEY"
    static let FIREBASE_APP_CHECK_DEBUG_TOKEN = "$FIREBASE_TOKEN"
    static let GIT_COMMIT_SHA: String = "$(swift_escape "$GIT_SHA")"
    static let AGENT_DEBUG_JWKS: String = "$ESCAPED_AGENT_DEBUG_JWKS"
}
// swiftlint:enable all
EOF
    echo "🏁 Generated Secrets.swift for Local"

# Part 2: Generate Secrets.swift for Dev builds (read Firebase token from .env)
elif [ "$CONFIGURATION" = "Dev" ]; then
    echo "🔧 Dev build detected - generating secrets from .env"

    SECRETS_FILE="${SRCROOT}/Convos/Config/Secrets.swift"
    mkdir -p "${SRCROOT}/Convos/Config"

    # Firebase debug token: cached .env first, else 1Password ("Convos" vault); empty in CI.
    FIREBASE_TOKEN="$(resolve_firebase_debug_token "${SRCROOT}/.env")"
    CONVOS_API_BASE_URL=""
    AGENT_DEBUG_JWKS=""
    POSTHOG_API_KEY=""
    SENTRY_DSN=""
    if [ -f "${SRCROOT}/.env" ]; then
        CONVOS_API_BASE_URL=$(grep -v '^#' "${SRCROOT}/.env" | grep '^CONVOS_API_BASE_URL=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)

        AGENT_DEBUG_JWKS=$(grep -v '^#' "${SRCROOT}/.env" | grep '^AGENT_DEBUG_JWKS=' | cut -d'=' -f2- | sed -e "s/^'//" -e "s/'$//" || true)
        POSTHOG_API_KEY=$(grep -v '^#' "${SRCROOT}/.env" | grep '^POSTHOG_API_KEY=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)

        SENTRY_DSN=$(grep -v '^#' "${SRCROOT}/.env" | grep '^SENTRY_DSN=' | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi

    if [ -n "$FIREBASE_TOKEN" ]; then
        echo "✅ Resolved Firebase debug token (1Password or .env cache)"
    else
        echo "⚠️  No Firebase debug token from 1Password or .env - run /firebase-token"
    fi

    if [ -n "$AGENT_DEBUG_JWKS" ]; then
        echo "✅ Found AGENT_DEBUG_JWKS in .env (DEBUG attestation override active)"
    fi

    if [ -n "$SENTRY_DSN" ]; then
        echo "✅ Found SENTRY_DSN in .env (Sentry enabled for this Dev build)"
    fi

    ESCAPED_AGENT_DEBUG_JWKS=$(swift_escape "$AGENT_DEBUG_JWKS")

    cat > "$SECRETS_FILE" << EOF
import Foundation

// swiftlint:disable all
enum Secrets {
    static let CONVOS_API_BASE_URL = "$CONVOS_API_BASE_URL"
    static let XMTP_CUSTOM_HOST = ""
    static let GATEWAY_URL = ""
    static let POSTHOG_API_KEY = "$POSTHOG_API_KEY"
    static let SENTRY_DSN = "$(swift_escape "$SENTRY_DSN")"
    static let FIREBASE_APP_CHECK_DEBUG_TOKEN = "$FIREBASE_TOKEN"
    static let GIT_COMMIT_SHA: String = "$(swift_escape "$GIT_SHA")"
    static let AGENT_DEBUG_JWKS: String = "$ESCAPED_AGENT_DEBUG_JWKS"
}
// swiftlint:enable all
EOF
    echo "🏁 Generated Secrets.swift for Dev"

# Part 2b: Generate Secrets.swift for LOCAL Prod builds (the "Convos (Prod)" /
# "NotificationService (Prod)" schemes use the "Release" configuration). GATED
# LOCAL-ONLY (mirrors the CI guard at Makefile:50): in CI, `make secrets` runs
# generate-secrets-secure.sh first and injects the real analytics keys, so this
# build phase must NOT clobber that output — the Release branch is skipped when
# $CI or $BITRISE_BUILD_NUMBER is set. Locally we force the backend URL and XMTP
# host EMPTY so ConfigManager falls back to the prod source-of-truth in
# config.prod.json. Values are NEVER read from .env here (that local dev backend
# leak is what this PR fixes); every field is empty except GIT_COMMIT_SHA.
elif [ "$CONFIGURATION" = "Release" ] && [ -z "$CI" ] && [ -z "$BITRISE_BUILD_NUMBER" ]; then
    echo "🚀 Local Prod (Release) build detected - resolving backend from config.prod.json"

    SECRETS_FILE="${SRCROOT}/Convos/Config/Secrets.swift"
    mkdir -p "${SRCROOT}/Convos/Config"

    # Firebase debug token: cached .env first, else 1Password ("Convos" vault); empty in CI.
    FIREBASE_TOKEN="$(resolve_firebase_debug_token "${SRCROOT}/.env")"

    cat > "$SECRETS_FILE" << EOF
import Foundation

// swiftlint:disable all
enum Secrets {
    static let CONVOS_API_BASE_URL = ""
    static let XMTP_CUSTOM_HOST = ""
    static let GATEWAY_URL = ""
    static let POSTHOG_API_KEY = ""
    static let SENTRY_DSN = ""
    static let FIREBASE_APP_CHECK_DEBUG_TOKEN = "$FIREBASE_TOKEN"
    static let GIT_COMMIT_SHA: String = "$(swift_escape "$GIT_SHA")"
    static let AGENT_DEBUG_JWKS: String = ""
}
// swiftlint:enable all
EOF
    echo "🏁 Generated Secrets.swift for local Prod"
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
