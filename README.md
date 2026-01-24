# Convos iOS

[![ConvosCore Tests](https://github.com/xmtplabs/convos-ios/actions/workflows/convoscore-tests.yml/badge.svg)](https://github.com/xmtplabs/convos-ios/actions/workflows/convoscore-tests.yml)

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
- Ruby 3.3.3
- Homebrew

### Quick Start

```bash
# Run the setup script
./Scripts/setup.sh
```

The setup script will:
- Install Git hooks for code quality checks
- Configure Xcode defaults for consistent development
- Install required dependencies:
  - SwiftLint (code linting)
  - SwiftFormat (code formatting)
  - swift-protobuf (Protocol Buffer support)
  - GitHub CLI (for release automation)
  - Bundler and Ruby gems

### Manual Setup

If you prefer to set up components individually:

```bash
# Install SwiftLint
brew install swiftlint

# Install SwiftFormat
brew install swiftformat

# Install swift-protobuf
brew install swift-protobuf

# Install GitHub CLI (optional, for releases)
brew install gh

# Install Ruby dependencies
bundle install
```

### Configuration

The setup script configures Xcode with:
- Automatic trailing whitespace trimming
- 120-character page guide
- Build operation duration display
- Disabled plugin fingerprint validation for development

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

Run tests in Xcode or via command line:
```bash
xcodebuild test -project Convos.xcodeproj -scheme Convos
```

### Code Quality

Pre-commit hooks automatically run:
- SwiftLint for code style
- SwiftFormat for formatting

## ConvosCore Documentation

ConvosCore is the core Swift Package containing shared logic between the main app and notification extension. See individual component documentation in the source files for details.
