# Test: Legacy-Wipe on Upgrade to Single-Inbox Build

Verify that upgrading from the current production version (main branch) to the single-inbox refactor branch executes a clean legacy wipe: prior GRDB data, prior XMTP databases, and prior per-conversation identities are removed, and the app boots into a fresh single-inbox state without crashing.

> **Expected to fail until the refactor is behaviorally complete.** The wipe itself lands in C2; full single-inbox identity creation and onboarding come online incrementally across C3 → C11. Until then, the "Phase 5" post-wipe functionality assertions will not all pass. That is expected — the Pass/Fail criteria below are annotated with the checkpoint that unblocks each one.

## Why the test shape changed

Previously `13-migration.md` verified that conversations and messages *survived* the upgrade, with a note that `eraseDatabaseOnSchemaChange = true` would wipe debug builds if the schema changed. The single-inbox refactor removes any notion of backwards-compatible data: per-conversation identities cannot be carried forward because the identity model itself has changed. The refactor plan documents this explicitly (see `docs/plans/single-inbox-identity-refactor.md`, sections "Non-Goals" and "Migration / Fresh-Start Strategy"). The test now verifies the *intentional* wipe rather than data preservation.

## Prerequisites

- The current branch has been built and is known to work.
- The convos CLI is initialized for the dev environment.
- Git worktrees are available (the project uses git worktrees).

## Setup: Create a Migration Simulator

1. Determine the current branch's simulator name (from `.convos-task` or derived from git branch).
2. Create a new simulator for this test by cloning a base iPhone simulator. Name it `<current-simulator-name>-migration`.
3. Boot the migration simulator.
4. Record the migration simulator's UDID — use it for all subsequent operations in this test.

## Phase 1: Build and Install the Main Branch Version

5. Create a temporary worktree for the main branch:
   ```
   git worktree add /tmp/convos-migration-main main
   ```
   If main is already checked out elsewhere, use `git worktree add /tmp/convos-migration-main origin/main --detach` instead.

6. Build the app from the main branch worktree, targeting the migration simulator:
   ```
   xcodebuild build \
     -project /tmp/convos-migration-main/Convos.xcodeproj \
     -scheme "Convos (Dev)" \
     -destination "platform=iOS Simulator,id=<MIGRATION_UDID>" \
     -derivedDataPath /tmp/convos-migration-main/.derivedData
   ```

7. Find the built app and install it on the migration simulator:
   ```
   APP_PATH=$(find /tmp/convos-migration-main/.derivedData/Build/Products -name 'Convos.app' -type d | head -1)
   xcrun simctl install <MIGRATION_UDID> "$APP_PATH"
   ```

8. Launch the app on the migration simulator.

## Phase 2: Populate Legacy Data on the Main Branch Version

All simulator interactions in this phase must target the migration simulator UDID.

9. Using the CLI, create three conversations with distinct names:
   - "Legacy Chat Alpha"
   - "Legacy Chat Beta"
   - "Legacy Chat Gamma"

10. For each conversation, generate an invite and open it as a deep link in the migration simulator. Process join requests from the CLI side. Wait for the app to join each conversation. This creates three separate per-conversation inboxes in the legacy build.

11. Populate each conversation with messages:
    - In "Alpha": send 3 text messages from the CLI.
    - In "Beta": send 2 text messages from the CLI.
    - In "Gamma": send 1 text message from the CLI, then send 1 message from the app.

12. Note the legacy state for later comparison:
    - Number of conversations in the list: 3
    - Main screen screenshot shows conversations populated
    - Keychain will carry three per-conversation identities (cannot be asserted from QA, but should be inferrable from app behavior)

13. Terminate the app on the migration simulator.

## Phase 3: Install the Single-Inbox Branch

14. Build the app from the current branch (the working directory), targeting the migration simulator:
    ```
    xcodebuild build \
      -project Convos.xcodeproj \
      -scheme "Convos (Dev)" \
      -destination "platform=iOS Simulator,id=<MIGRATION_UDID>" \
      -derivedDataPath .derivedData
    ```

15. Install the new build on the migration simulator (overwriting the old version):
    ```
    APP_PATH=$(find .derivedData/Build/Products -name 'Convos.app' -type d | head -1)
    xcrun simctl install <MIGRATION_UDID> "$APP_PATH"
    ```

16. Launch the app on the migration simulator.

## Phase 4: Verify the Legacy Wipe

17. Wait for the app to launch and stabilize. Take a screenshot.

18. Verify the conversations list is empty:
    - No "Legacy Chat Alpha", "Legacy Chat Beta", or "Legacy Chat Gamma" visible.
    - No residual unread counts from prior conversations.
    - The empty state for a first-launch user appears.

19. Verify no crash occurred during the upgrade launch:
    - Device logs / Console show no fatal errors on first launch.
    - `LegacyDataWipe: detected legacy data` and `LegacyDataWipe: removed ...` log lines appear (confirms the wipe path executed, not a silent no-op).

20. (Once identity creation is wired — **blocked until C3**) Verify a single fresh identity is created silently:
    - No onboarding carousel, no recovery-phrase prompt, no "create an inbox" button.
    - Settings / debug panel (if available) shows exactly one `clientId` and one `inboxId`.
    - The shared app-group keychain carries exactly one `KeychainIdentityStore.v3` entry (replacement key for C3; exact key name TBD in the C3 commit).

## Phase 5: Verify Post-Wipe Functionality

Whether or not identity creation is wired at the time of running, verify core lifecycle:

21. (**Blocked until C3/C4 onboarding lands**) Create a new conversation via the CLI with name "Post-Wipe Test".
22. (**Blocked until C10**) Generate an invite and open it as a deep link in the migration simulator.
23. (**Blocked until C10**) Process the join request from the CLI.
24. (**Blocked until C10**) Verify the app enters the conversation using the single inbox.
25. (**Blocked until C11**) Exchange messages in both directions to confirm the app is fully functional.

## Phase 6: Idempotence

26. Terminate and relaunch the app. The schema-generation marker in the app-group UserDefaults should be present; `LegacyDataWipe` should no-op this time:
    - Device logs show **no** `LegacyDataWipe: detected legacy data` message.
    - Conversations list state from the previous launch is preserved (whatever new data was added since Phase 4).

## Teardown

27. Terminate the app on the migration simulator.
28. Delete the migration simulator: `xcrun simctl delete <MIGRATION_UDID>`
29. Remove the temporary main branch worktree: `git worktree remove /tmp/convos-migration-main --force`
30. Explode any conversations created during the test via CLI.

## Pass/Fail Criteria

- [ ] Main branch app builds and installs successfully on the migration simulator
- [ ] Legacy conversations and messages populate correctly on the main branch version
- [ ] Single-inbox branch app builds and installs on top of the main branch version
- [ ] App launches without crashing after the upgrade (C2)
- [ ] Conversations list is empty on first post-upgrade launch (C2)
- [ ] `LegacyDataWipe` log lines confirm the wipe path executed (C2)
- [ ] On second launch, the wipe path does **not** run again (C2)
- [ ] Identity is created silently on first post-wipe launch — no onboarding prompts (C3)
- [ ] Exactly one identity is present in the keychain after the wipe (C3)
- [ ] A new conversation can be created via invite flow using the single inbox (C10)
- [ ] Messages can be exchanged in the new conversation (C11)
- [ ] Cleanup completes (simulator deleted, worktree removed)
