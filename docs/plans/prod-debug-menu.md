# PRD: Prod Debug Menu

Status: Draft for review
Owner: (product owner request)
Date: 2026-06-17
Scope: Convos iOS (branch dev), main app + Notification Service Extension (NSE)
Audience: eng + product. Read-only investigation; no code changed to produce this doc.

---

## 0. TL;DR

We already ship an in-app debug menu (`DebugViewSection` in `Convos/Debug View/DebugView.swift`).
It already contains the three tools the product owner wants -- a Subscription & Credits
view, a Push-notification panel, and a SIWE auth probe. The catch: the whole menu is
hidden in production by a single runtime check:

    // Convos/App Settings/AppSettingsView.swift:326
    if !ConfigManager.shared.currentEnvironment.isProduction {
        debugRow
    }

So in a prod build, none of it is reachable -- but (critically) the code is still
compiled into the production binary. The gate is environment-based, not `#if DEBUG`,
and `#if DEBUG` does not even strip code inside the ConvosCore SPM package (documented
at `ConvosCore/.../Messaging/MessagingService+DebugInjector.swift:12-14`).

This PRD proposes a "Prod Debug Menu": a curated, read-only, own-account subset of those
tools, reachable in RELEASE/prod builds behind a hidden activation gesture plus an
explicit enable/disable toggle, with a visible "debug mode ON" indicator and auto-expiry.
The crux for a privacy-first E2EE app: the gesture's secrecy is obscurity, not a security
boundary. Only Tier 1 (read-only, own-account) tools go behind it. Everything that touches
message content, key material, other users' data, environment switching, or destructive
actions stays compile-time-stripped or behind a server-validated staff allowlist.

---

## 1. Motivation

We hit bugs that only reproduce on real production accounts, against the production
backend and real prod XMTP/MLS state. Dev and local builds cannot reproduce them because
the failing state lives on a specific prod inbox/installation.

Recent concrete example (2026-06-15, session `prod-msg-not-delivered`): a user's emoji
send showed "Not Delivered." Root cause was that the user's MLS installation had been
silently removed from the group (libxmtp marked the group `INACTIVE` after an
`UpdateGroupMembership` commit), and the app never detected the removal because the
detection path needs to decode a `GroupUpdated` event that an inactive group can no longer
yield. Diagnosing it required reading prod-only, on-device facts: the inboxId, the
installation ID, group membership/epoch state, and the on-device logs. The investigation
leaned entirely on production diagnostics pulled off the device.

We already accept and ship prod diagnostics today. The conversation "Support" section
ships in every environment so production users can send on-device diagnostics to support:

    // Convos/Conversation Detail/ConversationInfoView.swift:673-684
    // "The support rows ship in every environment so production users can send
    //  on-device diagnostics to support; the remaining rows are internal debugging
    //  tools and stay out of production builds."

`reportIssueRow` (`ConversationInfoView.swift:745`) and `shareLogsRow`
(`ConversationInfoView.swift:773`) are rendered unconditionally and export a zipped log
bundle (`Convos/Debug View/DebugLogExporter.swift:6` `exportAllLogs(...)`, writing from
the app-group `Logs/convos.log`). So "ship read-only diagnostics in prod" is established
precedent, not a new posture.

What's missing is structured, in-app, on-device readouts that let an engineer (or a
trusted internal tester on their own prod account) read the exact identifiers and state
needed to triage -- without a Mac, a debugger, or a TestFlight rebuild. That is what the
three requested tools provide, and they already exist; they're just locked behind the
non-production gate.

Why now / why a gesture instead of just always-on: these readouts include identity
correlators (inboxId, installation IDs, eth address) and a stable device identifier (APNs
token) that should not be visible in normal prod UI. A hidden, opt-in, auto-expiring
surface bounds who ever sees them and for how long.

Non-goals: this is not a remote-admin tool, not an environment switcher, not a way to
inspect message content or other users' data, and not a replacement for proper telemetry
(Sentry/PostHog already ship).

---

## 2. Activation mechanism

### 2.1 Trigger (hidden gesture to reveal)

Recommendation: N consecutive taps on the version label in App Settings.

The version label already exists: `Text("V\(Bundle.appVersion)")` at
`AppSettingsView.swift:370`, and it currently has no gesture. Attaching a tap-count
recognizer to it is the smallest, most iOS-idiomatic change and mirrors the long-standing
Android "tap the build number 7 times" easter egg -- discoverable enough to feel like an
easter egg, obscure enough not to be hit by accident.

