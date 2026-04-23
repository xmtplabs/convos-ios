#!/usr/bin/env bash

# Exit on any error and ensure pipeline failures are caught
set -e
set -o pipefail

# style the output
function info {
  echo "[$(basename "${0}")] [INFO] ${1}"
}

# style the output
function die {
  echo "[$(basename "${0}")] [ERROR] ${1}"
  exit 1
}

# get the directory name of the script
DIRNAME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# setup developer environment

if [ ! "${CI}" = true ]; then
  info "Configuring Git hooks..."
  # Use core.hooksPath so hooks work in both the main clone and any git worktree.
  # This replaces the previous per-hook symlinks into .git/hooks, which were
  # broken inside worktrees (where .git is a file, not a directory).
  repo_root="$(cd "${DIRNAME}/.." && pwd)"
  (cd "${repo_root}" && git config core.hooksPath Scripts/hooks)
  # Ensure hook files are executable (they're tracked as +x, but be safe).
  chmod +x "${repo_root}/Scripts/hooks/"*
fi

################################################################################
# Xcode                                                                        #
################################################################################

if [ ! "${CI}" = true ]; then
  info "Installing Xcode defaults..."
  defaults write com.apple.dt.Xcode DVTTextEditorTrimTrailingWhitespace -bool true
  defaults write com.apple.dt.Xcode DVTTextEditorTrimWhitespaceOnlyLines -bool true
  defaults write com.apple.dt.Xcode DVTTextPageGuideLocation -int 120
  defaults write com.apple.dt.Xcode ShowBuildOperationDuration -bool true
fi

  # Skip fingerprint validation for SPM plugins and macros in Xcode
  defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
  defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

################################################################################
# Setup Dependencies                                                           #
################################################################################

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    echo "❌ Homebrew is not installed. Please install Homebrew first."
    echo "You can install Homebrew using:"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi

# Check Xcode version (README requires 16+)
if command -v xcodebuild &> /dev/null; then
    xcode_major="$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ {split($2, v, "."); print v[1]; exit}')"
    if [ -n "${xcode_major}" ] && [ "${xcode_major}" -lt 16 ]; then
        die "Xcode 16+ is required (detected Xcode ${xcode_major}). Update via the App Store or https://xcodereleases.com"
    fi
fi

# Check and install SwiftLint (pinned for compatibility with the project's rules)
SWIFTLINT_VERSION="0.62.2"
SWIFTLINT_INSTALL_DIR="$(brew --prefix)/bin"  # user-writable, avoids sudo; in PATH on both Intel & Apple Silicon
install_swiftlint() {
    echo "Installing SwiftLint ${SWIFTLINT_VERSION} to ${SWIFTLINT_INSTALL_DIR}..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    curl -sL "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" -o "${tmp_dir}/swiftlint.zip"
    unzip -o "${tmp_dir}/swiftlint.zip" -d "${tmp_dir}" >/dev/null
    mv -f "${tmp_dir}/swiftlint" "${SWIFTLINT_INSTALL_DIR}/swiftlint"
    chmod +x "${SWIFTLINT_INSTALL_DIR}/swiftlint"
    rm -rf "${tmp_dir}"
}

if ! command -v swiftlint &> /dev/null; then
    install_swiftlint
elif [[ "$(swiftlint version)" != "${SWIFTLINT_VERSION}" ]]; then
    echo "SwiftLint version mismatch. Found $(swiftlint version), expected ${SWIFTLINT_VERSION}."
    echo "Updating SwiftLint..."
    install_swiftlint
fi
echo "✅ SwiftLint ${SWIFTLINT_VERSION} is installed"

# Check and install SwiftFormat
if ! command -v swiftformat &> /dev/null; then
    echo "Installing SwiftFormat..."
    if ! brew install swiftformat; then
        echo "❌ Failed to install SwiftFormat. Please try installing manually:"
        echo "  brew install swiftformat"
        exit 1
    fi
fi

# Check and install swift-protobuf
if ! command -v protoc-gen-swift &> /dev/null; then
    echo "Installing swift-protobuf..."
    if ! brew install swift-protobuf; then
        echo "❌ Failed to install swift-protobuf. Please try installing manually:"
        echo "  brew install swift-protobuf"
        exit 1
    fi
fi

# Check and install GitHub CLI (skip installing in CI)
if [ ! "${CI}" = true ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "Installing GitHub CLI..."
        if ! brew install gh; then
            echo "❌ Failed to install GitHub CLI. Please try installing manually:"
            echo "  brew install gh"
            exit 1
        fi
    fi
    # Verify gh is working
    if ! gh --version >/dev/null 2>&1; then
        echo "⚠️ gh installed but not working properly"
        echo "Try reinstalling: brew uninstall gh && brew install gh"
    else
        echo "✅ GitHub CLI is working"
        # Check authentication status
        if ! gh auth status >/dev/null 2>&1; then
            echo "ℹ️ GitHub CLI is not authenticated"
            echo "Run: gh auth login (to enable release automation)"
            echo "Or set GITHUB_TOKEN environment variable"
        else
            echo "✅ GitHub CLI is authenticated"
        fi
    fi
else
    echo "ℹ️ CI environment detected - GitHub CLI should be pre-installed in CI image"
fi

echo "✅ All dependencies are properly installed"

################################################################################
# Firebase App Check Debug Token                                                #
################################################################################

if [ ! "${CI}" = true ] || [ "${CLAUDE_SETUP}" = "1" ]; then
    ENV_FILE="${DIRNAME}/../.env"
    if [ ! -f "$ENV_FILE" ]; then
        echo ""
        echo "⚠️  No .env file found at ${ENV_FILE}"
        echo "   If this is a worktree, symlink the parent's .env:"
        echo "     ln -s ../.env .env"
        echo "   Otherwise copy the template and add a FIREBASE_APP_CHECK_DEBUG_TOKEN from"
        echo "   https://console.firebase.google.com/project/convos-otr/appcheck :"
        echo "     cp .env.example .env"
    elif ! grep -q "^FIREBASE_APP_CHECK_DEBUG_TOKEN=" "$ENV_FILE" || \
         [ -z "$(grep "^FIREBASE_APP_CHECK_DEBUG_TOKEN=" "$ENV_FILE" | cut -d'=' -f2-)" ]; then
        echo ""
        echo "⚠️  FIREBASE_APP_CHECK_DEBUG_TOKEN is not set in .env"
        echo "   Without this, you'll need to register a new debug token in Firebase Console"
        echo "   each time the simulator changes."
        echo ""
        echo "   To fix:"
        echo "   1. Run: uuidgen"
        echo "   2. Go to Firebase Console → App Check → Manage debug tokens"
        echo "   3. Add the generated UUID as a debug token"
        echo "   4. Add to .env: FIREBASE_APP_CHECK_DEBUG_TOKEN=<your-uuid>"
    else
        echo "✅ Firebase App Check debug token is configured"
    fi
fi
