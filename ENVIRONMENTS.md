# Environment Configuration

## Overview

The app supports 3 environments with distinct configurations:

| Environment | XMTP Network | Backend | Main Bundle ID | Purpose |
|-------------|--------------|---------|----------------|---------|
| **Local** | XMTP Local | localhost:4000 | `org.convos.ios-local` | Development with local XMTP |
| **Dev** | XMTP Dev | api.dev.convos.xyz | `org.convos.ios-preview` | TestFlight builds, real XMTP dev |
| **Production** | XMTP Prod | api.prod.convos.xyz | `org.convos.ios` | App Store release |

### Complete Bundle ID Structure

| Target | Local | Dev | Production |
|--------|-------|-----|------------|
| **Main App** | `org.convos.ios-local` | `org.convos.ios-preview` | `org.convos.ios` |
| **Tests** | `org.convos.ios-local.tests` | `org.convos.ios-preview.tests` | `org.convos.ios.tests` |
| **App Clip** | `org.convos.ios-local.Clip` | `org.convos.ios-preview.Clip` | `org.convos.ios.Clip` |
| **App Clip Tests** | `org.convos.ios-local.ConvosAppClipTests` | `org.convos.ios-preview.ConvosAppClipTests` | `org.convos.ios.ConvosAppClipTests` |
| **Notification Service** | `org.convos.ios-local.ConvosNSE` | `org.convos.ios-preview.ConvosNSE` | `org.convos.ios.ConvosNSE` |

## How Environment Switching Works

### 🏗️ Build-Time Selection
- **Xcode Build Configurations** determine which environment to use
- **`.xcconfig` files** set `CONFIG_FILE` variable per environment
- **Build script** copies the correct `config.json` to app bundle
- **`ConfigManager`** loads config at runtime and tells `AppEnvironment` what to use

### 📁 File Structure
```
Convos/Config/
├── config.local.json     # Local development settings
├── config.dev.json       # TestFlight/staging settings
├── config.prod.json      # Production settings
├── Local.xcconfig        # Build settings for local
├── Dev.xcconfig          # Build settings for dev
├── Prod.xcconfig         # Build settings for prod
└── Secrets.swift         # Generated from environment variables

Scripts/
├── generate-secrets-local.sh    # Generates Secrets.swift for local dev
├── generate-secrets-secure.sh   # Generates Secrets.swift from env vars
├── create-release-tag.sh         # Creates release tags and versions
├── get-version.sh               # Gets current app version
└── setup.sh                     # Sets up development environment
```

## 🔄 How to Switch Environments

### Method 1: Xcode Scheme (Recommended)
1. **Create 3 schemes** in Xcode:
   - `Convos Local` → Uses Debug config → Copies `config.local.json`
   - `Convos Dev` → Uses Dev config → Copies `config.dev.json`
   - `Convos Prod` → Uses Release config → Copies `config.prod.json`

2. **Switch environment:**
   - Xcode toolbar → Select scheme dropdown
   - Choose `Convos Local`, `Convos Dev`, or `Convos Prod`
   - Build and run

### Method 2: Build Configuration
1. **Product** → **Scheme** → **Edit Scheme**
2. **Run** tab → **Info** → **Build Configuration**
3. Select: `Debug` (local), `Dev`, or `Release` (prod)

## ⚙️ Setup Instructions

### 1. Add Build Configurations
1. Open **Convos.xcodeproj**
2. **Project** → **Info** → **Configurations**
3. **Duplicate** "Debug" → Rename to "Dev"
4. You should have: `Debug`, `Dev`, `Release`

### 2. Assign .xcconfig Files
1. **Project** → **Info** → **Configurations**
2. For **ALL targets** (Convos, ConvosTests, ConvosAppClip, ConvosAppClipTests, NotificationService):
   - **Debug** → Select `Convos/Config/Local.xcconfig`
   - **Dev** → Select `Convos/Config/Dev.xcconfig`
   - **Release** → Select `Convos/Config/Prod.xcconfig`

### 2.1. Set Target-Specific Bundle IDs
After assigning `.xcconfig` files, update each target's bundle ID:

1. **Convos target** → Build Settings → Product Bundle Identifier → `$(CONVOS_BUNDLE_ID)`
2. **ConvosTests target** → Build Settings → Product Bundle Identifier → `$(CONVOS_TESTS_BUNDLE_ID)`
3. **ConvosAppClip target** → Build Settings → Product Bundle Identifier → `$(CONVOS_APP_CLIP_BUNDLE_ID)`
4. **ConvosAppClipTests target** → Build Settings → Product Bundle Identifier → `$(CONVOS_APP_CLIP_TESTS_BUNDLE_ID)`
5. **NotificationService target** → Build Settings → Product Bundle Identifier → `$(NOTIFICATION_SERVICE_BUNDLE_ID)`

