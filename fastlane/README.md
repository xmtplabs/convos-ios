fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Lane definitions

Lane definitions live in [xmtplabs/convos-releases](https://github.com/xmtplabs/convos-releases/tree/main/fastlane/lanes) and are pulled in via the nix dev shell. Run `fastlane` from `nix develop` (or let direnv activate it automatically).

# Available Actions

## iOS

### ios sync_match

```sh
fastlane ios sync_match
```

Sync match profiles for all bundle IDs (run after Matchfile changes)

### ios sync_devices

```sh
fastlane ios sync_devices
```

Regenerate every profile type (adhoc + development) for new devices. Used by the daily sync-devices workflow.

### ios firebase_pr

```sh
fastlane ios firebase_pr
```

Build Convos (PR Preview) ad-hoc and upload to Firebase App Distribution

### ios verify_api_key

```sh
fastlane ios verify_api_key
```

Sanity check API Key

### ios bootstrap

```sh
fastlane ios bootstrap
```

One-time local dev setup: install team certs and profiles into the keychain

----

This README.md documents the available lanes. Lane source lives at [xmtplabs/convos-releases](https://github.com/xmtplabs/convos-releases/tree/main/fastlane/lanes).

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
