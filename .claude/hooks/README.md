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

## Installation

### Option 1: Symlink to Git hooks

```bash
# From project root
ln -sf ../../.claude/hooks/pre-commit.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
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
