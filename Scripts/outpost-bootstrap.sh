#!/bin/bash
# Bootstrap a fresh macOS machine (e.g. a cloud devbox) to build Convos and
# run the qa/ smoke: selects the pinned Xcode, installs idb and the convos
# CLI, and verifies every tool. Idempotent; installs nothing that is already
# present. Never touches a secret.
#
# Usage:
#   Scripts/outpost-bootstrap.sh          # install + verify, then print exports
#   eval "$(Scripts/outpost-bootstrap.sh --env)"   # exports only, for a shell
set -euo pipefail

# The pinned toolchain. Authority: .github/workflows/warm-xcode-cache.yml
# (xcode-path) — keep in sync when the CI pin moves.
PINNED_XCODE="/Applications/Xcode_26.3.app"

# fb-idb's client crashes under Python >= 3.14 (asyncio.get_event_loop was
# removed), so it gets its own Python 3.13 venv.
IDB_VENV="${HOME}/.convos-qa/idbvenv"

emit_env() {
	echo "export DEVELOPER_DIR=\"${PINNED_XCODE}\""
	echo "export PATH=\"${IDB_VENV}/bin:\${PATH}\""
}

if [[ "${1:-}" == "--env" ]]; then
	emit_env
	exit 0
fi

fail() {
	echo "outpost-bootstrap: $1" >&2
	exit 1
}

step() { echo "==> $1"; }

# Xcode: verify the pin exists; never mutate the machine default
# (xcode-select) — every build must pass DEVELOPER_DIR explicitly.
step "Xcode pin"
if [[ ! -d "${PINNED_XCODE}" ]]; then
	echo "Installed Xcodes:" >&2
	ls -d /Applications/Xcode*.app >&2 || true
	fail "pinned Xcode not found at ${PINNED_XCODE}"
fi
DEVELOPER_DIR="${PINNED_XCODE}" xcodebuild -version

step "Homebrew"
command -v brew >/dev/null || fail "Homebrew is required and not installed"
brew --version | head -1

step "idb-companion"
if ! command -v idb_companion >/dev/null; then
	brew tap facebook/fb
	brew install idb-companion
fi
command -v idb_companion >/dev/null || fail "idb_companion did not install"

step "idb client (Python 3.13 venv)"
if [[ ! -x "${IDB_VENV}/bin/idb" ]]; then
	PY313="$(command -v python3.13 || true)"
	if [[ -z "${PY313}" ]]; then
		brew install python@3.13
		PY313="$(brew --prefix python@3.13)/bin/python3.13"
	fi
	"${PY313}" -m venv "${IDB_VENV}"
	"${IDB_VENV}/bin/pip" install --quiet fb-idb
fi
"${IDB_VENV}/bin/idb" --help >/dev/null || fail "idb client is not runnable"
echo "idb: ${IDB_VENV}/bin/idb"

step "convos CLI"
if ! command -v convos >/dev/null; then
	command -v npm >/dev/null || fail "npm is required to install @xmtp/convos-cli"
	npm install -g @xmtp/convos-cli
fi
convos --version

step "convos CLI dev config"
if [[ ! -f "${HOME}/.convos/.env" ]]; then
	convos init --env dev
fi
convos identity list >/dev/null || fail "convos CLI is not usable after init"

echo
echo "Bootstrap complete. Load the environment into your shell with:"
echo "  eval \"\$(Scripts/outpost-bootstrap.sh --env)\""
emit_env
