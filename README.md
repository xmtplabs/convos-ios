# Convos iOS

[![ConvosCore Tests](https://github.com/xmtplabs/convos-ios/actions/workflows/convoscore-tests.yml/badge.svg)](https://github.com/xmtplabs/convos-ios/actions/workflows/convoscore-tests.yml)
[![SwiftLint](https://github.com/xmtplabs/convos-ios/actions/workflows/swiftlint.yml/badge.svg)](https://github.com/xmtplabs/convos-ios/actions/workflows/swiftlint.yml)

Convos is an everyday private chat app for the surveillance age. Built on the open-source, censorship-resistant, post-quantum secure [XMTP protocol](https://xmtp.org), Convos provides instant, impermanent, and self-evidently private conversations.

## What is Convos?

Convos is a privacy-first messenger that offers:
- **No signup** — Simply scan, tap or airdrop into a conversation
- **No numbers** — New identity in every conversation
- **No history** — Time bomb your groupchats with irreversible countdowns
- **No spam** — Every conversation is invitation-only
- **No tracking** — Zero data collection, not even contact info
- **No server** — Messages stored on your device, secured by XMTP

Learn more at [convos.org](https://convos.org).

## Project Setup

### Prerequisites

- macOS with Xcode 16+
- Homebrew
- Docker (required for running the test suite via `./dev/up`)

### Quick Start

```bash
# 1. Install dependencies and configure your environment
./Scripts/setup.sh        # or: make setup

# 2. Create your local .env from the template
cp .env.example .env

# 3. (Optional) Add a Firebase App Check debug token to .env
#    See .env comments, or generate one at:
#    https://console.firebase.google.com/project/convos-otr/appcheck
```

The setup script will:
- Configure the repo's Git hooks (`core.hooksPath` → `Scripts/hooks/`), which works for both regular clones and `git worktree`s
- Configure Xcode defaults for consistent development
- Install required dependencies:
  - SwiftLint (code linting, pinned version for compatibility)
  - SwiftFormat (code formatting)
  - swift-protobuf (Protocol Buffer support)
  - GitHub CLI (for release automation)

### Manual Setup

If you prefer to install dependencies individually, run:

```bash
brew install swiftformat swift-protobuf gh
```

Then run `./Scripts/setup.sh` once to install the pinned SwiftLint version, configure git hooks, and apply Xcode defaults.

### Configuration

The setup script configures Xcode with:
- Automatic trailing whitespace trimming
- 120-character page guide
- Build operation duration display
- Disabled plugin fingerprint validation for development

For build environments (Local, Dev, Production), bundle IDs, and secrets handling, see [ENVIRONMENTS.md](ENVIRONMENTS.md).

### Useful Make Targets

```bash
make setup           # Run Scripts/setup.sh
make status          # Show version, secrets, git, and .env status
make secrets-local   # Regenerate Convos/Config/Secrets.swift for Local builds
make protobuf        # Regenerate Swift code from .proto files
make clean           # Remove generated secrets and build artifacts
```

## Project Structure

```
convos-ios/
├── Convos/              # Main iOS application
├── ConvosCore/          # Shared business logic Swift Package
├── NotificationService/ # Push notification extension
└── Scripts/             # Build and development scripts
```

### ConvosCore Package

`ConvosCore` is a Swift Package containing all shared business logic, including:
- XMTP client management and messaging
- Database management with GRDB
- Authentication and identity management
- Conversation and message handling
- Push notification support

See [ConvosCore documentation](#convoscore-documentation) below for details.

## Development

### Building

Open `Convos.xcodeproj` in Xcode and build normally. The project uses Swift Package Manager for dependencies.

### Testing

Most ConvosCore tests require Docker to run a local XMTP node.

```bash
# Full suite — starts Docker, runs tests, stops Docker
./dev/test

# Or manage Docker manually:
./dev/up                                             # start local XMTP node
swift test --package-path ConvosCore                 # run ConvosCore tests
./dev/down                                           # stop when finished

# iOS app tests via xcodebuild (use a scheme that includes the environment)
xcodebuild test \
  -project Convos.xcodeproj \
  -scheme "Convos (Local)" \
  -destination "platform=iOS Simulator,name=iPhone 17"
```

### Code Quality

Pre-commit hooks automatically run:
- SwiftLint for code style
- SwiftFormat for formatting

## ConvosCore Documentation

ConvosCore is the core Swift Package containing shared logic between the main app and notification extension. See individual component documentation in the source files for details.
