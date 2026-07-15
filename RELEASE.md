# Release Process

Releases are cut, uploaded, and promoted by the convos-releases release
train — see `RUNBOOK.md` in
[xmtplabs/convos-releases](https://github.com/xmtplabs/convos-releases).

In short:

- The train cuts a `release/X.Y.Z` branch (with the version bump) and
  opens a release PR against `main`.
- Every push to a `release/**` or `hotfix/**` branch uploads a TestFlight
  RC (`.github/workflows/release-rc.yml`).
- Release PRs are merged with the `@convos-conductor merge` PR comment
  (`.github/workflows/conductor-merge.yml`).
- Merging the release PR tags `vX.Y.Z`, creates the GitHub Release from
  the train's release manifest, and stages the already-uploaded RC's App
  Store Connect metadata (`.github/workflows/appstore-promote.yml`).

The legacy tag-and-GitHub-Release pipeline formerly described here
(`create-release.yml`, `release-tag-on-merge.yml`, `auto-release.yml`,
`promote-to-main.yml`) has been retired — its un-prefixed `X.Y.Z` tags,
`<!-- release-tag -->` PR markers, and AI-generated release notes are
replaced by the train's `v*` tags and manifest-seeded notes.
