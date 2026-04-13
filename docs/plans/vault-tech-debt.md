# Vault Tech Debt Recovery

Tasks to clean up the Convos Vault implementation, ordered by dependency.

## Task List

### 1. Remove unused delegate methods from VaultManagerDelegate
- Remove `didImportKey`, `didRemoveDevice`, `didEncounterError` — no consumers
- Keep only `didReceivePairingJoinRequest` (used by UI bridge)
- Remove default no-op implementations for removed methods
- Update VaultClient delegate conformance in VaultManager accordingly

### 2. Consolidate notification names
- Move all vault notification names into one `Notification.Name` extension in `VaultServiceProtocol.swift`
- Remove the scattered extension in `VaultClient.swift`
- Verify all consumers still compile

### 3. Deduplicate vault group selection logic
- Extract `selectBestVaultGroup(from groups:, cleanup:)` in VaultClient
- Used by both `findOrCreateVaultGroup` and `resyncVaultGroup`
- Handles member-count comparison + orphan cleanup in one place

### 4. Convert VaultClient from `@unchecked Sendable` to actor
- Replace `OSAllocatedUnfairLock<VaultClientInternalState>` with actor isolation
- Migrate `state`, `client`, `group` to actor-isolated properties
- Update streaming to work with actor (stream tasks launched from actor context)
- Update all call sites in VaultManager (already an actor, so `await` is natural)
- Keep lifecycle observation working (NotificationCenter async sequences)

### 5. Split VaultManager into focused internal helpers
- Keep VaultManager as the public coordinator (~200-300 lines)
- Extract `VaultKeySharing` — GRDB observation, shareKey, shareAllKeys, import logic
- Extract `VaultPairingInitiator` — createPairingInvite, DM stream, handleDmMessage, lock/unlock
- Extract `VaultPairingJoiner` — sendJoinRequest, joiner DM/poll, handleJoinerDmMessage
- Internal types, called by VaultManager, not exposed publicly

### 6. Unify duplicate model types
- Merge `InboxKeyInfo` and `VaultIdentityEntry` into one type
- Merge shared fields from `DeviceKeyBundleContent`/`DeviceKeyShareContent` into `DeviceKeyEntry`

### 7. Wire joiner completion transition
- JoinerPairingSheetViewModel observes `.vaultDidReceiveKeyBundle` notification
- On receipt: transition from pin display → syncing → completed
- Stop joiner DM stream + poll on completion
- Joiner polling uses `resyncVaultGroup()` to discover group (necessary — can't stream a group you haven't joined yet), then one-time message read + stream for new messages

### 8. Wire error feedback to joiner
- On pairing rejection (wrong pin, timeout), initiator calls `sendPairingError`
- Joiner's DM stream already handles `PAIRING_ERROR:` prefix
- Wire the initiator UI rejection flow to call `sendPairingError`

### 9. Write VaultManager integration tests
- Use local XMTP node (same pattern as InviteJoinRequestIntegrationTests)
- Test key sharing flow: create vault → add member → verify key bundle received
- Test deletion broadcast: send ConversationDeletedContent → verify received
- Test pairing invite creation + join request via DM
- Test GRDB observation: insert inbox → verify shareKey called

### 10. Lint + test + verify
- Run swiftlint, fix any violations from refactors
- Run full ConvosCore test suite (390+ tests)
- Build app to verify UI still compiles
