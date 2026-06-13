# Lint

Check Swift code for style and quality issues with SwiftLint.

A full-tree lint runs in ~1-2 seconds. The pre-commit and pre-push hooks
catch the same set of violations CI does — `/lint` is mainly for an
on-demand sweep or for targeting a specific path.

## Usage

```
/lint                  # full tree
/lint <path>           # one file or directory
/lint --fix [<path>]   # auto-fix what SwiftLint can fix
```

## Commands

```bash
swiftlint                                 # full tree, warnings only
swiftlint lint --strict                   # warnings become errors (CI behavior)
swiftlint lint Convos/                    # one directory
swiftlint lint --fix                      # auto-fix what's auto-fixable
```

Note: `swiftlint --fix` only handles a subset of rules. The ones that
recurrently trip CI for us (`sorted_imports`, `vertical_whitespace_*`,
`type_body_length`, `cyclomatic_complexity`) need manual fixes.

## How it's gated

| Stage | Scope | Tool |
|---|---|---|
| `pre-commit` hook | Staged Swift files | `swiftlint lint --strict --quiet <paths>` |
| `pre-push` hook | Files changed since merge-base with `origin/dev` | same |
| CI workflow | Whole tree | `swiftlint lint --strict --cache-path .swiftlint-cache` |

All three pass paths positionally (or no args for CI). `--use-stdin` is
intentionally avoided because it skips rules that need a file path
(`sorted_imports` is the recurring offender).

## Key rules in `.swiftlint.yml`

- No force unwrapping / implicitly-unwrapped optionals
- Sorted imports (alphabetical, per import group)
- Private over fileprivate
- `first(where:)` / `last(where:)` / `contains(where:)` over filter-then-index
- Line length 200, function body 125, type body 635
- Cyclomatic complexity warning 14 / error 15

Full list in `.swiftlint.yml`. Custom rules: `no_assertions` (no
`assert(...)` in non-test code), `enum_constants` (name it `Constant`,
not `Constants`), `constant_enum_at_bottom`.

## Common fix patterns

- **Sorted Imports** — alphabetize within each `import` group (top-of-file imports, `@testable import` block, etc.). The blocks are sorted independently.
- **Vertical Whitespace Before Closing Braces** — drop the empty line right before a `}`.
- **Type Body Length** — extract a helper out of the type body, e.g. a fileprivate free function or a method on a sibling type.
- **Cyclomatic Complexity** — extract one of the `if`/`switch` branches into its own private method.
- **Orphaned Doc Comment** — usually a stray `// swiftlint:disable:next ...` line wedged between the doc comment and the declaration. Remove the disable comment if it's no longer needed.

If a rule genuinely needs a per-line waiver:

```swift
// swiftlint:disable:next force_unwrapping
let value = optional!
```

If it's not the right rule for the file, add it to `disabled_rules:` in `.swiftlint.yml` and discuss in the PR.
