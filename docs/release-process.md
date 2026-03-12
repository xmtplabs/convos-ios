# Release Process

This document describes the end-to-end release pipeline for the Convos iOS app.

## Overview

Releases are fully automated via GitHub Actions. A single `make release` command triggers the entire pipeline — from version bump to GitHub Release to main promotion. No local branch manipulation or direct pushes are required.

```
make release
  └── CI: create release branch, bump version, open PR
        └── Merge PR
              └── CI: create tag
                    └── CI: create GitHub Release (Claude-generated notes)
                          └── CI: fast-forward main to tagged release commit  ← production only
                                └── Bitrise: build from main → TestFlight
```

## Version Scheme

| Format | Purpose | Example |
|--------|---------|---------|
| `X.Y.Z` | Production release (App Store) | `1.2.0` |
| `X.Y.Z-dev.N` | Prerelease (TestFlight internal) | `1.2.0-dev.1` |

**Where versions live:**
- `MARKETING_VERSION` in `Convos.xcodeproj/project.pbxproj` — set automatically by CI
- Build number is managed by Bitrise (`BITRISE_BUILD_NUMBER`) — not part of this process

You never edit the version by hand. It is always set via `make release`.

## Production Release (X.Y.Z)

### Step 1 — Trigger the release workflow

```bash
make release
```

You will be prompted for the new version (e.g. `1.2.0`). The command validates you have `gh` installed and authenticated, then triggers the `Create Release` CI workflow.

### Step 2 — CI creates the release PR

The `create-release.yml` workflow:
1. Creates a `release/1.2.0` branch from `dev`
2. Bumps `MARKETING_VERSION` to `1.2.0` in the Xcode project
3. Opens a PR from `release/1.2.0` → `dev`

### Step 3 — Review and merge the PR

Review the version bump and merge. SwiftLint runs on all PRs, but exits cleanly when no `.swift` files changed.

### Step 4 — CI creates the tag

`release-tag-on-merge.yml` triggers on merge and:
1. Creates tag `1.2.0` on the merge commit
2. Deletes the `release/1.2.0` branch

### Step 5 — CI creates the GitHub Release

`auto-release.yml` triggers on the tag push and:
1. Generates customer-friendly release notes using Claude
2. Creates a GitHub Release for `1.2.0`

### Step 6 — CI fast-forwards main to the tagged release commit

`promote-to-main.yml` triggers after `auto-release.yml` succeeds and:
1. Resolves the exact commit for the release tag (for example, `1.2.0`)
2. Verifies main is an ancestor of that commit (fast-forward is safe)
3. Pushes that exact release commit to `main` directly — no merge commit

This guarantees `main` advances to the exact commit that was released, even if new commits land on `dev` after tagging.

This requires the GitHub Actions bot to be added to the main branch ruleset bypass list (see [Setup](#one-time-repo-setup) below).

### Step 7 — Bitrise builds and deploys

Bitrise detects the push to `main` and builds the production app → TestFlight → App Store.

## Prerelease / TestFlight Dev Build (X.Y.Z-dev.N)

Same process as above, but enter a prerelease version at the prompt (e.g. `1.2.0-dev.1`).

Steps 1–5 are identical. Step 6 is skipped — prereleases are never promoted to main. Bitrise builds are triggered separately if configured for prerelease tags.

## CI Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `create-release.yml` | `make release` (manual dispatch) | Creates release branch and PR |
| `release-tag-on-merge.yml` | PR merged to `dev` from `release/*` | Creates tag, deletes branch |
| `auto-release.yml` | Tag push | Creates GitHub Release with AI notes |
| `promote-to-main.yml` | `auto-release.yml` success | Fast-forwards main to tagged release commit (production only) |
| `swiftlint.yml` | PR or push to `dev`/`main` | Lints Swift code (skips lint step when no Swift changes in PR) |

All release workflows (`create-release.yml`, `release-tag-on-merge.yml`, `auto-release.yml`, `promote-to-main.yml`) share a `release-pipeline` concurrency group — only one runs at a time.

## One-Time Repo Setup

The `promote-to-main.yml` workflow pushes directly to `main` using `GITHUB_TOKEN`. For this to work with branch rulesets, GitHub Actions must be added as a bypass actor on the `main` branch ruleset:

1. Go to **Settings → Rules → Rulesets**
2. Open the ruleset protecting `main`
3. Under **Bypass list**, add **GitHub Actions**
4. Save

This allows CI to fast-forward main without a PR, while the ruleset still blocks direct pushes from individuals.

## Troubleshooting

**`promote-to-main.yml` fails with "main has diverged from release commit"**

main has commits that are not ancestors of the tagged release commit. Investigate what was pushed to main directly, then manually reconcile before retrying.

**Release PR shows SwiftLint but no lint output**

This is expected when no `.swift` files changed. The workflow reports success with a skip message so required checks still pass.

**`promote-to-main.yml` fails with "Could not resolve commit for tag"**

The tag referenced by the Auto Release run is missing or not yet visible in the clone. Re-run the workflow after confirming the tag exists remotely.

**Tag already exists**

`release-tag-on-merge.yml` checks for an existing tag and skips creation if found. The GitHub Release step in `auto-release.yml` will update an existing release. No action needed.