- Proposed: 7 taps within a short window (e.g. 3s) on the version label.
- On reaching the threshold, present a confirmation ("Enable debug mode?") rather than
  silently flipping state, so an accidental burst of taps does nothing.

Alternatives considered and rejected:

- A literal on-screen "Konami code" (directional swipes / button sequence): clunky on a
  touchscreen, googleable, and easy to fat-finger. Rejected.
- Shake gesture (`motionEnded(_:with:)`): ergonomic, but fires accidentally (walking,
  in a pocket, on transit) and is hard to scope to one screen. Acceptable as a secondary
  trigger but not the primary one.
- Multi-finger long-press on a specific surface: works, but less discoverable and harder
  to document for internal testers than "tap the version number."

The tap-the-version-label trigger keeps the easter-egg flavor, is trivially documentable
for internal testers, and reuses an element that's already on screen.

### 2.2 Enable/disable toggle

Revealing the gesture does not itself dump sensitive data -- it reveals a Debug Mode
screen whose top control is an explicit on/off toggle. Debug mode is OFF by default. The
toggle is the thing that gets persisted (section 2.4). Turning it off immediately hides
the menu and clears the indicator.

### 2.3 Visible "debug mode ON" indicator (required)

When debug mode is on, the app must show a persistent, unmistakable indicator so a user
(or a support agent looking at a screen recording) can always tell the device is in an
elevated-diagnostics state. Options: a thin tinted status banner, a persistent badge on
the Settings tab, or a small floating chip. Requirement is "always visible while on," not
the specific visual. This protects against a device being left in debug mode unknowingly.

### 2.4 Persistence + NSE visibility (app-group UserDefaults)

The enabled flag must be readable by the Notification Service Extension, so push-debug
behavior (e.g. recording last-push metadata) can honor it. It therefore lives in
app-group UserDefaults, not `UserDefaults.standard`.

Exact precedent to copy: `ConvosCore/Sources/ConvosCore/Pairing/PairedDeviceNameStore.swift`,
which stores to `UserDefaults(suiteName: appGroup)` and whose own doc comment says
"Storage is app-group UserDefaults so the NSE could read it too if it ever needs to (it
doesn't today)." `BadgeCounter` (`ConvosCore/.../Notifications/BadgeCounter.swift:7,15`)
is the confirmed two-way example: the NSE writes it (`NotificationService.swift:109`) and
the main app reads/resets it (`Convos/ConvosAppDelegate.swift:28`).

The app group id is per-environment, from `config.json`'s `appGroupIdentifier`, surfaced
as `AppEnvironment.appGroupIdentifier` (`AppEnvironment.swift:116`); prod is
`group.org.convos.ios` (`Convos/Config/config.prod.json:6`). The NSE shares the group via
`NotificationService/NotificationService.entitlements`.

Note: the existing runtime feature flag `FeatureFlags.isDebugInjectorEnabled`
(`Convos/Config/FeatureFlags.swift:12`) is the right model for a persisted runtime toggle
that is hard-locked off in prod -- but it uses `UserDefaults.standard` (app-only) and so
is NOT visible to the NSE. The new debug-mode flag must use the app-group suite instead.

### 2.5 Auto-expire (required, bounds the exposure window)

Debug mode must not persist indefinitely. Two complementary expiry rules:

1. Expire on app cold-launch: write an `enabledAt` timestamp alongside the flag; on
   launch, if the process is a fresh start (not a warm resume), clear the flag. This means
   a user must re-arm debug mode each session.
2. Time cap: store `enabledAt`; any reader (app or NSE) treats the flag as OFF if
   `now - enabledAt > N hours` (proposed N = 4). The NSE honors the same cap when it reads
   the flag, since it cannot rely on the app's launch lifecycle.

Storing `enabledAt` (a `Date`) next to the bool in the app-group suite lets both processes
evaluate expiry independently without coordination.

### 2.6 Re-confirmation for sensitive items

Even within Tier 1, the most sensitive fields (raw APNs token, eth address, accountId,
inboxId, installation IDs) are masked/truncated by default. Revealing the full value, or
copying it to the clipboard, requires a per-item tap-to-reveal / explicit "Copy" action
with a confirmation. Debug mode being on is necessary but not sufficient to see a full
identity correlator in the clear.

