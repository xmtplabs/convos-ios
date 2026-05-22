# Test: Pair a Second Device

Verify that an existing user (Device A) can pair a fresh-install second device (Device B) so both devices share the same SIWE address, the same `inboxId`, and the same backend `accountId` — without writing any identity to iCloud Keychain.

This is the production-TestFlight-beta gate for multi-device support and for in-app purchase restoration across devices.

## Prerequisites

- Two iOS simulators running the same Convos build.
- Device A is fully onboarded and has at least one conversation in its list.
- Device B has the app installed but the keychain is empty (run `xcrun simctl uninstall <DeviceB> org.convos.ios` then reinstall). iCloud Keychain may be on or off — pairing must work in both cases.
- Both devices are network-reachable to the same XMTP environment.

## Steps

### Initiator: open the pairing sheet

1. On Device A, open **App Settings → Devices**.
2. Verify the screen shows only "This device" with the device name, plus an "Add new device" button.
3. Tap `add-new-device-button` (empty state) or `add-device-button` (list state).
4. Verify the sheet appears with title "Pair new device" and a **blurred QR code** in the center, copy "Scan this code with your new device to pair".
5. Tap and hold the `hold-to-reveal-button` — the QR sharpens and a light haptic fires while held. Release — the QR re-blurs.
6. Verify `pairing-countdown` shows "Expires in 120s" counting down by 1s.

### Joiner: open the deep link

7. Tap the "Share" pill on Device A and AirDrop / Messages the URL to Device B (or copy/paste).
8. On Device B, tap the `https://<env-domain>/pair/<slug>?expires=...&name=...` link.
9. Verify Device B opens Convos and presents a sheet titled "Request to pair" with copy `"<Device A name>" is requesting to pair. Paired devices sync all conversations.` plus a progress spinner and an expiry countdown.

### PIN exchange

10. Within 60 seconds, Device A's sheet transitions to a 6-digit PIN display (`pairing-pin-display`) with copy `Share this code with "<Device B name>" to continue pairing.`
11. Device B's sheet transitions to a `pin-entry-field` with copy `Enter the code shown on "<Device A name>" to finish pairing.`
12. On Device B, type the 6 digits shown on Device A. Submit (`submit-pin-button`).

### Emoji fingerprint

13. Both sheets transition to a 3-emoji display (`pairing-emoji-fingerprint`). Title changes to **"Confirm pairing"** on both.
14. **Verify the 3 emojis are identical on both devices.** This is the MITM-resistance check — if the emojis don't match, the user is being attacked and must cancel.
15. On Device A, tap `confirm-emoji-button`.
16. Device B does **not** have a confirm button — it shows "Waiting for confirmation..." beneath the emojis.

### Identity transfer

17. Both sheets transition to a `syncing` state: rotating sync icon + copy "Pairing device..." (Device A) / "Adopting your identity..." (Device B). The sheet is non-dismissible.
18. Within ~5 seconds both sheets reach `completed`:
    - Device A title becomes **"Device added"**, shows `iphone.badge.checkmark` + the device-B name.
    - Device B title becomes **"Device paired"**, shows the same icon + "Successfully paired".
19. Tap `got-it-button` on either device to dismiss.

### Backend account verification (the production beta gate)

20. On Device B, open the debug menu and **Run Auth Probe** (Debug → Auth Probe).
21. Verify the probe shows:
    - `Loading identity… address=0x…` — matches Device A's wallet address from its own probe.
    - `accountId=<uuid>` on the decoded JWT — must equal the `accountId` shown by Device A's probe.
    - `GET /api/v2/account-auth-check → 200`.
22. Repeat on Device A. Confirm both devices resolve to the **same** `accountId`.

This proves that an IAP purchase made on Device A would be restorable on Device B via the standard backend entitlement check, because both devices authenticate as the same account.

### Negative cases (briefly)

- Wrong PIN: on Device B enter `000000` instead of the displayed PIN, submit. Device A transitions to a `failed` state with copy "The confirmation code does not match." Device B receives the error DM and shows the same failure.
- Expired invite: leave Device A's QR screen open without Device B scanning for 120 seconds. Device A transitions to `expired` with copy "Pairing expired. Please try again."
- Joiner inbox already exists: on a Device B that already has an identity (`identity-row` populated in Debug), the joiner sheet must refuse with copy "This device already has a Convos identity. Delete data first to pair with a different account." (TODO(pairing-session-3): currently the joiner silently bootstraps an ephemeral inbox on top — needs the guard before merging.)

### iCloud Keychain non-leakage check (the safety gate)

23. On either device, open Settings.app → Apple ID → iCloud → Passwords & Keychain. Confirm Convos is **not** listed among synced services. The pairing flow must not have written any items with `kSecAttrSynchronizable = true`.

## QA event hooks

The pairing flow emits `[EVENT] pairing.pairing_url_created url=https://...` when the initiator's sheet finishes building the URL. Use `sim_log_events` with `event_filter: "pairing.pairing_url_created"` to extract the URL during automated tests instead of OCR-ing the QR.
