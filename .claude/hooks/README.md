# Claude Code Hooks

This directory contains hook scripts that can be used with Claude Code and Git.

## Available Hooks

### pre-commit.sh

Runs SwiftLint and SwiftFormat on staged Swift files before each commit.

**Features:**
- Automatically formats staged Swift files with SwiftFormat
- Runs SwiftLint with auto-fix enabled
- Blocks commits if unfixable lint errors remain
- Re-stages files after formatting

### pre-push.sh

Runs SwiftLint on changed Swift files before pushing.

**Features:**
- Only lints Swift files that changed (not the entire repo)
- Smart base detection for new vs existing branches
- Skips lint when no Swift files changed
- Blocks push if lint errors are found

## Installation

### Option 1: Symlink to Git hooks

```bash
# From project root
ln -sf ../../.claude/hooks/pre-commit.sh .git/hooks/pre-commit
ln -sf ../../.claude/hooks/pre-push.sh .git/hooks/pre-push
chmod +x .git/hooks/pre-commit .git/hooks/pre-push
```

### Option 2: Use with Claude Code hooks system

Add to your Claude Code settings or use with the hooks configuration in `.claude/settings.json`.

### Option 3: Manual execution

Run manually before committing:

```bash
./.claude/hooks/pre-commit.sh
```

## Requirements

- **SwiftLint**: `brew install swiftlint`
- **SwiftFormat**: `brew install swiftformat`

Both tools are optional - the hook will skip checks if they're not installed.