---

## 3. Risk tiering (the crux)

This is a privacy-first, E2EE messaging app. The activation gesture is security through
obscurity: it is googleable in principle, leaks via documentation to internal testers, and
the underlying tool code is already compiled into the prod binary (the gate is runtime,
not `#if DEBUG`, and `#if DEBUG` does not strip code inside ConvosCore). Therefore:

> The gesture's secrecy MUST NOT be the security boundary for any sensitive data.

Only Tier 1 goes behind the gesture. Tier 2 stays compile-time-stripped at the app-target
call site (the `DebugConnectionInjectorSheet` `#if DEBUG` pattern) or behind a
server-validated staff allowlist -- never the client gesture alone.

### Tier 1 -- read-only, own-account; safe behind the gesture in prod

Confirmed read-only and own-account by investigation:

| Tool | file:line | Read-only / own-account |
|------|-----------|--------------------------|
| Build / bundle id / version / environment display | `DebugView.swift:200-221` | yes / yes |
| Log storage size + log export (already ships in prod) | `DebugView.swift:223-232`; `DebugLogExporter.swift:38-63`; `ConversationInfoView.swift:773` | yes / yes |
| Sync status / own MLS commit-log + epoch diagnostics | `ConvosCore/.../Extensions/Conversation+ExportDebugInfo.swift:5-37` | yes / yes (membership-change metadata only, no plaintext) |
| Feature-flag readout (display only) | `DebugView.swift:72-93` | display yes; the toggle mechanic is Tier 2 |
| (1) Subscription & Credits readout | `Convos/Subscription/SubscriptionSettingsView.swift:97-173` | yes / yes (see 4.1) |
| (2) Push-notification readout | `DebugView.swift:144-197` | yes / yes (see 4.2) |
| (3) Identity view (SIWE address, accountId, inboxId, installation IDs, SIWE config, app/build/env) | static local reads; see 4.3 | yes / yes (see 4.3) |

### Tier 2 -- must NOT sit behind a mere client gesture in prod

Keep `#if DEBUG` (app-target call site) or gate behind a server-validated staff allowlist.

| Tool | file:line | Risk |
|------|-----------|------|
| Live BackendAuthProbe / "Run Auth Probe" (SIWE JWT mint) | `Convos/Debug View/DebugAuthProbeView.swift:31-65, 99-122`; `BackendAuthProbe.swift` | Makes live signed network call; Result carries a JWT bearer token (`BackendAuthProbe.Result.jwt`). Never render or copy the JWT from any prod-reachable surface. Stays #if DEBUG / staff-gated. |
| Hidden-messages debug decoder | `ConvosCore/.../Messaging/XMTPClientProvider+HiddenMessagesDebug.swift:47-263`; UI `ConversationInfoView.swift:733` | Decodes OTHER members' control traffic: sender inboxIds, cleartext profile names, reaction targets, connection-payload contents. Other-users' data. |
| Conversation metadata debug (carries live invite tag) | `ConvosCore/.../Messaging/XMTPClientProvider+MetadataDebug.swift:24-46`; UI `ConversationInfoView.swift:727` | Surfaces the live invite tag = an unguessable join/capability secret; disclosure lets the holder join/mint invites. |
| Connection-payload injector | `ConvosCore/.../Messaging/MessagingService+DebugInjector.swift:15-29`; sheet `DebugConnectionInjectorSheet.swift` (whole file `#if DEBUG`) | Mutating; forges agent-triggering messages. Already gold-standard locked (flag off in prod + button hidden + `#if DEBUG` sheet + core throws in prod). Replicate this pattern. |
| Restore invite tag | `ConversationInfoView.swift:737-741` -> `ConversationViewModel.swift:4018-4030` | Mutating MLS group state. |
| Subscription debug toggles (use-real-StoreKit / use-real-credits / credits-state preset / Show Paywall) | `DebugView.swift:95-141` | Fakes balance/subscription app-wide via shared singletons; Show Paywall launches a real purchase. |
| Subscribe / Change-plan / Manage CTAs | `SubscriptionSettingsView.swift:118-131` | Launches real StoreKit purchase / external account management. |
| Reset onboarding / reset all settings / register device again | `DebugView.swift:368-389, 431-488` | Mutates onboarding / device-registration / UserDefaults state. |
| "Hold to reset account" -> `deleteAllInboxes()` | `OrphanedInboxDebugView.swift:72-84`; wipe `SessionManager.swift:469-569` | Full local account wipe. (The user-facing "Delete all app data" in `AppSettingsView.swift:96` is the same primitive shipped deliberately with a 3s hold; that is fine -- but it must never sit behind an accidental gesture.) |
| Pending-invite delete (+ exposes invite-tag prefixes) | `PendingInviteDebugView.swift:111-145, 158` | Mutating; leaks invite-tag prefixes. |
| Asset renewal: "Renew now" / per-asset renew / copy-key | `DebugView.swift:333-343, 466-481`; `DebugAssetRenewalView.swift:140-155` | Mutating network renew; copy-key puts an encrypted-asset key on the clipboard. |
| Sentry test events | `DebugView.swift:276-303, 490-536` | Sends events to Sentry; pollutes prod telemetry. |
| PostHog project token row (copy) | `DebugView.swift:238-261` | Exposes/copies an analytics API key to the clipboard. |
| ConnectionsDebugView (currently unwired) | `ConvosConnections/.../Debug/ConnectionsDebugView.swift` | `public`, only `#if canImport(SwiftUI)` (NOT `#if DEBUG`); holds in-memory contact names/GPS + mutating start/stop/fake-grant. Safe only because nothing instantiates it -- wrap in `#if DEBUG` before any wiring. |
| DebugAgentKeysetOverride | `ConvosCore/.../Crypto/DebugAgentKeysetOverride.swift:14-24`; call site `ConvosApp.swift:81-89` (`#if DEBUG`) | Weakens agent-attestation trust; keep stripped from prod. |
| QAAutomationServer | `QAAutomationServer/QAAutomationServer.swift` | Unauthenticated TCP :8615 that drives the full UI. Not in any shipped scheme/archive, so not a prod risk; dev/CI hardening only. |

