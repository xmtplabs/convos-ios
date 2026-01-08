# Lint

Check code for style and quality issues using SwiftLint.

## Usage

```
/lint [path]
```

- Default: Lint entire project
- Path: Lint specific file or directory

## Commands

### Check for Issues

```bash
swiftlint
```

### Lint Specific Path

```bash
swiftlint lint --path Convos/
swiftlint lint --path ConvosCore/Sources/
```

### Auto-fix Issues

```bash
swiftlint --fix
```

### Lint Only Changed Files

```bash
git diff --name-only --diff-filter=d | grep '\.swift$' | xargs swiftlint lint --path
```

## Key Rules

From `.swiftlint.yml`, these rules are enforced:
- No force unwrapping
- Prefer `first(where:)` over filter
- Sort imports alphabetically
- Private over fileprivate
- No implicitly unwrapped optionals
- Line length: 200 characters max
- Function body length: 125 lines max

## Excluded Paths

These paths are excluded from linting:
- `.build/`
- `ConvosCore/Tests/`
- `ConvosTests/`
- `*.pb.swift` (generated protobuf files)

## On Issues Found

1. Try auto-fix first: `swiftlint --fix`
2. Review remaining issues manually
3. Check if the rule can be disabled for a specific line with `// swiftlint:disable:next rule_name`
4. Consider if the rule should be added to the disabled list in `.swiftlint.yml`
