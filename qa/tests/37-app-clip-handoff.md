# Test: App Clip → Full App Identity Handoff

Verify that an identity created by the App Clip persists into the full Convos app via the shared app-group keychain, and that the full app skips identity creation on first launch when the clip already seeded one.

## Background (C12)

The App Clip and the main app bind `KeychainIdentityStore` to the same access group (`$(AppIdentifierPrefix)$(APP_GROUP_IDENTIFIER)`). When the clip runs, it instantiates the singleton identity and writes it to that shared slot. On the main app's first launch `SessionManager.makeService` finds the stored identity and takes the `authorize` branch, reusing the same inbox and client ID — no fresh registration, no keychain overwrite.

## Prerequisites

- Simulator has no prior Convos install (erased or fresh).
- Dev build available for both the App Clip and the main app.

## Automated Portion (Simulator)

1. **Install only the App Clip.**
   ```
   xcrun simctl install <UDID> <path-to-ConvosAppClip.app>
   xcrun simctl launch <UDID> org.convos.ios-preview.Clip
   ```
   (Adjust bundle identifier to match the Dev scheme if different.)

2. Wait 3–5 seconds for the clip to run Firebase setup, call `ConvosClient.client(...)`, and land on `AppClipRootView`.

3. **Verify the clip wrote an identity.** Read the app-group plist or pull the log — look for a `ConvosCore` authorization-flow log line containing an `inboxId` and `clientId`. Record both values.

4. **Install the main app on top of the clip.**
   ```
   xcrun simctl install <UDID> <path-to-Convos.app>
   xcrun simctl launch <UDID> org.convos.ios-preview
   ```

5. Wait 5–10 seconds for the main app to bootstrap.

6. **Verify no onboarding prompt fires and the same identity is reused.** Check the log for:
   - An authorization flow log line with the SAME `inboxId` / `clientId` captured in step 3 — not a new pair.
   - Absence of any `Registering new inbox` / `Started registration` log line.
   - The conversations list renders without the empty-state "Pop-up private convos" carousel.

7. Send a message from the full app and confirm it posts under the same inbox id the clip created (verify via CLI `convos conversation members <id>` or log inspection).

## Manual Portion (TestFlight / Device)

App Clip discovery + install flows (App Clip Experience URL, Smart App Banner, Safari redirect) require real device distribution and can't be exercised from the simulator tooling. The steps below are for manual runs on a TestFlight build:

8. Scan an App Clip experience URL (or tap a Smart App Banner) that launches the clip.
9. Confirm the clip shows `AppClipRootView` and Firebase debug logs indicate identity creation.
10. Through App Store, install the full app.
11. Launch the full app. Confirm it lands on the conversations list (no onboarding) and shows the conversation the clip joined, if any.

## Pass/Fail Criteria

- [ ] App Clip launches without crashing on first run on a fresh simulator.
- [ ] App Clip persists a single `KeychainIdentityStore.v3` entry (inboxId + clientId).
- [ ] Full app launched on top sees the same inboxId + clientId (no new registration).
- [ ] Full app does not show the empty-state "Start a convo" carousel (if the clip had already joined a conversation) and does not prompt for onboarding before first interaction.
- [ ] No `Failed to register device` / `Registering new inbox` log lines appear on the main-app launch following a clip run.
- [ ] Identity survives reopening the full app.

## Notes

- The `AppClipIdentityHandoffTests` unit suite in `ConvosCoreTests` pins the logical contract; this QA test exercises it on a real simulator / device.
- If the inbox IDs differ between the clip and the full app launch, the keychain access group is misconfigured — confirm that both `Convos.entitlements` and `ConvosAppClip.entitlements` declare the same `keychain-access-groups` array.
