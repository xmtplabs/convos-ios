#!/usr/bin/env bash

# Exit on any error and ensure pipeline failures are caught
set -e
set -o pipefail

# This script generates the Secrets.swift file for Local development
# It automatically detects the local IP address and populates the secrets
# It also ensures the file exists with minimal content if needed
#
# Configuration Priority (.env values):
# - Missing/Empty/Commented: Auto-detect local IP (default)
# - "USE_CONFIG": Use value from config.local.json (or empty for XMTP/Gateway)
# - Custom value: Use that value explicitly
#
# Examples:
#   CONVOS_API_BASE_URL=                    → Auto-detect IP
#   CONVOS_API_BASE_URL=USE_CONFIG          → Use config.json default
#   CONVOS_API_BASE_URL=http://10.0.1.5:4000/api → Use custom URL
#
# Usage: ./generate-secrets-local.sh

# Source shared utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/secrets-utils.sh"

# The paths to the Secrets.swift files (main app and app clip)
SECRETS_FILE_APP="Convos/Config/Secrets.swift"
SECRETS_FILE_APPCLIP="ConvosAppClip/Config/Secrets.swift"

# Create the output directories if they don't exist
ensure_secrets_directories

# Function to create minimal Secrets.swift if it doesn't exist or is empty
ensure_minimal_secrets() {
    local secrets_file=$1
    if [ ! -f "$secrets_file" ] || [ ! -s "$secrets_file" ]; then
        echo "🔑 Creating minimal Secrets.swift file first: $secrets_file"

        cat >"$secrets_file" <<'MINIMAL_EOF'
import Foundation

// WARNING:
// This is a minimal Secrets.swift file created automatically.
// Building the "Convos (Local)" scheme will replace this with auto-detected IP addresses.

enum Secrets {
    static let CONVOS_API_BASE_URL: String = ""
    static let XMTP_CUSTOM_HOST: String = ""
    static let GATEWAY_URL: String = ""
    static let SENTRY_DSN: String = ""
    static let FIREBASE_APP_CHECK_DEBUG_TOKEN: String = ""
}

MINIMAL_EOF
        echo "✅ Created minimal Secrets.swift file"
        return 0
    fi
    return 1
}

# If called with --ensure-only flag, just ensure minimal file exists and exit
if [ "$1" = "--ensure-only" ]; then
    if ensure_minimal_secrets "$SECRETS_FILE_APP"; then
        echo "✅ Minimal Secrets.swift created for main app - ready for building"
    else
        echo "✅ Secrets.swift already exists for main app"
    fi
    if ensure_minimal_secrets "$SECRETS_FILE_APPCLIP"; then
        echo "✅ Minimal Secrets.swift created for app clip - ready for building"
    else
        echo "✅ Secrets.swift already exists for app clip"
    fi
    exit 0
fi

echo "🔍 Detecting configuration for Local development..."

# Ensure minimal files exist first (in case this is the first run)
# The function returns 0 if file was created, 1 if it already exists
if ensure_minimal_secrets "$SECRETS_FILE_APP"; then
    echo "Created minimal secrets for app"
fi
if ensure_minimal_secrets "$SECRETS_FILE_APPCLIP"; then
    echo "Created minimal secrets for app clip"
fi

# Function to get the first routable IPv4 address
get_local_ip() {
    # Get all network interfaces and find the first routable IPv4 address
    # Exclude:
    # - 127.x.x.x (loopback)
    # - 169.254.x.x (link-local/APIPA - indicates DHCP failure)
    # - 0.0.0.0 (invalid)
    # Prefer in order:
    # 1. Public IP addresses (not in private ranges)
    # 2. Private network addresses (10.x.x.x, 172.16-31.x.x, 192.168.x.x)

    # First try to get a public IP (not in private ranges)
    local public_ip=$(ifconfig | grep -E "inet [0-9]+" | \
        grep -v "127\." | \
        grep -v "169\.254\." | \
        grep -v "10\." | \
        grep -v "172\.1[6-9]\." | \
        grep -v "172\.2[0-9]\." | \
        grep -v "172\.3[0-1]\." | \
        grep -v "192\.168\." | \
        head -1 | awk '{print $2}')

    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return
    fi

    # If no public IP, get the first private network IP (but not link-local)
    local private_ip=$(ifconfig | grep -E "inet [0-9]+" | \
        grep -v "127\." | \
        grep -v "169\.254\." | \
        head -1 | awk '{print $2}')

    echo "$private_ip"
}