Reassuring negatives to state explicitly: there is NO runtime environment switcher
(prod/dev is bundled `config.json`, memoized in `ConfigManager.swift:70-91`), NO
key-export/dump tool, NO database-export tool, NO bulk-plaintext decrypt, and NO
keychain dump (single-item reads only). These do not exist and must not be added to a
prod-reachable surface.

---

## 4. Item specs (the three requested tools)

For each: what it shows, data source (file:line), tier, and any field "more sensitive than
it looks." The common rule: split the passive readout (Tier 1) from the active/mutating
controls currently bundled on the same screens (Tier 2), and mask sensitive identifiers by
default. Items 4.1 and 4.2 are straightforward Tier-1 readouts. Item 4.3 (SIWE /
account-identity) is split: the static Identity view is Tier 1; the live auth probe stays
Tier 2 and is never in the prod gesture menu.

### 4.1 Subscription & Credits -- Tier 1

What it shows: own credit balance + monthly grant + grant used + next refresh date +
period label (and derived `isLow`/`isDepleted`/`fractionRemaining`); subscription tier,
period, status, productId, current period end, willRenew, isInTrial.

Data source:
- Credits view: `Convos/Subscription/SubscriptionSettingsView.swift:97-173`.
- Credits read repository (read-only by construction -- protocol has only
  `balancePublisher` / `currentBalance()`): `ConvosCore/.../Storage/Repositories/CreditsRepository.swift:8-44`.
- Model: `ConvosCore/.../Storage/Models/CreditBalance.swift:3-42`.
- Backing data: backend `GET /v2/accounts/me/credits` via
  `ConvosCore/.../Storage/Writers/CreditBalanceWriter.swift:44-61`, cached to a single-row
  GRDB table (`credit_balance`). The repository reads that local cache. Credits are
  account-level (one global balance), consistent with the single-row design.
- Subscription: `GET /v2/accounts/me/subscription` + StoreKit 2 entitlements via
  `Convos/Subscription/StoreKitSubscriptionService.swift`.

Tier: Tier 1. `/me/` endpoints + a `userId`-free service protocol make it structurally
own-account-only. The reads have no side effects beyond benign network re-reads.

More sensitive than it looks: nothing severe -- balance/plan are low-sensitivity
own-account data. The risk on this screen is the bundled mutating controls, not the
readout: exclude the DebugView subscription toggles/preset-picker (`DebugView.swift:95-141`)
and the live "Subscribe / Change plan / Manage" CTAs (`SubscriptionSettingsView.swift:118-131`)
from the prod read-only surface, or isolate them so they cannot be triggered from it.

