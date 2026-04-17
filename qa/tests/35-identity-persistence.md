# Test: Identity Persistence Across App Reinstall

Verify that the single-inbox user identity persists across an app reinstall on the same simulator, approximating (within the bounds of a unit/UI test harness) the iCloud Keychain sync behavior that ships in C3.

> **Scope note.** True iCloud Keychain sync requires two Apple-ID-paired devices and cannot be exercised from a simulator-only QA run. This test uses app reinstall as the best available proxy: if the keychain item survives an uninstall + reinstall on the same simulator, the access class + synchronizable attributes are configured consistently with sync behavior. End-to-end iCloud Keychain verification belongs in a manual device test, not in the automated QA suite — noted below.

## Prerequisites

- The app is installed on the simulator.
- The simulator must be at a clean state (no prior Convos data) for the baseline — run `xcrun simctl erase <UDID>` then reinstall before starting.
- Fresh CLI state (`convos reset`) if the CLI will be used in post-reinstall checks.

## Phase 1: First Launch — Identity Creation

1. Launch the app. Wait for it to settle.
2. Verify the onboarding flow runs silently (no identity prompt) and an identity is created in the keychain. Indicators, any one of which is sufficient:
   - Device logs show no fatal errors during launch.
   - Once a conversation is created (see step 3), the user's profile is visible with an inbox ID present (inboxable via debug / settings panel if available).
3. Create a conversation titled "Persistence Test Alpha" via the compose flow and send one text message.
4. Take a screenshot and note:
   - The displayed profile/Quickname (if any) for the local user
   - The presence of the conversation in the list

## Phase 2: Uninstall the App

5. Terminate the app: `xcrun simctl terminate <UDID> org.convos.ios-preview`
6. Uninstall the app from the simulator: `xcrun simctl uninstall <UDID> org.convos.ios-preview`
7. **Do not erase the simulator** — that would clear the keychain and defeat the test. We want the app's data to be gone but the shared keychain to remain.

## Phase 3: Reinstall and Relaunch

8. Reinstall the previously built app bundle: `xcrun simctl install <UDID> "$APP_PATH"`
9. Launch the app: `xcrun simctl launch <UDID> org.convos.ios-preview`
10. Wait for the app to settle.

## Phase 4: Verify Identity Carryover

11. Verify the app does **not** run the first-launch onboarding flow:
    - No "create an inbox" prompt, no identity-generation screen.
    - Launch is indistinguishable (other than being empty of conversations) from a normal relaunch.

12. Verify the conversations list is empty. The GRDB database is stored in the app's container and was erased with the uninstall; the conversation "Persistence Test Alpha" should **not** be present. This is expected and correct — only the keychain identity persists, not app data.

13. Verify the same identity is used by creating a second conversation "Persistence Test Beta" and inspecting that the user's inbox ID in any debug surface matches what was present in Phase 1 (note: debug surfaces may not be exposed in production builds; in that case, indirectly verify via the CLI joining the conversation and confirming the creator inbox ID is consistent across the two runs).

14. Confirm no app-level errors are logged during the reinstall launch.

## Phase 5: Teardown

15. Terminate and uninstall the app.
16. Erase the simulator if you want to restore a clean state: `xcrun simctl erase <UDID>` (this clears the keychain too, which is fine at the end of the test).

## Pass/Fail Criteria

- [ ] First launch creates an identity silently, no onboarding prompt (**blocked until C3 silent onboarding is wired** — in C3 only the keychain storage lands, not the full silent-onboarding flow; see C11)
- [ ] Uninstall + reinstall does not trigger re-onboarding
- [ ] Identity read on relaunch matches the identity from first launch (via inbox-ID comparison through debug surface or CLI join)
- [ ] No fatal errors on either launch

## Manual Follow-Up (Not QA-Automated)

For true iCloud Keychain sync verification, a human tester with two physical iOS devices signed in to the same Apple ID should:

1. Install the single-inbox build on Device A, create an identity.
2. Install the same build on Device B and launch. Under iCloud Keychain sync, Device B should inherit the same identity (verifiable by comparing inbox IDs in a debug panel or by observing that the same conversations can be accessed from Device B after the user joins a test conversation from Device A).

This manual test is outside the scope of the automated QA agent and should be scheduled as a one-shot manual verification before release.
