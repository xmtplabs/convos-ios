#!/usr/bin/env bash

# A hook script to verify what is about to be pushed.  Called by "git push"
# after it has checked the remote status, but before anything has been pushed.
# If this script exits with a non-zero status nothing will be pushed.
#
# This hook is called with the following parameters:
#
# $1 -- Name of the remote to which the push is being done
# $2 -- URL to which the push is being done
#
# If pushing without using a named remote those arguments will be equal.
#
# Information about the commits which are being pushed is supplied as lines to
# the standard input in the form:
#
#   <local ref> <local sha1> <remote ref> <remote sha1>
#

set -euo pipefail

# Check if SwiftLint is installed
if ! command -v swiftlint &> /dev/null; then
	echo "❌ SwiftLint is not installed"
	echo "Please install SwiftLint using:"
	echo "  brew install swiftlint"
	exit 1
fi

z40=0000000000000000000000000000000000000000
git_root="$(git rev-parse --show-toplevel)"

while read -r local_ref local_sha remote_ref remote_sha; do
	if [ "$local_sha" = "$z40" ]; then
		# Handle delete - nothing to lint
		continue
	fi

	# Determine the base commit for comparison
	if [ "$remote_sha" = "$z40" ]; then
		# New branch - compare against main/master
		if git rev-parse --verify origin/main >/dev/null 2>&1; then
			base_sha="origin/main"
		elif git rev-parse --verify origin/master >/dev/null 2>&1; then
			base_sha="origin/master"
		else
			# Fallback: lint all Swift files in the commit
			base_sha="$local_sha^"
		fi
	else
		base_sha="$remote_sha"
	fi

	# Get changed Swift files that still exist (excluding generated protobuf files)
	changed_files=()
	while IFS= read -r file; do
		if [ -f "$git_root/$file" ]; then
			changed_files+=("$git_root/$file")
		fi
	done < <(git diff --name-only --diff-filter=d "$base_sha" "$local_sha" 2>/dev/null | grep '\.swift$' | grep -v '\.pb\.swift$' || true)

	if [ ${#changed_files[@]} -eq 0 ]; then
		echo "✅ No Swift files changed, skipping lint"
		continue
	fi

	echo "🔎 Linting ${#changed_files[@]} changed Swift file(s)..."

	if swiftlint lint --strict --config "$git_root/.swiftlint.yml" "${changed_files[@]}"; then
		echo "✅ No SwiftLint violations, pushing!"
	else
		echo ""
		echo "❌ Found SwiftLint violations, fix them before pushing."
		exit 1
	fi
done

exit 0