### 4.2 Push-notification debug -- Tier 1

What it shows: notification authorization status; authorized yes/no; APNs environment
(sandbox/production); the APNs device token; device-registration state; topic-subscription
cache hash + desired topics. Optionally (new storage) last-push metadata / NSE
decrypt-success.

Data source:
- Existing panel: `Convos/Debug View/DebugView.swift:144-197` (auth status :149, authorized
  :155, APNS env :162, device token row + copy :175-197).
- Registrar (the iOS `PushNotificationManager` bridge): token held in-memory at
  `ConvosCore/Sources/ConvosCoreiOS/IOSPushNotificationRegistrar.swift:17`; auth status via
  `UNUserNotificationCenter.notificationSettings().authorizationStatus` at :35-60; static
  read-only accessor `PushNotificationRegistrar.token`.
- Token receipt: `Convos/ConvosAppDelegate.swift:62-67`.
- Registration state persisted (read-only flags): `DeviceRegistrationManager`
  (`lastRegisteredDevicePushToken_*`, `hasRegisteredDevice_*` in UserDefaults).
- Topic cache: `ConvosCore/.../Syncing/PushTopicSubscriptionCache.swift:29`.
- NSE: `NotificationService/NotificationService.swift` (`didReceive` :68-124); decrypt in
  `ConvosCore/.../Inboxes/MessagingService+PushNotifications.swift`. Decrypt success/failure
  is currently only LOGGED, not persisted -- surfacing "last push decrypt status" would
  require new app-group storage (and the NSE would gate writing it on the new debug flag).

Tier: Tier 1 for the readout. All fields are own-device / own-account, read-only.

More sensitive than it looks: the raw APNs device token is a stable per-device identifier
-- a device-correlation/tracking vector, and (combined with the push key) a spoofing
target. Mask/truncate by default; require tap-to-reveal + explicit copy. The existing
"Request Now" (`DebugView.swift:166-171`) and "Register Device Again" (:431-460) buttons
are mutating (Tier 2) -- exclude them from the prod read-only readout.

### 4.3 SIWE / account-identity -- SPLIT between Tier 1 and Tier 2

This item is split into two surfaces that must never be combined behind the prod gesture.
The rationale: the prod menu must show only locally-available, static identity info and
must never expose the live token-minting probe or its JWT output.

#### 4.3-A Identity view (Tier 1 -- in the prod debug menu)

What it shows: a read-only "Identity" section composed entirely of locally-available,
static values -- no network call, no `BackendAuthProbe`, no JWT.

Fields:
- Checksummed eth address (from `SIWESigner.swift:76-84`, EIP-55 via `EthereumAddress.swift:26-46`)
- accountId (from JWT claim stored locally; `BackendAuthProbe.swift:89` is one source,
  but the value should come from the on-device identity store, not a live probe)
- inboxId (`ConvosCore/.../Auth/Keychain/KeychainIdentityStore.swift:76-80`)
- Current installation id + peer installation ids (`InstallationInfo.swift:20-30`;
  `DevicesViewModel.swift:121-122`)
- SIWE config: domain (`convos.org`), uri, chainId (`1`)
  (`ConvosConfiguration.swift:8-18`; prod values `config.prod.json:13-15`)
- App version, bundle id, build number, environment (already in `DebugView.swift:200-221`)

Implementation note: extract this static portion out of the existing combined
`DebugAuthProbeView` into the curated `ProdDebugMenuView`. The Identity view reads
only on-device stores; it does not instantiate `BackendAuthProbe` at all.

Tier: Tier 1. Every field is the device's own identity read from local storage.
Peer installation ids are this account's other devices -- still own-account, never another
user's.

More sensitive than it looks: the eth address, accountId, inboxId, and installation ids
are strong identity correlators -- they tie the otherwise-pseudonymous user to an on-chain
identity and a backend account. None appear in normal prod UI. Mask/truncate by default;
reveal/copy is an explicit per-item action (section 2.6).

#### 4.3-B Live auth probe (Tier 2 -- never in the prod gesture menu)

The existing `DebugAuthProbeView` (`Convos/Debug View/DebugAuthProbeView.swift:31-65,
99-122`) performs a live `/v2/account-auth-check` round-trip via `BackendAuthProbe.swift`.
Its `Result`/`Status` structs carry the full SIWE JWT (`BackendAuthProbe.swift:11`
`let jwt: String`) -- a live bearer credential.

