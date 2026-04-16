# Feature: Testnet Environment

> **Status**: Approved
> **Author**: Nicholas Molnar
> **Created**: 2026-04-15
> **Updated**: 2026-04-15

## Overview

Add a fourth named build environment, "Testnet," that connects to the XMTP testnet network via a gateway (`payer.testnet.xmtp.network`) and a separate Convos API backend. This environment is a separate dev environment. It has its own backend, bundle ID, and Apple identity, making it suitable for evaluating testnet infrastructure.

## Problem Statement

There is no way to connect to the `testnet` backend network in Convos today. This makes it impossible to evaluate the d14n capabilies of the XMTP SDKs.

## Goals

- [ ] "Convos (Testnet)" scheme builds and runs in the simulator
- [ ] App routes to the testnet Convos backend API (URL sourced from `.env` / `Secrets.swift`)
- [ ] App connects to the XMTP dev network via gateway `payer.testnet.xmtp.network`
- [ ] Notification Service extension builds and works for Testnet
- [ ] All existing Local, Dev, and Production environments continue to work without any behavior change
- [ ] Documentation updated to reflect the new environment everywhere it is currently mentioned

## Non-Goals

- Creating a new Firebase project for Testnet (reuse Dev Firebase project initially)
- Creating a dedicated App Clip scheme for Testnet (defer until there is a concrete need)
- Changing how Secrets are generated for any existing environment
- Adding a Testnet target to CI/CD pipelines (handled separately once the environment is stable)
- Any UI or feature changes; this is purely infrastructure

## User Stories

### As a developer, I want to build "Convos (Testnet)" so that I can test against testnet infrastructure without touching Dev

Acceptance criteria:
- [ ] Selecting the "Convos (Testnet)" scheme in Xcode produces a runnable app
- [ ] App display name is "Convos Testnet"
- [ ] Bundle ID is `org.convos.ios-testnet`
- [ ] App icon visually distinguishes the build from Dev and Production

### As a developer, I want the testnet app to connect to the correct backend

Acceptance criteria:
- [ ] `CONVOS_API_BASE_URL` in `.env` is used as the API base URL when present
- [ ] If `.env` has no value, the build fails with a clear error (no silent fallback to a wrong URL)
- [ ] App logs confirm the correct API URL at launch

### As a developer, I want push notifications to work for Testnet builds

Acceptance criteria:
- [ ] "NotificationService (Testnet)" scheme builds successfully
- [ ] Notification extension reads the correct environment config from Keychain at runtime

## Technical Design

### Architecture

The Testnet environment follows the identical layering used by Local, Dev, and Production:

- `config.testnet.json` (config file, main app bundle) — declares environment identity and static values
- `Testnet.xcconfig` (build settings) — bundle ID, display name, icon, URL scheme, associated domains
- `Convos (Testnet).xcscheme` and `NotificationService (Testnet).xcscheme` — Xcode build entry points
- `AppEnvironment.testnet` case (ConvosCore) — runtime environment enum
- `ConfigManager` `"testnet"` switch arm (main app) — wires Secrets + config into `AppEnvironment`
- Build phase scripts — Secrets.swift generation for the Testnet configuration
- `GoogleService-Info.Testnet.plist` — Firebase configuration (copy of Dev initially)
- `Info.Testnet.plist` — Info.plist variant

### Component Breakdown

#### config.testnet.json

New file at `Convos/Config/config.testnet.json`. Mirrors `config.dev.json` with these differences:

| Key | Value |
|-----|-------|
| `environment` | `"testnet"` |
| `backendUrl` | empty string or omitted (Secrets is required) |
| `xmtpNetwork` | `"dev"` |
| `bundleId` | `"org.convos.ios-testnet"` |
| `appGroupIdentifier` | `"group.org.convos.ios-testnet"` |
| `relyingPartyIdentifier` | [NEEDS DECISION] `"testnet.convos.org"` or same as Dev |
| `associatedDomains` | [NEEDS DECISION] — see Open Questions |
| `appUrlScheme` | `"convos-testnet"` |
| `gatewayUrl` | `"payer.testnet.xmtp.network"` |

Placing `gatewayUrl` in the config JSON is the cleanest approach: it follows the existing pattern, is visible in version control, and avoids hardcoding a fallback inside `ConfigManager`.

#### Testnet.xcconfig