### 3. Set Up Secrets Generation
1. **Ensure you have a `.env` file** with required environment variables (see setup instructions below)
2. **Run setup script:** `./Scripts/setup.sh` (installs dependencies and sets up git hooks)
3. **Generate secrets:** Run `make secrets` or use the appropriate script:
   - **Local development:** `./Scripts/generate-secrets-local.sh` (auto-detects IP)
   - **CI/Production:** `./Scripts/generate-secrets-secure.sh` (uses environment variables)

### 4. Create Schemes (Optional but Recommended)
1. **Product** → **Scheme** → **New Scheme**
2. Create:
   - **Convos Local** (Debug config)
   - **Convos Dev** (Dev config)
   - **Convos Prod** (Release config)

## 🔍 Verification

After setup, you can verify environment switching works:

```swift
// Add this to your app initialization for testing
print("🏃 Running in: \(ConfigManager.shared.currentEnvironment.rawValue)")
print("🌐 Backend: \(ConfigManager.shared.backendURLOverride ?? "default")")
print("🔑 Secrets loaded: \(Secrets.CONVOS_API_BASE_URL.isEmpty ? "No" : "Yes")")
```

### Quick Environment Check
Run `./Scripts/get-version.sh` to see the current app version, or check the build logs for environment information.

## 🚨 Pointing a build at a local backend

Three behaviours here are easy to misread, because each one fails somewhere
other than the setting that caused it.

**An empty value in `.env` is not an empty value in `Secrets.swift`.** For
`XMTP_CUSTOM_HOST`, blank means "auto-detect this machine's LAN IP", and the app
dials any non-empty host it is given — so a blank line silently points XMTP at a
local node that is probably not running. To genuinely mean "no custom host, use
the network the config selects", write `USE_CONFIG`. The same applies to
`CONVOS_API_BASE_URL`, where blank falls back to `http://<LAN-IP>:4000/api`.

**The scheme decides which Firebase app you are.** `Local` builds as
`org.convos.ios-local`, `Dev` as `org.convos.ios-preview` (see the `.xcconfig`
files). App Check debug tokens are registered per app, so building a scheme you
have not used before produces a bundle Firebase does not recognise; the client
then cannot obtain an App Check token and never issues the auth request at all.
The symptom is not an auth error — it is silence, with every authenticated call
401ing and no `/v2/auth/token` reaching the backend.

**A `.env` edit does nothing until you rebuild.** The build phase regenerates
`Secrets.swift` on every build, so the value the app uses is whatever the last
build baked in — and the build phase can overwrite what
`generate-secrets-local.sh` just produced.

When installing to a simulator by hand, `xcrun simctl ... booted` picks an
arbitrary one if several are running. Target the device by UDID
(`xcrun simctl list devices booted`) instead.

## 🚨 Important Notes

- **Secrets are generated from environment variables** → `Secrets.swift` (not tracked in Git)
- **Config files are tracked in Git** (no sensitive data!)
- **Bundle IDs differ per environment** (allows side-by-side installation)
- **All environments use real XMTP networks** (local/dev/production)
- **Local development auto-detects IP addresses** for backend connectivity
- **CI builds use environment variables** for secure secret management

## 🛠️ Development Workflow

### Typical Usage:
- **Daily dev work:** Use `Convos Local` scheme (auto-detects local IP)
- **TestFlight builds:** Use `Convos Dev` scheme → `api.dev.convos.xyz`
- **App Store release:** Use `Convos Prod` scheme → `api.prod.convos.xyz`

### Release Process:
1. **Create release tag:**
   ```bash
   ./Scripts/create-release-tag.sh
   ```
   This handles version bumping, tagging, and pushing to trigger CI/CD.

2. **CI/CD Integration:**
   ```bash
   # Bitrise builds use environment-specific configurations
   xcodebuild -scheme "Convos Dev" -configuration Dev archive
   xcodebuild -scheme "Convos Prod" -configuration Release archive
   ```

### Git Hooks (Auto-installed by setup.sh)
- **pre-commit:** Formats Swift code with SwiftFormat
- **pre-push:** Runs SwiftLint to prevent pushing with violations
- **post-checkout/post-merge:** Updates dependencies and regenerates secrets

## 🧪 Testing and Development

### Initial Setup
1. **Run the setup script:**
   ```bash
   ./Scripts/setup.sh
   ```
   This installs dependencies, sets up git hooks, and configures Xcode defaults.

2. **Create a `.env` file** with your environment variables (see `.env.example`)

3. **Generate secrets:**
   ```bash
   make secrets  # Smart detection: local vs CI
   # OR manually:
   ./Scripts/generate-secrets-local.sh    # For local development
   ./Scripts/generate-secrets-secure.sh   # For CI/production builds
   ```

### Available Scripts
- **`./Scripts/setup.sh`** - Initial development environment setup
- **`./Scripts/get-version.sh`** - Get current app version from Xcode project
- **`./Scripts/create-release-tag.sh`** - Create release tags with version bumping
- **`./Scripts/generate-secrets-local.sh`** - Generate secrets for local development
- **`./Scripts/generate-secrets-secure.sh`** - Generate secrets from environment variables
- **`./Scripts/generate-mock-env.sh`** - Generate mock environment for PR builds
