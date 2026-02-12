# Test: Database Migration from Main

Verify that upgrading from the current production version (main branch) to the current branch preserves user data and that the app functions correctly after the upgrade.

## Important: Debug Erase Behavior

The app's database migrator has `eraseDatabaseOnSchemaChange = true` in DEBUG builds. This means if the database schema changed between main and the current branch, the database will be automatically wiped on first launch of the new version. This is expected behavior in dev builds.

The migration test should detect and report this:
- If data survives the upgrade, the schema did not change — report migration as successful.
- If data is wiped after the upgrade, the schema changed and the debug erase triggered — report this clearly. This is not a test failure, but the test should verify the app still launches and functions correctly after the wipe.

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

## Phase 2: Populate Data on the Main Branch Version

All simulator interactions in this phase must target the migration simulator UDID.

9. Using the CLI, create three conversations with distinct names:
   - "Migration Chat Alpha" with profile name "Alpha User"
   - "Migration Chat Beta" with profile name "Beta User"
   - "Migration Chat Gamma" with profile name "Gamma User"

10. For each conversation, generate an invite and open it as a deep link in the migration simulator. Process join requests from the CLI side. Wait for the app to join each conversation.

11. Populate each conversation with messages:
    - In "Alpha": send 3 text messages from the CLI.
    - In "Beta": send 2 text messages and 1 emoji message from the CLI.
    - In "Gamma": send 1 text message from the CLI, then send 1 message from the app.

12. Take a screenshot and note the state of the conversations list. Record conversation names and message counts for later comparison.

13. Terminate the app on the migration simulator.

## Phase 3: Install the Current Branch Version

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

## Phase 4: Verify Migration

17. Wait for the app to launch and stabilize. Take a screenshot.

18. Check if the conversations list shows the previously created conversations:
    - If conversations are present: the database migrated successfully. Proceed to verify each conversation.
    - If the conversations list is empty: the schema changed and `eraseDatabaseOnSchemaChange` wiped the database. Note this in the results and skip to Phase 5.

19. If conversations survived, verify:
    - All three conversations appear in the list with their correct names.
    - Open "Migration Chat Alpha" and verify messages are present.
    - Navigate back and open "Migration Chat Beta" and verify messages are present.
    - Navigate back and verify the conversations list is intact.

20. If conversations survived, verify that new messages still work:
    - Open any conversation.
    - Send a message from the CLI.
    - Verify it appears in the app.
    - Send a message from the app.
    - Verify it appears via CLI.

## Phase 5: Verify Post-Upgrade Functionality

Whether or not the database was preserved, verify that core functionality works on the new version:

21. Create a new conversation via the CLI with name "Post-Migration Test".
22. Generate an invite and open it as a deep link in the migration simulator.
23. Process the join request from the CLI.
24. Verify the app enters the conversation.
25. Exchange messages in both directions to confirm the app is fully functional.

## Teardown

26. Terminate the app on the migration simulator.
27. Delete the migration simulator: `xcrun simctl delete <MIGRATION_UDID>`
28. Remove the temporary main branch worktree: `git worktree remove /tmp/convos-migration-main --force`
29. Explode any conversations created during the test via CLI.

## Pass/Fail Criteria

- [ ] Main branch app builds and installs successfully on the migration simulator
- [ ] Conversations can be created and populated on the main branch version
- [ ] Current branch app builds and installs on top of the main branch version
- [ ] App launches without crashing after the upgrade
- [ ] Data migration outcome is reported (preserved or wiped due to schema change)
- [ ] If data preserved: conversations and messages are intact after upgrade
- [ ] If data preserved: new messages can be sent and received in migrated conversations
- [ ] Post-upgrade: a new conversation can be joined and used
- [ ] Post-upgrade: messages can be exchanged in the new conversation
- [ ] Cleanup completes (simulator deleted, worktree removed)