This surface stays `#if DEBUG` / staff-gated and is never reachable from the prod gesture.
If it is shown anywhere (dev/local/staff builds only), the raw JWT must never be rendered
or placed on the clipboard. The "Run Auth Probe" actions make live signed network calls and
are mutating in the sense that they mint a fresh bearer token -- they do not belong behind
an obscurity-only client gesture.

The prod menu shows identity (4.3-A), never the live probe (4.3-B).

### 4.4 Baseline Tier-1 set (ship alongside the three)

These round out the menu and are all read-only / own-account:
- Build / bundle id / version / environment (`DebugView.swift:200-221`).
- Log storage size + log export (`DebugView.swift:223-232`; export already ships in prod).
- Sync status + own MLS commit-log / epoch readout
  (`Conversation+ExportDebugInfo.swift:5-37`) -- exactly the data the
  prod-msg-not-delivered RCA needed.
- Feature-flag readout (display only; the toggle is Tier 2).

---

## 5. Implementation approach

### 5.1 A runtime DebugMenu gate replacing the compile-time/env split for the curated subset

Today the menu is gated by `!isProduction` (`AppSettingsView.swift:326`). Replace that, for
the curated Tier-1 subset only, with a runtime check against a new debug-mode gate that is
true in prod only when the user has armed it via the gesture and it has not expired:

    // conceptual
    if DebugMenuGate.isEnabled(for: ConfigManager.shared.currentEnvironment) {
        debugRow  // -> a ProdDebugMenuView containing the Tier-1 subset
    }

`DebugMenuGate.isEnabled` returns true when either (a) the environment is non-production
(unchanged behavior for dev/local -- they keep the full menu), or (b) the environment is
production AND the app-group flag is on AND not expired (section 2.5). This preserves the
existing internal experience and adds the curated prod surface on top.

The codebase already prefers runtime gates over `#if DEBUG` for exactly this reason --
`#if DEBUG` does not propagate into the ConvosCore SPM package
(`MessagingService+DebugInjector.swift:12-14`), so runtime `AppEnvironment` checks are the
established convention. The new gate follows that convention.

### 5.2 The gate flag's home (app group)

New value-type facade, modeled on `PairedDeviceNameStore`, e.g. `DebugMenuFlagStore`:

- Storage: `UserDefaults(suiteName: environment.appGroupIdentifier)` (NOT
  `UserDefaults.standard`).
- Keys: `convos.debugMenu.enabled.v1` (Bool) and `convos.debugMenu.enabledAt.v1` (Date).
- API: `isEnabled(environment:)` (applies the time-cap from 2.5), `enable(environment:)`
  (stamps `enabledAt = now`), `disable(environment:)`, `clearIfNewLaunch(environment:)`.
- Hard rule: in production, `isEnabled` returns false unless the flag is set AND within the
  time cap -- same defensive posture as `FeatureFlags.isDebugInjectorEnabled`
  (`FeatureFlags.swift:14`), but in the app-group suite.

### 5.3 Gesture recognizer + indicator

- Attach a tap-count gesture (7 taps / 3s) to the version label
  `AppSettingsView.swift:370`; on threshold show a confirm dialog that calls
  `DebugMenuFlagStore.enable(...)`.
- The Debug Mode screen's top control is the on/off toggle bound to the flag.
- While enabled, render the always-visible indicator (section 2.3) at the app shell level
  (e.g. a banner/overlay in the root container) so it shows on every screen, not just
  Settings.

### 5.4 Curated prod view -- split readout from controls

Build a `ProdDebugMenuView` that composes only the Tier-1 readouts. Do not point the
gesture at the existing `DebugViewSection`/`DebugExportView` wholesale -- those interleave
Tier-2 mutating controls (subscription toggles, "Request Now", reset buttons, Sentry tests,
PostHog token copy, asset renew). Reuse the read-only sub-views (or factor read-only
subsections out of the existing sections) and leave the mutating controls compiled behind
`#if DEBUG` at the app-target call site, exactly as `DebugConnectionInjectorSheet.swift`
does (`#if DEBUG` view, `EmptyView()` in `#else`).

For the SIWE/account identity view (4.3-A), extract the static read-only fields (eth
address, accountId, inboxId, installation ids, SIWE config) out of the existing combined
`DebugAuthProbeView` into `ProdDebugMenuView`. The live `BackendAuthProbe` round-trip
(4.3-B) stays `#if DEBUG` / staff-gated and is never reachable from the prod gesture.
The prod menu shows identity, never the live token-minting probe.

