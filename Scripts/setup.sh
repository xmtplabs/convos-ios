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
  # assumes you are in ./Scripts/ folder
  git_dir="${DIRNAME}/../.git"
  pre_commit_file="../../Scripts/hooks/pre-commit"
  pre_push_file="../../Scripts/hooks/pre-push"
  post_checkout_file="../../Scripts/hooks/post-checkout"
  post_merge_file="../../Scripts/hooks/post-merge"

  info "Installing Git hooks..."
  cd "${git_dir}"
  if [ ! -L hooks/pre-push ]; then
      ln -sf "${pre_push_file}" hooks/pre-push
  fi
  if [ ! -L hooks/pre-commit ]; then
      ln -sf "${pre_commit_file}" hooks/pre-commit
  fi
  if [ ! -L hooks/post-checkout ]; then
      ln -sf "${post_checkout_file}" hooks/post-checkout
  fi
  if [ ! -L hooks/post-merge ]; then
      ln -sf "${post_merge_file}" hooks/post-merge
  fi
  cd "${DIRNAME}"
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

# Check and install SwiftLint (pinned to 0.62.2 for compatibility with project)
SWIFTLINT_VERSION="0.62.2"
install_swiftlint() {
    echo "Installing SwiftLint ${SWIFTLINT_VERSION}..."
    local tmp_dir=$(mktemp -d)
    curl -sL "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" -o "${tmp_dir}/swiftlint.zip"
    unzip -o "${tmp_dir}/swiftlint.zip" -d "${tmp_dir}"
    sudo mv "${tmp_dir}/swiftlint" /usr/local/bin/swiftlint
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

if [ ! "${CI}" = true ]; then
    ENV_FILE="${DIRNAME}/../.env"
    if [ ! -f "$ENV_FILE" ]; then
        echo ""
        echo "⚠️  No .env file found"
        echo "   Create one to configure local development settings."
        echo "   See: https://console.firebase.google.com/project/convos-otr/appcheck for debug tokens"
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