New file at `Convos/Config/Testnet.xcconfig`. Based on `Dev.xcconfig`:

```
CONFIG_FILE = config.testnet.json
DEVELOPMENT_TEAM = FY4NZR34Z3
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
OTHER_SWIFT_FLAGS = $(inherited) -Onone

MAIN_BUNDLE_ID = org.convos.ios-testnet
PRODUCT_BUNDLE_IDENTIFIER = $(MAIN_BUNDLE_ID)
CONVOS_BUNDLE_ID = $(MAIN_BUNDLE_ID)
CONVOS_TESTS_BUNDLE_ID = $(MAIN_BUNDLE_ID).tests
CONVOS_APP_CLIP_BUNDLE_ID = $(MAIN_BUNDLE_ID).Clip
NOTIFICATION_SERVICE_BUNDLE_ID = $(MAIN_BUNDLE_ID).ConvosNSE

APP_GROUP_IDENTIFIER = group.$(MAIN_BUNDLE_ID)
ASSOCIATED_DOMAIN = [NEEDS DECISION]
WEB_CREDENTIALS_DOMAIN = [NEEDS DECISION]
SECONDARY_ASSOCIATED_DOMAIN = [NEEDS DECISION]
URL_SCHEME = convos-testnet
KEYCHAIN_GROUP_IDENTIFIER = $(MAIN_BUNDLE_ID)
APP_DISPLAY_NAME = Convos Testnet
APNS_ENVIRONMENT = production

ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon-Dev  (reuse Dev initially; swap to AppIcon-Testnet once asset is created)

SWIFT_OPTIMIZATION_LEVEL = -Onone
ENABLE_TESTABILITY = YES
DEBUG_INFORMATION_FORMAT = dwarf
```

#### Xcode Project Build Configurations

The `.xcodeproj/project.pbxproj` must gain a "Testnet" build configuration for every target that currently has Local / Dev / Prod configurations. This is the most structurally complex part of the change because it must be done through Xcode's UI (or careful manual pbxproj editing) to avoid corrupting the project file.

Targets that need a "Testnet" configuration:
- Convos (main app)
- ConvosTests
- NotificationService
- ConvosAppClip (even without a Testnet scheme, the target config must exist to avoid build system errors)
- Any other targets present in the project

Each new configuration should be based on the "Dev" configuration in Xcode's "Duplicate" flow, then have its xcconfig file set to `Testnet.xcconfig`.

#### AppEnvironment (ConvosCore)

File: `ConvosCore/Sources/ConvosCore/AppEnvironment.swift`

Add `case testnet(config: ConvosConfiguration)` to the `AppEnvironment` enum and update every switch statement:

- `name` → return `"testnet"`
- `firebaseConfigURL` → return `"GoogleService-Info.Testnet"` resource
- `apiBaseURL` → delegate to `config.apiBaseURL` (same pattern as dev)
- `appGroupIdentifier` → delegate to `config.appGroupIdentifier`
- `relyingPartyIdentifier` → delegate to `config.relyingPartyIdentifier`
- `xmtpEndpoint` → delegate to `config.xmtpEndpoint`
- `xmtpNetwork` → delegate to `config.xmtpNetwork`
- `gatewayUrl` → delegate to `config.gatewayUrl`
- `isProduction` → `false`
- `isTestingEnvironment` → `false`

Also update `EnvironmentType`:
```swift
public enum EnvironmentType {
    case local, dev, testnet, production, tests
}
```

And `configured(_:type:)` to handle `.testnet`.

#### AppEnvironment+Shared.swift

`SharedAppConfiguration.toAppEnvironment()` currently falls through to `.production` for unknown environment strings. Add an explicit `"testnet"` case:
```swift
case "testnet":
    return .testnet(config: config)
```

#### ConfigManager

File: `Convos/Config/ConfigManager.swift`

Add a `case "testnet":` arm in `createEnvironment()`. The testnet case:

1. Requires `CONVOS_API_BASE_URL` from Secrets (same as Dev — no hardcoded fallback URL acceptable)
2. Passes `gatewayUrl` from config JSON (already populated in `config.testnet.json`)
3. Does not pass `xmtpEndpoint` from Secrets unless `XMTP_CUSTOM_HOST` is set (same behavior as Dev)
4. Returns `.testnet(config: config)`

