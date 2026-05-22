# Disable DeviceConnections in the UI for v1 (cloud / Google Calendar only)

## Context

Build 856 upload triggered ITMS-90683: the binary references `CLLocationManager.requestAlwaysAuthorization()` (via `LocationDataSource`) but `Info.plist` only had `NSLocationWhenInUseUsageDescription` - not the matching `NSLocationAlwaysAndWhenInUseUsageDescription` key Apple wants for `requestAlwaysAuthorization()`. All other device-framework purpose strings (Health / Calendar / Contacts / Photos / Music / HomeKit / Motion) were present and never triggered a warning.

For v1 we also want only Google Calendar surfaced in the Connections UX. The Composio cloud connection covers that without touching device code.

## Approach

Two-line behavior fix, plus the missing plist key:

1. **Add `NSLocationAlwaysAndWhenInUseUsageDescription`** to all three `Info.plist` files. Silences ITMS-90683.
2. **Set `SupportedConnections.supportedDeviceKinds = []`** so the existing view-model filters render only the Google Calendar cloud row in App Settings -> Connections and Conversation Info -> Connections. Re-enabling a device kind later is one allowlist entry.

We deliberately do **not** wrap device DataSource code in `#if` flags. The earlier wide-gating spike confirmed it requires ~56 files of churn across `ConvosConnections`, `ConvosCore`, and the main app (plus convenience-init dances to keep SwiftLint's type-body limit happy). The binary still carries the device framework symbols, but they are unreachable at runtime (UI hides them) and Apple's static analysis only flags missing purpose strings, not symbol presence.

We also keep the existing `NSHealth*`, `NSCalendars*`, `NSContacts*`, `NSPhotoLibrary*`, `NSAppleMusic*`, `NSHomeKit*`, `NSMotion*` purpose strings. Dropping them would trigger fresh ITMS-90683 warnings for the corresponding framework APIs that are still compiled into the binary. They cost nothing to keep.

## Critical files

- `Convos/Config/Info.Dev.plist`, `Info.Prod.plist`, `Info.Local.plist` - add the missing key.
- `ConvosCore/Sources/ConvosCore/CapabilityResolution/SupportedConnections.swift` - empty `supportedDeviceKinds`.

## Verification

1. **Build clean.** `xcodebuild build -scheme "Convos (Dev)" -only-testing:Convos` (the full scheme build hits a pre-existing NotificationService module-resolution error on `dev` baseline unrelated to this change).
2. **UI smoke.** Run the app. App Settings -> Connections and Conversation Info -> Connections each show only the Google Calendar cloud row.
3. **TestFlight upload.** Push a build and confirm App Store Connect does not email ITMS-90683.

## To bring device connections back

Set `supportedDeviceKinds` back to `[.health]` (or whichever kinds). No other code changes needed.
