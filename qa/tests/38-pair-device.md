# Test: Pair a Second Device

Verify that an existing user (Device A) can pair a fresh-install second device (Device B) so both devices share the same SIWE address, the same `inboxId`, and the same backend `accountId` — without writing any identity to iCloud Keychain. Also verify that revoking a paired device immediately surfaces a "This device has been removed" banner on the revoked device.

This is the production-TestFlight-beta gate for multi-device support and for in-app purchase restoration across devices.

## Prerequisites

- Two iOS simulators running the same Convos build.
- Device A is fully onboarded (display name set, profile photo optional) and has at least one conversation in its list.
- Device B has Convos installed but should be either fresh-install or in a state where the user has not yet engaged with any conversations (the `hasAnyUsedConversations` gate determines whether the destructive "Hold to erase and pair" path is shown).
- Both devices are network-reachable to the same XMTP environment.

## Steps

### Initiator: open the pairing sheet

1. On Device A, open **App Settings → Devices**.
2. Verify the screen shows the current device labelled `iPhone <X>` with `This device` subtitle, plus an `Add new device` row.
3. Tap `add-device-button`.
4. Verify the sheet appears with title `Pair new device` and a **blurred QR code** in the center, plus copy `Scan this code with your new device to pair`.
5. Tap and hold the `hold-to-reveal-button` — the QR sharpens, opacity goes to 1.0, scale to 1.0, and a light sensory feedback fires while held. Release — the QR re-blurs to radius 20.
6. Verify `pairing-countdown` shows `Expires in 120s` counting down by 1s.

### Joiner: open the deep link

7. Tap the `share-pairing-link` pill on Device A and AirDrop / Messages the URL to Device B (or `xcrun simctl openurl <DeviceB> "convos-dev://pair/<slug>?expires=…&name=…"`).
8. Verify Device B opens Convos and presents a sheet titled `Request to pair` with copy `"<Device A name>" is requesting to pair. Paired devices sync all conversations.` plus a progress spinner and a countdown.

### Destructive guard (only fires for users with real conversations)

If Device B's session reports any conversation with `isUnused == false` (via `SessionManagerProtocol.hasAnyUsedConversations`), the joiner sheet routes through this confirmation **before** sending the join request. Skip this section on a fresh install — it will not fire.

- Sheet renders the red exclamation icon, `This device already has a Convos account.`, the explanation `Pairing with "<Device A name>" will replace this device's account. Existing conversations and data on this device will be deleted.`, a `hold-to-erase-and-pair-button` (3.0s hold, red `.colorCaution` background, label `Hold to erase and pair`), and a `Cancel` text button.
- Hold the button. Label flips to `Erasing...`, sheet becomes non-dismissible, and the device's local data is wiped via `session.deleteAllInboxes()`.
- After deletion completes the sheet re-enters `.connecting` and the join request flow continues as normal.

### PIN exchange

9. Within ~10s, Device A's sheet transitions to a 6-digit PIN display (`pairing-pin-display`) with copy `Share this code with "<Device B name>" to continue pairing.`
10. Device B's sheet transitions to a `pin-entry-field` with copy `Enter the code shown on "<Device A name>" to finish pairing.`
11. On Device B, type the 6 digits shown on Device A. Submit (`submit-pin-button`).

### Emoji fingerprint

12. Both sheets transition to a 3-emoji display (`pairing-emoji-fingerprint`). Title changes to `Confirm pairing` on both.
13. **Verify the 3 emojis are identical on both devices.** This is the MITM-resistance check — if the emojis don't match, the user is being attacked and must cancel.
14. On Device A, tap `confirm-emoji-button`.
15. Device B does **not** have a confirm button — it shows `Waiting for confirmation...` beneath the emojis.

### Identity transfer

16. Both sheets transition to a `syncing` state: rotating sync icon. Device A subhead: `Pairing device...`. Device B subhead: `Adopting your identity...`. Sheets are non-dismissible (`canDismiss = false`).
17. Within a couple seconds both sheets reach `completed`:
    - Device A title becomes `Device added`, shows `iphone.badge.checkmark` + the device-B name.
    - Device B title becomes `Device paired`, shows the same icon + `Successfully paired`.
18. Tap `got-it-button` on either device to dismiss.

### Post-pair UI checks