# Function to extract value from config JSON
get_config_value() {
    local config_file=$1
    local key=$2
    if [ -f "$config_file" ]; then
        # Use python to parse JSON (available on macOS by default)
        # Type-check to avoid printing "None" for null values
        python3 -c "import json; v=json.load(open('$config_file')).get('$key', ''); print(v if isinstance(v, str) else '')" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Load defaults from config.local.json
CONFIG_FILE="Convos/Config/config.local.json"
DEFAULT_BACKEND_URL=$(get_config_value "$CONFIG_FILE" "backendUrl")

# Detect the local IP for auto-configuration
LOCAL_IP=$(get_local_ip)

# Read .env overrides if they exist
ENV_BACKEND_URL=""
ENV_XMTP_HOST=""
ENV_GATEWAY_URL=""
ENV_SENTRY_DSN=""
ENV_FIREBASE_DEBUG_TOKEN=""
ENV_HAS_BACKEND_URL=false
ENV_HAS_XMTP_HOST=false
ENV_HAS_GATEWAY_URL=false

if [ -f ".env" ]; then
    echo "📋 Checking .env for overrides..."
    # Check if keys exist in .env (even if empty)
    if grep -v '^#' ".env" | grep -q '^CONVOS_API_BASE_URL='; then
        ENV_HAS_BACKEND_URL=true
        ENV_BACKEND_URL=$(grep -v '^#' ".env" | grep '^CONVOS_API_BASE_URL=' | tail -n1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi
    if grep -v '^#' ".env" | grep -q '^XMTP_CUSTOM_HOST='; then
        ENV_HAS_XMTP_HOST=true
        ENV_XMTP_HOST=$(grep -v '^#' ".env" | grep '^XMTP_CUSTOM_HOST=' | tail -n1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi
    if grep -v '^#' ".env" | grep -q '^GATEWAY_URL='; then
        ENV_HAS_GATEWAY_URL=true
        ENV_GATEWAY_URL=$(grep -v '^#' ".env" | grep '^GATEWAY_URL=' | tail -n1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi
    if grep -v '^#' ".env" | grep -q '^SENTRY_DSN='; then
        ENV_SENTRY_DSN=$(grep -v '^#' ".env" | grep '^SENTRY_DSN=' | tail -n1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi
    if grep -v '^#' ".env" | grep -q '^FIREBASE_APP_CHECK_DEBUG_TOKEN='; then
        ENV_FIREBASE_DEBUG_TOKEN=$(grep -v '^#' ".env" | grep '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' | tail -n1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' || true)
    fi
fi

# Determine final values for Secrets.swift (Tier 1 of two-tier system)
# Priority: .env "USE_CONFIG" > .env custom value > auto-detected IP > config.json default
# Swift (ConfigManager.swift) provides isEmpty fallback to config.json as Tier 2
FINAL_BACKEND_URL=""
FINAL_XMTP_HOST=""
FINAL_GATEWAY_URL=""

# CONVOS_API_BASE_URL logic
if [ "$ENV_HAS_BACKEND_URL" = true ] && [ "$ENV_BACKEND_URL" = "USE_CONFIG" ]; then
    # Explicitly requesting config.json default
    FINAL_BACKEND_URL="$DEFAULT_BACKEND_URL"
    echo "✅ Using CONVOS_API_BASE_URL from config.json (explicit USE_CONFIG): $FINAL_BACKEND_URL"
elif [ "$ENV_HAS_BACKEND_URL" = true ] && [ -n "$ENV_BACKEND_URL" ]; then
    # Custom value from .env
    FINAL_BACKEND_URL="$ENV_BACKEND_URL"
    echo "✅ Using CONVOS_API_BASE_URL from .env: $FINAL_BACKEND_URL"
elif [ -n "$LOCAL_IP" ]; then
    # Auto-detect (when .env missing, empty, or commented)
    FINAL_BACKEND_URL="http://$LOCAL_IP:4000/api"
    echo "✅ Auto-detected CONVOS_API_BASE_URL: $FINAL_BACKEND_URL"
elif [ -n "$DEFAULT_BACKEND_URL" ]; then
    # Fallback when IP detection fails
    FINAL_BACKEND_URL="$DEFAULT_BACKEND_URL"
    echo "✅ Using CONVOS_API_BASE_URL from config.json (fallback): $FINAL_BACKEND_URL"
else
    FINAL_BACKEND_URL=""
    echo "⚠️  CONVOS_API_BASE_URL will be empty"
fi

# XMTP_CUSTOM_HOST logic
if [ "$ENV_HAS_XMTP_HOST" = true ] && [ "$ENV_XMTP_HOST" = "USE_CONFIG" ]; then
    # Explicitly requesting no custom host (use default XMTP network)
    FINAL_XMTP_HOST=""
    echo "✅ Using XMTP_CUSTOM_HOST from config (explicit USE_CONFIG): empty (default network)"
elif [ "$ENV_HAS_XMTP_HOST" = true ] && [ -n "$ENV_XMTP_HOST" ]; then
    # Custom value from .env
    FINAL_XMTP_HOST="$ENV_XMTP_HOST"
    echo "✅ Using XMTP_CUSTOM_HOST from .env: $FINAL_XMTP_HOST"
elif [ -n "$LOCAL_IP" ]; then
    # Auto-detect (when .env missing, empty, or commented)
    FINAL_XMTP_HOST="$LOCAL_IP"
    echo "✅ Auto-detected XMTP_CUSTOM_HOST: $FINAL_XMTP_HOST"
else
    # Fallback when IP detection fails (use default network)
    FINAL_XMTP_HOST=""
    echo "✅ XMTP_CUSTOM_HOST will be empty (default network)"
fi

# GATEWAY_URL logic (for d14n - decentralized network)
if [ "$ENV_HAS_GATEWAY_URL" = true ] && [ "$ENV_GATEWAY_URL" = "USE_CONFIG" ]; then
    # Explicitly requesting no gateway (direct XMTP connection)
    FINAL_GATEWAY_URL=""
    echo "✅ Using GATEWAY_URL from config (explicit USE_CONFIG): empty (direct connection)"
elif [ "$ENV_HAS_GATEWAY_URL" = true ] && [ -n "$ENV_GATEWAY_URL" ]; then
    # Custom gateway URL from .env
    FINAL_GATEWAY_URL="$ENV_GATEWAY_URL"
    echo "✅ Using GATEWAY_URL from .env: $FINAL_GATEWAY_URL (d14n mode)"
else
    # Default: no gateway, direct XMTP connection
    FINAL_GATEWAY_URL=""
    echo "ℹ️  GATEWAY_URL not set - using direct XMTP connection"
fi

# Function to generate a Secrets.swift file
generate_secrets_file() {
    local secrets_file=$1
    echo "🔑 Generating $secrets_file for Local development"

    # Generate Secrets.swift with determined values
    cat >"$secrets_file" <<EOF
import Foundation

// WARNING:
// This code is generated by ./Scripts/generate-secrets-local.sh for Local development.
// Do not edit this file directly. Your changes will be lost on next build.
// Git does not track this file.
// Priority: .env overrides > auto-detected IP > config.json defaults > empty string
// For other environments, edit the .env file and run ./Scripts/generate-secrets.sh

/// Secrets are generated automatically for Local development
enum Secrets {
    static let CONVOS_API_BASE_URL: String = "$(swift_escape "$FINAL_BACKEND_URL")"
    static let XMTP_CUSTOM_HOST: String = "$(swift_escape "$FINAL_XMTP_HOST")"
    static let GATEWAY_URL: String = "$(swift_escape "$FINAL_GATEWAY_URL")"
    static let SENTRY_DSN: String = "$(swift_escape "$ENV_SENTRY_DSN")"
    static let FIREBASE_APP_CHECK_DEBUG_TOKEN: String = "$(swift_escape "$ENV_FIREBASE_DEBUG_TOKEN")"
EOF

# Check if .env file exists and add any additional secrets from it
if [ -f ".env" ]; then
    echo "📋 Adding additional secrets from .env file..."

    # Read each line from .env file, handles missing newline at EOF
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ $key =~ ^#.*$ ]] && continue
        [[ -z $key ]] && continue

        # Skip the keys we already handled
        [[ "$key" == "CONVOS_API_BASE_URL" ]] && continue
        [[ "$key" == "XMTP_CUSTOM_HOST" ]] && continue
        [[ "$key" == "GATEWAY_URL" ]] && continue
        [[ "$key" == "SENTRY_DSN" ]] && continue
        [[ "$key" == "FIREBASE_APP_CHECK_DEBUG_TOKEN" ]] && continue

        # Validate Swift identifier
        if ! is_valid_swift_identifier "$key"; then
            echo "⚠️  Skipping invalid Swift identifier: $key" >&2
            continue
        fi

        # Remove any quotes from the value
        value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//')

        # Escape the value to prevent injection
        escaped_value=$(swift_escape "$value")

        # Add the secret to the Swift file
        echo "    static let $key: String = \"$escaped_value\"" >>"$secrets_file"
    done <.env
else
    echo "⚠️  No .env file found, using defaults from config.json"
fi

cat >>"$secrets_file" <<'EOF'
}
EOF
}

# Generate Secrets.swift for both targets
generate_secrets_file "$SECRETS_FILE_APP"
generate_secrets_file "$SECRETS_FILE_APPCLIP"

echo "🏁 Generated Secrets.swift files successfully"
echo "🔗 CONVOS_API_BASE_URL: $FINAL_BACKEND_URL"
echo "🌐 XMTP_CUSTOM_HOST: $FINAL_XMTP_HOST"
echo "🌍 GATEWAY_URL: ${FINAL_GATEWAY_URL:-'(not set - using XMTP v3 network)'}"