Also extend the `xmtpNetwork` validator to accept `"testnet"` if that string ever appears; currently it only accepts `"local"`, `"dev"`, `"production"`, and `"prod"`. Since `config.testnet.json` sets `xmtpNetwork` to `"dev"`, this validator change may not be strictly required, but it is defensive hygiene.

#### Build Phase Scripts

All three scripts in `Scripts/build-phases/` handle Local and Dev with explicit branches; all other configurations fall through to the config-copy step only. Testnet needs its own branch to generate a `Secrets.swift` with the correct shape.

Pattern for each script: add an `elif [ "$CONFIGURATION" = "Testnet" ]` block that:

1. Reads `CONVOS_API_BASE_URL` from `.env` (same as Dev)
2. Reads `FIREBASE_APP_CHECK_DEBUG_TOKEN` from `.env` (same as Dev)
3. Writes `GATEWAY_URL = ""` (the gateway URL comes from config.json, not Secrets, for testnet)
4. Writes `XMTP_CUSTOM_HOST = ""` (not overridable for testnet)
5. Writes `SENTRY_DSN = ""` (unless a testnet-specific DSN is configured — deferred)

For `copy-env-config-main-app.sh`, the branch guard is `[ "$TARGET_NAME" = "Convos" ] && [ "$CONFIGURATION" = "Testnet" ]`, matching the existing Dev pattern.

#### Firebase Configuration

Create `Convos/Config/GoogleService-Info.Testnet.plist` as a copy of `GoogleService-Info.Dev.plist` initially. A dedicated Firebase project or app registration can be created later if testnet analytics need to be separated from Dev. There is no App Clip for Testnet in this phase, so no `ConvosAppClip/Config/GoogleService-Info.Testnet.plist` is needed.

#### Info.plist Variant

Create `Convos/Config/Info.Testnet.plist` as a copy of `Convos/Config/Info.Dev.plist`. The bundle display name will be controlled by `APP_DISPLAY_NAME` from the xcconfig, so no content changes are needed beyond using it as the per-configuration Info.plist for the Testnet build configuration.

#### App Icon

Add `AppIcon-Testnet` to the asset catalog, or reuse `AppIcon-Dev` by pointing `ASSETCATALOG_COMPILER_APPICON_NAME` at it. A distinct icon is preferable for clarity on-device but is not a blocker for the initial implementation.

#### Xcode Schemes

Create two new schemes in `Convos.xcodeproj/xcshareddata/xcschemes/`:

`Convos (Testnet).xcscheme` — copy of `Convos (Dev).xcscheme` with all `buildConfiguration = "Dev"` replaced by `buildConfiguration = "Testnet"`. The test plan reference (`Convos (Dev).xctestplan`) should be updated to a `Convos (Testnet).xctestplan` or simply omitted until one is created.

`NotificationService (Testnet).xcscheme` — copy of `NotificationService (Dev).xcscheme` with `buildConfiguration = "Dev"` replaced by `buildConfiguration = "Testnet"` in the LaunchAction.

### Data Model

No new database tables or model changes. The existing `ConvosConfiguration` struct and `SharedAppConfiguration` Codable type already carry all required fields (`gatewayUrl`, `xmtpNetwork`, etc.).

### API Changes

No API contract changes. The testnet environment points at a different base URL but uses the identical API surface as Dev.

### UI/UX

No UI changes. The only visible difference to a user is the app display name ("Convos Testnet") and app icon.

## Implementation Plan

### Phase 1: Core infrastructure (no Xcode project editing yet)

- [ ] Create `Convos/Config/config.testnet.json`
- [ ] Create `Convos/Config/Testnet.xcconfig`
- [ ] Create `Convos/Config/GoogleService-Info.Testnet.plist` (copy of Dev)
- [ ] Create `Convos/Config/Info.Testnet.plist` (copy of Dev)
- [ ] Add `AppIcon-Testnet` to asset catalog (or confirm Dev reuse)
- [ ] Add `case testnet(config: ConvosConfiguration)` to `AppEnvironment` and update all switch statements
- [ ] Add `case testnet` to `EnvironmentType` and `configured(_:type:)`
- [ ] Update `AppEnvironment+Shared.swift` `toAppEnvironment()` with explicit `"testnet"` case
- [ ] Add `"testnet"` arm to `ConfigManager.createEnvironment()`
- [ ] Extend `xmtpNetwork` validator to allow `"testnet"` network string
- [ ] Add Testnet branch to `copy-env-config-main-app.sh`
- [ ] Add Testnet branch to `copy-env-config-notification-service.sh`
- [ ] Add Testnet branch to `copy-env-config-app-clip.sh`

