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

# Check and install tmux (required by convos-task for parallel worktree sessions)
if ! command -v tmux &> /dev/null; then
    echo "Installing tmux..."
    if ! brew install tmux; then
        echo "❌ Failed to install tmux. Please try installing manually:"
        echo "  brew install tmux"
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
# convos-task PATH + alias                                                     #
################################################################################

SHELL_RC_UPDATED=false

if [ ! "${CI}" = true ]; then
    REPO_ROOT="$(cd "${DIRNAME}/.." && pwd)"
    CONVOS_TASK_DIR="${REPO_ROOT}/.claude/scripts"

    if [ -x "${CONVOS_TASK_DIR}/convos-task" ]; then
        case "${SHELL}" in
            */zsh)  SHELL_RC="${HOME}/.zshrc" ;;
            */bash) SHELL_RC="${HOME}/.bashrc" ;;
            *)      SHELL_RC="" ;;
        esac

        if [ -z "${SHELL_RC}" ]; then
            echo "ℹ️ Unrecognized shell (${SHELL}); add to your shell rc manually:"
            echo "    export PATH=\"${CONVOS_TASK_DIR}:\$PATH\""
            echo "    alias ct=\"convos-task\""
        else
            MARKER="# convos-task (added by Scripts/setup.sh)"
            PATH_LINE="export PATH=\"${CONVOS_TASK_DIR}:\$PATH\""
            ALIAS_LINE='alias ct="convos-task"'

            has_path=false
            has_alias=false
            if [ -f "${SHELL_RC}" ]; then
                grep -qF "${CONVOS_TASK_DIR}" "${SHELL_RC}" && has_path=true
                grep -qE '^[[:space:]]*alias[[:space:]]+ct=' "${SHELL_RC}" && has_alias=true
            fi

            if [ "${has_path}" = true ] && [ "${has_alias}" = true ]; then
                echo "✅ convos-task already configured in ${SHELL_RC}"
            else
                {
                    echo ""
                    echo "${MARKER}"
                    [ "${has_path}" = false ] && echo "${PATH_LINE}"
                    [ "${has_alias}" = false ] && echo "${ALIAS_LINE}"
                } >> "${SHELL_RC}"
                echo "✅ Added convos-task to ${SHELL_RC}"
                SHELL_RC_UPDATED=true
            fi
        fi
    fi
fi

################################################################################
# Firebase App Check Debug Token                                                #
################################################################################

