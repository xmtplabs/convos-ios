fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios sync_match

```sh
[bundle exec] fastlane ios sync_match
```

Sync match profiles for all bundle IDs (run after Matchfile changes)

### ios firebase_pr

```sh
[bundle exec] fastlane ios firebase_pr
```

Build Convos (PR Preview) ad-hoc and upload to Firebase App Distribution

### ios verify_api_key

```sh
[bundle exec] fastlane ios verify_api_key
```

Sanity check API Key

### ios bootstrap

```sh
[bundle exec] fastlane ios bootstrap
```

One-time local dev setup: install team certs and profiles into the keychain

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