19. On Device A's `Devices` screen, immediately after dismissing the sheet, Device B's row should appear with the joiner's `UIDevice.current.name` (e.g. `Jarod's iPhone 13 mini`). This is the optimistic insert — it shows before the network surfaces the real installation. The row is reconciled with the real installation id within ~5–20s; the displayed name persists across the swap because `PairedDeviceNameStore` cached it.
20. On Device B, the conversation list reflects Device A's history once XMTP sync completes. The bottom-of-conversation `Add your name and pic` red CTA should **not** appear — `ConversationOnboardingCoordinator.markCompletedForPairedDevice()` flips the global onboarding `UserDefaults` flags as part of pair adoption, and `ProfileSettingsViewModel.shared` is rebound to the freshly-bootstrapped `MessagingService` so `profileSettings.isDefault` is `false`.
21. On Device B, navigate into one of Device A's existing conversations. Verify Device A's prior outgoing messages render on the **right side** of the message list (own bubbles), proving the local DB's "current user" pivoted to the paired inboxId via the `wipeResidualInboxRows()` call in `SessionManager.refreshAfterPairingCompleted`.

### Backend account verification (the production beta gate)

22. On Device B, open the debug menu and **Run Auth Probe** (Debug → Auth Probe).
23. Verify the probe shows:
    - `Loading identity… address=0x…` — matches Device A's wallet address from its own probe.
    - `accountId=<uuid>` on the decoded JWT — must equal the `accountId` shown by Device A's probe.
    - `GET /api/v2/account-auth-check → 200`.
24. Repeat on Device A. Confirm both devices resolve to the **same** `accountId`. This proves an IAP purchase made on Device A would be restorable on Device B via the standard backend entitlement check, because both devices authenticate as the same account.

### Revoke flow (the read-only safety net)

25. On Device A's `Devices` screen, swipe Device B's row left and tap `Delete`. The `RemoveDeviceSheetView` appears with a `Hold to delete` button (3.0s hold, red `.colorCaution` background).
26. Hold the button. The label flips to `Removing...`, the sheet stays open until the underlying `revokeInstallation(installationId:)` call returns.
27. Internally: `MessagingService.revokeInstallation` first sends a `DeviceRemovedContent` DM (carrying `revokedInstallationId`) into the most recently created conversation under the shared inbox. Both installations under the inbox are members, so Device B receives the message via its existing message stream. Then `libxmtp.revokeInstallations` is called.
28. On Device B, **within a couple seconds** (no foreground cycle, no app restart), `StreamProcessor.processMessage` fires the early-return for `ContentTypeDeviceRemoved`, posts `.installationWasRevokedByPeer`, `SessionStateMachine.startRevocationObserver` transitions to `.error(DeviceReplacedError)`, and `StaleDeviceObserver` flips `isDeviceRemoved = true`.
29. Verify Device B's `ConversationsView` now shows the `stale-device-banner` at the top:
    - Title: `This device has been removed` (icon: red `exclamationmark.triangle.fill`).
    - Body: `Another device removed this one from your account. Resetting will clear local data here so you can start fresh or pair again.`
    - `hold-to-reset-device-button` (label: `Hold to reset`, 3.0s hold, red `.colorCaution` background).
30. Hold the reset button. Label flips to `Resetting...`. `ConversationsViewModel.resetForStaleDevice` immediately calls `staleDeviceObserver.dismiss()` (banner disappears optimistically), runs `appSettingsViewModel.deleteAllData`, and on completion rebinds the observer to the freshly-built `sessionStateManager`. Device B is now in a fresh-install state.

### Negative cases

- **Wrong PIN.** On Device B enter `000000` instead of the displayed PIN, submit. Device A transitions to `.failed` with copy `The confirmation code does not match`. Device A also sends a `PairingMessageContent.error` DM so Device B drops into the same failed state.
- **Expired invite.** Leave Device A's QR screen open without Device B scanning for 120 seconds. Device A transitions to `.expired` with the `clock.badge.xmark` icon and copy `Pairing expired. Please try again.`
- **Cancel mid-flow.** Tap `cancel-pairing` on either side during `showingPin` or `waitingForEmoji`. The opposite side receives a `PairingMessageContent.error` DM and surfaces `Pairing was cancelled by the other device`.

### iCloud Keychain non-leakage check (the safety gate)

31. On either device, open `Settings.app → Apple ID → iCloud → Passwords & Keychain`. Confirm Convos is **not** listed among synced services. The pairing flow must not have written any items with `kSecAttrSynchronizable = true`; the device-local identity slot at `KeychainIdentityStore.defaultService` (`org.convos.ios.KeychainIdentityStore.v3`) is keyed with `kSecAttrSynchronizable = false`.

## QA event hooks

The pairing flow emits `[EVENT] pairing.pairing_url_created url=https://...` when the initiator's sheet finishes building the URL. Use `sim_log_events` with `event_filter: "pairing.pairing_url_created"` to extract the URL during automated tests instead of OCR-ing the QR.
