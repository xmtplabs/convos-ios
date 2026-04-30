# Ad Hoc Builds

> **Status**: Proposed
> **Author**: Louis
> **Created**: 2026-04-22

## Motivation

Weekly release trains mean features often need to stay out of `dev` longer to keep `dev → main` promotion clean. Per-PR Ad Hoc builds let the whole team exercise unmerged work on-device without forcing an early merge into `dev` just to get a TestFlight build.

## TL;DR

Label a PR `adhoc` → Bitrise builds an Ad Hoc archive → Firebase App Distribution → testers install via the Firebase App Tester iOS app. TestFlight is unchanged for dev and prod releases.

## Decision

| Channel          | Tool                         | Trigger                              | Audience           |
|------------------|------------------------------|--------------------------------------|--------------------|
| PR Ad Hoc        | Firebase App Distribution    | PR label `adhoc` (or manual)         | Whole team         |
| Dev TestFlight   | App Store Connect (existing) | Release tag via `make tag-release`   | Broader internal   |
| Prod TestFlight  | App Store Connect (existing) | Push to `main`                       | External beta      |

- Opt-in only — no auto-build on every push.
- TestFlight stays as-is for dev and prod releases.

## Build ↔ PR linkage

- Firebase display version: `PR-<num>-<shortSHA>`.
- Firebase release notes populated with: PR title, PR URL, branch, author, Bitrise run URL, full commit SHA.
- Driven by Bitrise env vars already set by the GitHub integration: `BITRISE_PULL_REQUEST`, `BITRISE_GIT_COMMIT`, `BITRISE_GIT_BRANCH`.

## Tester onboarding and devices

1. Admin invites tester via Firebase App Distribution email.
2. Tester installs the Firebase App Tester iOS app, signs in, UDID is captured by Firebase.
3. Admin copies the UDID from the Firebase console into the Apple Developer portal — manual in v1, automatable later via the `register-test-devices` Bitrise step if volume warrants it.
4. Next Ad Hoc build regenerates the provisioning profile via `manage-ios-code-signing@2` with the new UDID included.
5. Tester pulls the build from the Firebase App Tester app.

## Provisioning profile lifecycle

- Profile regenerated on every Ad Hoc build through `manage-ios-code-signing@2`, same mechanism as today's App Store flow. The only change is `distribution_method: ad-hoc`.
- No manual profile management. New UDIDs registered in the Apple Developer portal are picked up on the next build.

## New Bitrise workflow (sketch)

- Name: `archive_and_export_adhoc`.
- Based on `archive_and_export_dev`: same `Convos (Dev)` / `NotificationService (Dev)` schemes, same Setup and ReleaseNotes bundles.
- Swaps: `distribution_method: ad-hoc` in both `manage-ios-code-signing@2` and `xcode-archive@5`; replace `deploy-to-itunesconnect-application-loader@2` with a `firebase-app-distribution` step.
- Trigger: `pull_request` filtered by the `adhoc` label (preferred), or manual Start Build. The existing but disabled `build_for_testing` workflow is a precedent for PR triggers in this repo.

## Open questions

- [ ] Build from PR HEAD, or from PR merged into `dev`? Default: PR HEAD — matches what the reviewer sees.
- [ ] Firebase project: reuse the one already wired for iOS (confirm via `ConfigManager` environments) or spin up a new one dedicated to App Distribution?
- [ ] NSE and App Clip: NSE must be included (push depends on it); App Clip stays off while `ENABLE_APPCLIP=false`.
- [ ] UDID registration: keep manual in v1, or adopt `register-test-devices` from day one?
- [ ] Bundle ID: reuse `org.convos.ios-preview` so testers can keep Dev TF and PR Ad Hoc installed side-by-side, or allocate a separate bundle ID (extra ASC + Firebase app)? Default: reuse.

## Rollout

1. Merge this doc.
2. Confirm or create the Firebase App Distribution project.
3. Copy the dev workflow into `archive_and_export_adhoc` and apply the two swaps above.
4. Dry-run on an open PR to validate signing, upload, and tester install.
5. Write the tester onboarding steps in Notion or the README for the non-eng team.

## Non-goals

- Not writing the Bitrise workflow in this PR.
- Not setting up the Firebase project in this PR.
- Not touching `archive_and_export_dev` or `archive_and_export_prod`.
- Not an ADR — this is a decision memo; graduate to `docs/adr/012-adhoc-builds.md` if the approach holds up.
