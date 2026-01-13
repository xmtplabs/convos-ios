# Format

Format Swift code using SwiftFormat.

## Usage

```
/format [path]
```

- Default: Format changed files
- Path: Format specific file or directory

## Commands

### Format Entire Project

```bash
swiftformat .
```

### Format Specific Path

```bash
swiftformat Convos/
swiftformat ConvosCore/Sources/
```

### Format Only Changed Files

```bash
git diff --name-only --diff-filter=d | grep '\.swift$' | xargs swiftformat
```

### Preview Changes (Dry Run)

```bash
swiftformat . --dryrun
```

## Configuration

From `.swiftformat`:
- `--stripunusedargs closure-only` - Only strip unused args in closures
- `--trimwhitespace always` - Always trim trailing whitespace
- `--commas always` - Trailing commas in collections
- `--allman false` - K&R style braces (same line)

### Disabled Rules
- `redundantSelf`
- `spaceInsideComments`
- `specifiers`
- `redundantReturn`
- `numberFormatting`

## Excluded Paths

These are excluded from formatting:
- `**Generated**`
- `**Config**`
- `**Scripts**`

## Workflow

1. Make code changes
2. Run `/format` to auto-format
3. Run `/lint` to check for remaining issues
4. Commit changes
