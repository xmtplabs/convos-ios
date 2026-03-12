# Vault Archive Backup Plan

## Scope

Add archive creation and import APIs to the vault. The import method returns all extracted key material so the caller can save it to the local keychain.

Another engineer handles:
- iCloud Keychain storage for the vault key
- Conversation archive creation/import
- Bundle orchestration
- Saving extracted keys to the local keychain

## API

### VaultManager

```swift
// Create an encrypted archive of the vault's XMTP database
func createArchive(at path: URL, encryptionKey: Data) async throws

// Import a vault archive, returning all conversation keys found in vault messages
@discardableResult
func importArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry]
```

### VaultKeyEntry

```swift
public struct VaultKeyEntry: Sendable, Equatable {
    public let inboxId: String
    public let clientId: String
    public let conversationId: String
    public let privateKeyData: Data
    public let databaseKey: Data
}
```

### VaultServiceProtocol

Both methods added to the protocol so the backup orchestrator can call them through the protocol.

## How It Works

### Backup creation
`createArchive` calls through `VaultClient` → `XMTPiOS.Client.createArchive`, producing an encrypted file at the given path containing all vault group messages (key bundles, key shares, deletions, etc.).

### Restore
`importArchive` does two things:
1. Calls `XMTPiOS.Client.importArchive` to restore vault group message history
2. Iterates all vault messages, extracts `DeviceKeyBundleContent` and `DeviceKeyShareContent`, and returns deduplicated `[VaultKeyEntry]` (keyed by inboxId, later messages win)

The caller receives the key entries and decides how to save them to the keychain.

### Post-import state
After importing the archive, the vault group's message history is available in the local database for key extraction. The restored device registers as a new installation under the same vault inbox (since it has the private key). The vault group reactivates once an existing member comes online and syncs, automatically adding the new installation. The user keeps their vault — new key shares will flow to this device going forward.

## Key extraction logic

- Processes bundles first, then shares
- Deduplicates by inboxId (last write wins)
- Shares processed after bundles, so a share for the same inboxId overwrites a bundle entry
- Extracted via `VaultManager.extractKeyEntries(bundles:shares:)` (static, tested independently)

## Files

### New
- `ConvosCore/Sources/ConvosCore/Vault/VaultKeyEntry.swift`
- `ConvosCore/Sources/ConvosCore/Vault/VaultManager+Archive.swift`
- `ConvosCore/Tests/ConvosCoreTests/VaultManagerArchiveTests.swift` (22 tests)

### Modified
- `ConvosCore/Sources/ConvosCore/Vault/VaultClient.swift` — added 3 archive pass-through methods
- `ConvosCore/Sources/ConvosCore/Vault/VaultServiceProtocol.swift` — added 2 archive methods to protocol