if [ ! "${CI}" = true ] || [ "${CLAUDE_SETUP}" = "1" ]; then
    REPO_ROOT="$(cd "${DIRNAME}/.." && pwd)"
    PARENT_DIR="$(dirname "${REPO_ROOT}")"
    PARENT_ENV="${PARENT_DIR}/.env"
    LOCAL_ENV="${REPO_ROOT}/.env"
    FIREBASE_CONSOLE_URL="https://console.firebase.google.com/u/1/project/convos-otr/appcheck/apps"

    # Reads FIREBASE_APP_CHECK_DEBUG_TOKEN from a file, or empty string if missing/unset.
    read_firebase_token() {
        local file="$1"
        [ -f "$file" ] || { echo ""; return; }
        grep "^FIREBASE_APP_CHECK_DEBUG_TOKEN=" "$file" | tail -1 | cut -d'=' -f2-
    }

    # Matches the /firebase-token slash command's "new token" report.
    print_firebase_report() {
        local token="$1"
        local pinned_path="$2"
        local symlink_note="$3"
        echo ""
        echo "🔥 Firebase App Check Debug Token"
        echo ""
        echo "Token: ${token}"
        echo ""
        echo "✓ Pinned in ${pinned_path}"
        if [ -n "${symlink_note}" ]; then
            echo "${symlink_note}"
        fi
        echo ""
        echo "Register it in Firebase Console if you haven't already:"
        echo "${FIREBASE_CONSOLE_URL}"
        echo ""
        echo "1. Click the link"
        echo "2. Pick the iOS app for your scheme:"
        echo "   - Dev:   org.convos.ios-preview"
        echo "   - Local: org.convos.ios-local"
        echo "   - Prod:  org.convos.ios"
        echo "3. Overflow menu (⋮) → Manage debug tokens → Add debug token"
        echo "4. Paste the UUID above"
    }

    LOCAL_TOKEN="$(read_firebase_token "${LOCAL_ENV}")"
    PARENT_TOKEN="$(read_firebase_token "${PARENT_ENV}")"

    if [ -n "${LOCAL_TOKEN}" ] || [ -n "${PARENT_TOKEN}" ]; then
        if [ -L "${LOCAL_ENV}" ]; then
            echo "✅ Firebase App Check debug token is configured (via ${LOCAL_ENV} → $(readlink "${LOCAL_ENV}"))"
        elif [ -f "${LOCAL_ENV}" ] && [ -n "${LOCAL_TOKEN}" ]; then
            echo "✅ Firebase App Check debug token is configured in ${LOCAL_ENV}"
        else
            echo "✅ Firebase App Check debug token is configured in ${PARENT_ENV}"
        fi
    else
        # Nothing set anywhere — generate, pin in parent, symlink local.
        NEW_TOKEN="$(uuidgen)"
        if [ -f "${PARENT_ENV}" ] && grep -q "^FIREBASE_APP_CHECK_DEBUG_TOKEN=" "${PARENT_ENV}"; then
            sed -i.bak "s|^FIREBASE_APP_CHECK_DEBUG_TOKEN=.*|FIREBASE_APP_CHECK_DEBUG_TOKEN=${NEW_TOKEN}|" "${PARENT_ENV}"
            rm -f "${PARENT_ENV}.bak"
        else
            echo "FIREBASE_APP_CHECK_DEBUG_TOKEN=${NEW_TOKEN}" >> "${PARENT_ENV}"
        fi

        SYMLINK_NOTE=""
        if [ ! -e "${LOCAL_ENV}" ] && [ ! -L "${LOCAL_ENV}" ]; then
            ln -s ../.env "${LOCAL_ENV}"
            SYMLINK_NOTE="✓ Linked .env → ../.env at ${LOCAL_ENV}"
        elif [ -L "${LOCAL_ENV}" ]; then
            link_target="$(readlink "${LOCAL_ENV}")"
            SYMLINK_NOTE="✓ .env → ${link_target} symlink already in place at ${LOCAL_ENV}"
        elif [ -f "${LOCAL_ENV}" ]; then
            SYMLINK_NOTE=$'⚠️  '"${LOCAL_ENV}"$' is a regular file, not a symlink.\n   To share one token across worktrees:\n     cat .env >> ../.env && rm .env && ln -s ../.env .env'
        fi

        print_firebase_report "${NEW_TOKEN}" "${PARENT_ENV}" "${SYMLINK_NOTE}"
    fi
fi

################################################################################
# Reload shell so new PATH/alias is live immediately                            #
################################################################################

# If we just added entries to the shell rc, replace this process with a fresh
# interactive shell so 'convos-task' / 'ct' work without the user having to
# source their rc or open a new terminal. Only do this when invoked directly
# from an interactive terminal — skip in CI, under Claude Code's Bash tool,
# when piped, or when run as a subprocess of make/npm/etc. (where exec'ing a
# shell would hang the parent waiting on the script to finish). Use -i
# (interactive non-login) rather than -l so bash sources ~/.bashrc (login
# shells source ~/.bash_profile instead); zsh sources ~/.zshrc in both modes,
# so -i works uniformly.
if [ "${SHELL_RC_UPDATED}" = true ] \
    && [ -t 0 ] && [ -t 1 ] \
    && [ -n "${SHELL}" ] \
    && [ -z "${MAKELEVEL}" ] \
    && [ -z "${npm_lifecycle_event}" ]; then
    echo ""
    echo "🔄 Reloading your shell so 'convos-task' is on PATH..."
    exec "${SHELL}" -i
else
    if [ "${SHELL_RC_UPDATED}" = true ]; then
        echo ""
        echo "ℹ️ Open a new terminal (or run 'source ${SHELL_RC}') to pick up 'convos-task'."
    fi
fi
