# iOS Plan — Sync XMTP identity via iCloud Keychain

> Stacks on top of `louis/auth-siwe-plan` (PR #827). Inspired by the keychain layout work in `louis/backup-relanding` (PR #802), but deliberately *much smaller* — no encrypted backup bundle, no two-key model, no archive importer. Just iCloud Keychain.

## Context

Today the XMTP identity (signing key + database key) lives in a **device-local** Keychain slot:

```swift
KeychainQuery(account: "convos-identity",
              service: "org.convos.ios.KeychainIdentityStore.v3",
              accessGroup: <appGroup>,
              accessible: kSecAttrAccessibleAfterFirstUnlock,
              synchronizable: false)   // ← this
```

Consequence: each device generates its own private key, which derives its own Ethereum address, which produces its own backend `Account` row. Lose the device → lose the account. No multi-device.

Now that SIWE binds the iOS app to a backend `Account` via the Ethereum address derived from this key, "the same wallet on two devices = the same backend account" is a free feature *if* the key can follow the user across their Apple-ID-paired devices.

## Goal

Identity syncs via **iCloud Keychain** to all devices signed in to the same Apple ID. Sign in on iPhone → install Convos on iPad → already signed in to the same `Account`.

## Scope (deliberately tight)

- Flip the existing `KeychainIdentityKeys` slot to `synchronizable: true`.
- One-shot migration for existing users: move the identity from the current device-local slot into the synced slot on first launch with the new build.
- Surface state in the debug menu (which slot the identity lives in, sync flag).
- Tests.

**Explicitly NOT in this PR**
- Encrypted backup bundle (`Convos/Backup/*` from PR #802) — separate, larger effort.
- Two-key model splitting identity vs backup-envelope (PR #802 territory).
- BIP-39 mnemonic export.
- "Trusted device" linking flow.
- Cross-platform restore.

Each of those is real and worth doing eventually. None is required to ship iCloud sync for the SIWE/multi-device path.

## Why "just flip the flag" works for the SIWE flow

The backend's `upsertAuthMethodAndAccount` uniques on `(SIWE, lowercased_address)`. Two devices with the same private key resolve to the same address, which resolves to the same `Account.id`. Each device still mints its own JWT (the JWT slot is `(deviceId, address)`-scoped, so no JWT cross-talk). libxmtp creates a separate **installation** per device anyway — both authorized by the shared owner key. This is exactly XMTP's intended multi-device shape.

## Design

### File-level changes

**`ConvosCore/Sources/ConvosCore/Auth/Keychain/KeychainIdentityStore.swift`**

Introduce a second service identifier alongside the existing v3:

```swift
public static let legacyIdentityService: String = "org.convos.ios.KeychainIdentityStore.v3"  // local-only
public static let syncedIdentityService: String = "org.convos.ios.KeychainIdentityStore.v4-synced"
```

Keep the same `account` (`convos-identity`) and the same `kSecAttrAccessibleAfterFirstUnlock` (already sync-compatible). The only attribute that changes between slots is `kSecAttrSynchronizable`.

**Read path** — `load()` / `loadSync()` checks the synced slot first, falls back to legacy:

```swift
public nonisolated func loadSync() throws -> KeychainIdentity? {
    if let data = try? Self.loadKeychainData(with: syncedQuery().toReadDictionary()) {
        return try JSONDecoder().decode(KeychainIdentity.self, from: data)
    }
    if let data = try? Self.loadKeychainData(with: legacyQuery().toReadDictionary()) {
        // Lazy migration on next save(); read returns the legacy data verbatim.
        return try JSONDecoder().decode(KeychainIdentity.self, from: data)
    }
    return nil
}
```

**Write path** — `save(...)` writes the synced slot and removes the legacy one in the same call so the migration is self-healing on any identity touch:

```swift
public func save(inboxId:, clientId:, keys:) throws -> KeychainIdentity {
    let identity = KeychainIdentity(...)
    try saveData(JSONEncoder().encode(identity), with: syncedQuery())
    try? deleteData(with: legacyQuery())  // best-effort migration; ignore "not found"
    return identity
}
```

**Delete path** — `delete()` clears both slots so a sign-out wipes the legacy holdover too.

### Migration (one-shot, lazy)

Triggered on the first save after upgrade. The path is:

1. User upgrades, opens app.
2. Existing identity in `…v3` (local-only).
3. App calls `load()` — checks synced slot (miss), falls back to legacy (hit), returns identity.
4. Next time anything calls `save()` (most app lifecycle events touch this), the identity is written to `…v4-synced` and the legacy slot is deleted.
5. CKKS picks up the new synced item over the next minutes; paired devices see it.

Optional aggressive variant: run an explicit `save` on first launch after upgrade (if `load()` returned legacy data) to force the migration without waiting for an organic save. Cheap, removes the "if save never fires" tail risk.

PR #802's `KeychainLayoutMigrator` does a more elaborate guarded version with `UserDefaults` generation tracking. We don't need that complexity here because (a) the source slot is **local-only** (no cross-device deletion to coordinate) and (b) the migration is idempotent — running it more than once is a no-op.

### Debug surface

Add to `DebugAuthProbeView` (or as its own row in `DebugViewSection.authProbeSection`):

- "Identity slot: synced / legacy / missing"
- "Synchronizable flag: yes / no"
- "iCloud Keychain enabled (device-level)": from `SecCopyMatching` query against an iCloud-eligible class — only useful if Apple ever exposes a programmatic check; otherwise show "unknown" with a deep-link to Settings → iCloud → Keychain.

This is the same observability shape we added for `accountId` in PR #827 — read-only, refreshable, no network.

### Doc updates

- Update the `KeychainIdentityStore` class doc to explain the v3-local → v4-synced migration.
- Inline note: `databaseKey` gets synced too as part of `KeychainIdentityKeys`. This is harmless (each device's SQLCipher DB is separate; shared key doesn't cross databases) but suboptimal — splitting them is PR #802's two-key refactor.

## Tests

In `ConvosCoreTests` (or `KeychainIdentityStoreTests` if that target is enabled):

1. Save → re-load round-trip writes to synced slot with `kSecAttrSynchronizable == true`.
2. Pre-populate the legacy slot, call `load()`, expect identity returned. Then call `save()`, expect the identity to be present in the synced slot and absent from the legacy slot.
3. `delete()` clears both slots.

Notes:
- Simulator keychain doesn't actually push to iCloud, but it accepts and persists the `synchronizable` flag. Tests verify the *attribute* is set, not the wire push.
- The existing test target's keychain access can be flaky without entitlements; reuse the `MockKeychainService`-style pattern where useful, or stub via a protocol seam if testing on the real backend is needed.

## Risks

| Risk | Mitigation |
| --- | --- |
| **`databaseKey` is shared across devices via sync.** | Harmless today (each device has its own DB). Acknowledged in the doc. PR #802 splits this properly later. |
| **User has iCloud Keychain disabled.** | Item lives in the synced slot but doesn't propagate — i.e. degrades to current device-local behavior. We should surface "iCloud Keychain off" as a soft UI nudge somewhere (not in this PR). |
| **CKKS propagation latency.** | Typically <10 min, can be longer in pathological cases. Document as "may take a few minutes." |
| **Existing user re-installs the app.** | Identity is in iCloud Keychain — re-install picks it up automatically, same Account on backend. ✅ This is the headline win. |
| **User deletes the app on all devices.** | iCloud Keychain retains the item per Apple's retention policy. Reinstalling restores it. If they fully sign out before that, the slot is gone. |
| **Family Sharing / shared iCloud account.** | Out of scope. iCloud Keychain is per-iCloud-account; if two real users share an Apple ID, they share an identity. That's a product policy question. |

## Verification

After implementing, end-to-end:

1. Install app on **simulator A**. Sign in. Note the address + accountId in the Debug → SIWE Auth Probe screen.
2. Install on **simulator B with the same Apple ID** (or a real second device).
3. After a few minutes, open Convos on B — Debug → SIWE Auth Probe should show the **same address and accountId** without any onboarding step.
4. Run `SELECT … FROM "AuthMethod" WHERE type = 'SIWE'` on the backend — exactly one row, one Account, two devices behind it.
5. Sign out on A — confirm both slots cleared on A, but B's still has the identity (until B signs out separately).

## Out of scope / future work (link forward)

- **Backup bundles** (PR #802): adds an encrypted archive of XMTP DB state so a restored device picks up message history. Independent of this PR but compatible.
- **BIP-39 mnemonic export**: for users who want a non-iCloud backup. Builds on this PR's `KeychainIdentityKeys` by exposing a "show seed phrase" sheet.
- **Per-installation key separation**: split the per-device `databaseKey` out of `KeychainIdentityKeys` and keep only the owner key in the synced slot. PR #802's two-key model.
- **Account-level multi-device linking**: an explicit "add this device" QR flow instead of relying on iCloud Keychain. Useful for users who don't have iCloud or want cross-platform.

## Estimated work

- `KeychainIdentityStore.swift` edits: ~40 LOC.
- Debug surface row: ~20 LOC.
- Tests: ~60 LOC.
- Doc updates: ~30 LOC.

Single engineer, ~1 day including review-cycle. Behavior change is large; code change is small.