### Phase 2: Xcode project wiring

Done manually, not via Claude

- [ ] Open Xcode, duplicate the "Dev" build configuration for every target and name it "Testnet"
- [ ] Assign `Testnet.xcconfig` as the xcconfig for the Testnet configuration on each target
- [ ] Create `Convos (Testnet).xcscheme`
- [ ] Create `NotificationService (Testnet).xcscheme`
- [ ] Verify build succeeds for "Convos (Testnet)" scheme

### Phase 3: Apple Developer Portal

- [x] Register App ID `org.convos.ios-testnet` in the Developer Portal
- [x] Register App Group `group.org.convos.ios-testnet`
- [x] Register Notification Service extension App ID `org.convos.ios-testnet.ConvosNSE`
- [x] Create provisioning profiles for Testnet (development and distribution)
- [x] Configure associated domains for `testnet.convos.org` once the domain is decided
- [x] Update entitlements if associated domains differ from what xcconfig variables provide

### Phase 4: Validation and documentation

- [ ] Run "Convos (Testnet)" in a simulator and confirm: correct display name, bundle ID, API URL logged, gateway URL logged
- [ ] Run "NotificationService (Testnet)" scheme and confirm it builds without errors
- [ ] Confirm all existing schemes (Local, Dev, Prod) still build and behave correctly
- [ ] Update `CLAUDE.md` environment list and build command examples
- [ ] Update `.claude/commands/build.md` with testnet scheme
- [ ] Update `.claude/commands/setup.md` if it references specific environments
- [ ] Update `.claude/DESIGNER.md` if it references environments

## Testing Strategy

- Manual testing: build Testnet scheme in simulator, verify API URL and gateway URL in launch logs
- Manual testing: send a test message and confirm it routes through the XMTP dev network
- Manual testing: build each existing scheme (Local, Dev, Prod) and confirm no regressions
- No new unit tests required — the `AppEnvironment` switch changes follow the existing exhaustive pattern and the compiler will flag any missing cases

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| pbxproj corruption when manually adding build configurations | High | Make the change through Xcode UI, not direct file editing; commit the pbxproj change as its own isolated commit so it can be reverted cleanly |
| Missing `CONVOS_API_BASE_URL` in `.env` causes build-time failure | Medium | The `resolveAndValidateURL` helper already produces a clear `fatalError` message; document the required `.env` key in the testnet setup instructions |
| Associated domains for Testnet are not yet provisioned | Medium | The app will install and run without them; passkeys and universal links won't work until the domain is registered, but messaging functionality is unaffected |
| Reusing Dev Firebase project conflates testnet and dev analytics | Low | Acceptable for initial rollout; create a dedicated Firebase app registration later if needed |
| Notification extension Keychain sharing breaks without the registered App Group | Medium | Register the App Group in Phase 3 before testing push notifications on device; simulator does not require it |

## Open Questions

- [ ] Should Testnet have a completely separate Firebase project/app, or is sharing the Dev Firebase project acceptable long-term?
- [ ] Does the App Clip need a Testnet variant at any point in the near future?

## References

- `ConvosCore/Sources/ConvosCore/AppEnvironment.swift` — enum to extend
- `ConvosCore/Sources/ConvosCore/AppEnvironment+Shared.swift` — Keychain round-trip to update
- `Convos/Config/ConfigManager.swift` — environment creation logic
- `Convos/Config/Dev.xcconfig` — template for Testnet.xcconfig
- `Convos/Config/config.dev.json` — template for config.testnet.json
- `Scripts/build-phases/copy-env-config-main-app.sh` — Secrets generation to extend
- `Scripts/build-phases/copy-env-config-notification-service.sh` — Secrets generation to extend
- `Scripts/build-phases/copy-env-config-app-clip.sh` — Secrets generation to extend
- `Convos.xcodeproj/xcshareddata/xcschemes/Convos (Dev).xcscheme` — template for Convos (Testnet) scheme
- `Convos.xcodeproj/xcshareddata/xcschemes/NotificationService (Dev).xcscheme` — template for NotificationService (Testnet) scheme