### 5.5 How the NSE reads the flag

The NSE already reads shared state at runtime: environment from the app-group Keychain
(`NotificationExtensionEnvironment.getEnvironment()`), the shared GRDB DB, and the badge
count from app-group UserDefaults (`NotificationService.swift:109`). It branches on
`environment.isProduction` at runtime (`NotificationService.swift:32`).

So the NSE reads `DebugMenuFlagStore.isEnabled(environment:)` from the same app-group suite,
applying the same time-cap. Initial NSE use: when debug mode is on, persist last-push
metadata / decrypt-success to app-group storage so the push panel (4.2) can display it;
when off, do nothing extra. The NSE must never gate any security decision on this flag --
it is a diagnostics toggle only.

### 5.6 Keep Tier 2 stripped or staff-gated

Tier-2 items either stay compiled out via app-target `#if DEBUG` (injector pattern) or, if
a tool genuinely must run on prod for staff, gate it behind a server-validated staff
allowlist (the server confirms the account is staff before the tool unlocks) -- never the
client gesture alone. Also: wrap the currently-unwired `ConnectionsDebugView` in
`#if DEBUG` before anyone wires it, since it is `public` and not DEBUG-guarded today.

---

## 6. App Store note

Hidden developer/debug menus are standard and allowed. This design uses no private APIs:
the gesture is a normal `TapGesture`/`UITapGestureRecognizer`; storage is app-group
`UserDefaults`; the readouts use public framework calls already in the app
(`UNUserNotificationCenter`, StoreKit, the app's own backend, on-device XMTP/keychain).
Nothing is deceptive: the feature surfaces the user's own account information on their own
device, behind an explicit opt-in toggle with a visible active-state indicator, and
auto-expires. It does not download executable code, does not change documented app
behavior for normal users, and exposes no other users' data. This is consistent with the
diagnostics we already ship (Report an issue / Share logs).

---

## 7. Open questions and risks

1. Biggest risk: scope creep across the Tier 1 / Tier 2 line. The single most important
   constraint is that the gesture is obscurity, not a boundary, and the tool code is
   already in the prod binary. If anyone later points the gesture at the existing
   `DebugViewSection` wholesale (rather than a curated `ProdDebugMenuView`), every Tier-2
   mutating/other-users'-data tool becomes reachable in prod behind a googleable gesture.
   The curated-view split (5.4) and a code-review checklist item ("nothing Tier 2 reachable
   from the prod gate") are the mitigations.

2. Should the prod debug menu be available to all prod users, or only staff? A pure client
   gesture gates nobody by identity. If product wants these readouts only for staff/internal
   testers, even the Tier-1 surface should be additionally gated by a server-validated staff
   allowlist. Decision needed. (Tier 2, if ever exposed, must be staff-gated regardless.)

3. Auto-expire tuning: is "cleared on cold launch" too aggressive for a tester walking
   through a multi-launch repro? Proposed default N=4h time cap + clear-on-cold-launch;
   confirm both, or relax to time-cap-only.

4. Identity-correlator exposure: even masked + tap-to-reveal, surfacing inboxId /
   installation ids / eth address / APNs token in prod widens who can read them (e.g. over
   the user's shoulder, or in a screen recording sent to support). Confirm product accepts
   this for the triage value, and that masking-by-default + explicit reveal is sufficient.

5. New NSE storage for last-push metadata (4.2): adds app-group writes from the extension.
   Confirm we want the NSE writing diagnostics at all when debug mode is on (extension
   runtime/memory budget is tight). Could be deferred -- the push panel ships useful data
   without it.

6. SIWE split enforcement: the live `BackendAuthProbe` and its JWT (`BackendAuthProbe.Result.jwt`,
   a bearer credential) must remain `#if DEBUG` / staff-gated. Confirm that the extraction of the
   static Identity view (4.3-A) from `DebugAuthProbeView` does not inadvertently keep a reference to
   `BackendAuthProbe` in `ProdDebugMenuView`. Code review gate: the prod view must not import or
   instantiate `BackendAuthProbe` at all.

7. Indicator placement: confirm the "debug mode ON" indicator can be rendered app-wide
   (root container) without conflicting with existing overlays/banners.
