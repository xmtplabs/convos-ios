import Foundation

/// App-injected wipe steps for state that lives above ConvosCore: StoreKit
/// defaults (the `appAccountToken` binding and cached subscription state),
/// the analytics identity (derived from the inbox id), and app-target UI
/// defaults. Registered once at app startup via
/// `SessionManager.setAccountDeletionAppHooks`; unset hooks surface as
/// missing-handler wipe failures rather than silent skips.
public struct AccountDeletionAppHooks: Sendable {
    public var wipeStoreKitState: @Sendable () async throws -> Void
    public var resetAnalyticsIdentity: @Sendable () async throws -> Void
    public var wipeUserInterfaceDefaults: @Sendable () async throws -> Void

    public init(
        wipeStoreKitState: @escaping @Sendable () async throws -> Void,
        resetAnalyticsIdentity: @escaping @Sendable () async throws -> Void,
        wipeUserInterfaceDefaults: @escaping @Sendable () async throws -> Void
    ) {
        self.wipeStoreKitState = wipeStoreKitState
        self.resetAnalyticsIdentity = resetAnalyticsIdentity
        self.wipeUserInterfaceDefaults = wipeUserInterfaceDefaults
    }
}

/// Thrown by the keychain-identity wipe step when the iCloud-synchronizable
/// backup item is still present after delete-and-retry. Surfacing it keeps
/// the record in `localWipePending` so the next launch retries, instead of
/// silently assuming the private key left iCloud.
public struct SyncedBackupRemovalIncompleteError: Error, Equatable {
    public init() {}
}

// MARK: - Account deletion flow

extension SessionManager {
    /// Current durable deletion state; drives the settings pending-retry
    /// row and completion UI.
    public func accountDeletionStatus() -> AccountDeletionLoadResult {
        accountDeletionStore.load()
    }

    public func setAccountDeletionAppHooks(_ hooks: AccountDeletionAppHooks) {
        accountDeletionAppHooks.withLock { $0 = hooks }
    }

    /// Deletes the account: durable record first, backend deletion while
    /// the identity keys still exist, best-effort installation revocation,
    /// then the manifest-driven local wipe. On success the app is
    /// equivalent to a first install; the next messaging-service access
    /// registers a fresh identity.
    public func deleteAccountWithProgress() -> AsyncThrowingStream<AccountDeletionProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.accountDeletionService().deleteAccount { progress in
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Paired-device exit for the account-deleted terminal state: the
    /// backend already deleted the account from another device, so this
    /// runs the local wipe only (a `backendConfirmed` record is written
    /// first so a crash mid-wipe resumes).
    public func wipeAfterRemoteAccountDeletion() async throws {
        try await accountDeletionService().wipeAfterRemoteDeletion()
    }

    /// Launch-time recovery for a deletion interrupted by a crash or kill;
    /// runs before any session bootstrap work (see `init`).
    func recoverPendingAccountDeletionIfNeeded() async {
        if case .none = accountDeletionStore.load() {
            return
        }
        await accountDeletionService().recoverAtLaunch()
    }

    /// Single shared instance: launch recovery, UI retries, and the
    /// remote-deletion wipe must funnel into one single-flight actor so two
    /// runs can never interleave on the same durable record.
    func accountDeletionService() -> AccountDeletionService {
        accountDeletionServiceLock.withLock { existing in
            if let existing { return existing }
            let service = AccountDeletionService(
                store: accountDeletionStore,
                dependencies: makeAccountDeletionDependencies()
            )
            existing = service
            return service
        }
    }

    // MARK: - Dependency wiring

    private func makeAccountDeletionDependencies() -> AccountDeletionDependencies {
        AccountDeletionDependencies(
            loadIdentity: { [identityStore] in
                try identityStore.loadSync()
            },
            deviceId: {
                DeviceInfo.deviceIdentifier
            },
            ethAddress: { identity in
                BackendAuthSigningContext.make(from: identity.keys.privateKey).address.lowercased()
            },
            mintToken: { [apiClient] identity in
                let signing = BackendAuthSigningContext.make(from: identity.keys.privateKey)
                let appCheckToken = try await FirebaseHelperCore.getAppCheckToken()
                return try await apiClient.authenticateWithSIWE(appCheckToken: appCheckToken, signing: signing)
            },
            cachedToken: { record in
                let slot = KeychainAccount.siweJwt(deviceId: record.deviceId, address: record.ethAddress)
                guard let token = try? KeychainService().retrieveString(account: slot), !token.isEmpty else {
                    return nil
                }
                return token
            },
            requestDeletion: { [apiClient] operationId, jwt in
                try await apiClient.deleteAccount(operationId: operationId, jwt: jwt)
            },
            setReauthSuspended: { [apiClient] suspended in
                apiClient.setAutomaticReauthSuspended(suspended)
            },
            revokeInstallations: { [weak self] record in
                await self?.revokeInstallationsBestEffort(record: record)
            },
            stopServices: { [weak self] in
                guard let self else { return }
                do {
                    try await self.tearDownInbox()
                } catch {
                    Log.error("AccountDeletion: live-service teardown failed; wipe manifest continues: \(error)")
                }
            },
            makeWipeExecutor: { [weak self] in
                self?.makeAccountDeletionWipeExecutor() ?? WipeManifestExecutor(handlers: [:])
            },
            sweepRecordScopedSlots: { [identityStore] record in
                // Only slots the record itself names: safe when the live
                // identity is a different (displaced) one.
                let keychain = KeychainService()
                try? keychain.delete(account: KeychainAccount.siweJwt(deviceId: record.deviceId, address: record.ethAddress))
                try? keychain.delete(account: KeychainAccount.siweAccountId(deviceId: record.deviceId, address: record.ethAddress))
                if !record.inboxId.isEmpty {
                    try? await identityStore.deleteSyncedBackup(inboxId: record.inboxId)
                }
            }
        )
    }

    /// Best-effort XMTP protocol teardown between `backendConfirmed` and
    /// the keychain wipe: revoke every other installation, then the
    /// deleting device's own installation last, so the inbox can no longer
    /// send or receive anywhere. Requires a live (ready or backgrounded)
    /// session; a wipe-resume without one skips revocation — disclosed in
    /// the confirmation copy as best-effort. Soft-bounded: a step is not
    /// started past the time budget.
    private func revokeInstallationsBestEffort(record: AccountDeletionRecord) async {
        guard let service = cachedMessagingService.withLock({ $0 }) else {
            Log.warning("AccountDeletion: no live session; skipping best-effort installation revocation")
            return
        }
        let client: AnyClientProvider
        switch service.sessionStateManager.currentState {
        case .ready(let result), .backgrounded(let result):
            client = result.client
        default:
            Log.warning("AccountDeletion: session not ready; skipping best-effort installation revocation")
            return
        }
        guard let identity = try? identityStore.loadSync(), identity.inboxId == client.inboxId else {
            Log.warning("AccountDeletion: identity missing or mismatched; skipping installation revocation")
            return
        }
        let deadline = Date().addingTimeInterval(Constant.revocationBudget)
        do {
            let installations = try await client.listInstallations(refreshFromNetwork: true)
            let otherIds: [String] = installations.map(\.id).filter { $0 != client.installationId }
            if !otherIds.isEmpty, Date() < deadline {
                try await client.revokeInstallations(
                    signingKey: identity.keys.signingKey,
                    installationIds: otherIds
                )
                Log.info("AccountDeletion: revoked \(otherIds.count) other installation(s)")
            }
            if Date() < deadline {
                try await client.revokeInstallations(
                    signingKey: identity.keys.signingKey,
                    installationIds: [client.installationId]
                )
                Log.info("AccountDeletion: revoked this device's installation")
            } else {
                Log.warning("AccountDeletion: revocation budget exhausted before self-revocation; continuing to wipe")
            }
        } catch {
            Log.warning("AccountDeletion: best-effort installation revocation failed; continuing to wipe: \(error)")
        }
    }

    // MARK: - Wipe manifest handlers

    /// Builds the executor with every manifest entry ConvosCore owns; the
    /// StoreKit / analytics / UI-defaults entries come from the app hooks
    /// and count as missing-handler failures until the app registers them.
    func makeAccountDeletionWipeExecutor() -> WipeManifestExecutor {
        var handlers: [WipeManifestEntry: WipeStep] = [:]

        handlers[.xmtpLocalDatabase] = WipeStep { [environment] _ in
            // Throwing: a leftover artifact fails the entry so the record
            // stays and the next launch retries, instead of clearing the
            // durable record over surviving database files. The XMTP and
            // application log directories carry inbox identifiers, so
            // they go too.
            try XMTPDatabaseFileSweeper.sweep(directory: environment.defaultDatabasesDirectoryURL)
            for directory in AccountDeletionWipeSteps.logDirectoriesToSweep(environment: environment) {
                try XMTPDatabaseFileSweeper.sweepContents(of: directory)
            }
        }

        handlers[.keychainIdentityFamily] = WipeStep { [identityStore, environment] record in
            try await AccountDeletionWipeSteps.wipeKeychainIdentityFamily(
                identityStore: identityStore,
                record: record
            )
            // Historical identity services (pre-v3 and v4-local), local and
            // iCloud-synced copies. The generation-bump sweep is one-shot
            // and best-effort; the manifest variant throws so failures
            // retry. The current v3 family is deliberately excluded here:
            // its synced-backup service holds other identities' backups,
            // which the scoped deletes above must not touch.
            try LegacyDataWipe.wipeLegacyIdentityKeychainServices(
                accessGroup: AccountDeletionWipeSteps.legacyIdentitySweepAccessGroup(environment: environment)
            )
        }

        handlers[.siweJwtSlot] = WipeStep { record in
            try AccountDeletionWipeSteps.wipeSiweJwtSlot(record: record)
        }

        handlers[.siweAccountIdSlot] = WipeStep { record in
            try AccountDeletionWipeSteps.wipeSiweAccountIdSlot(record: record)
        }

        handlers[.legacyJwtSlot] = WipeStep { record in
            try AccountDeletionWipeSteps.wipeLegacyJwtSlot(record: record)
        }

        handlers[.databaseRows] = WipeStep { [databaseWriter] _ in
            try await AccountDeletionWipeSteps.wipeDatabaseRows(databaseWriter: databaseWriter)
        }

        handlers[.deviceRegistrationDefaults] = WipeStep { [platformProviders] _ in
            DeviceRegistrationManager.clearRegistrationState(deviceInfo: platformProviders.deviceInfo)
        }

        handlers[.imageCaches] = WipeStep { _ in
            // Awaited and throwing: the fire-and-forget variant would let
            // the record clear before the disk sweep finished, so a crash
            // in that window would leave cached images with no rerun.
            try await AccountDeletionWipeSteps.wipeImageCaches()
        }

        handlers[.appGroupPairingStores] = WipeStep { [environment] _ in
            AccountDeletionDefaultsSweeper.sweepAppGroupStores(appGroupIdentifier: environment.appGroupIdentifier)
        }

        if let hooks = accountDeletionAppHooks.withLock({ $0 }) {
            handlers[.storeKitDefaults] = WipeStep { _ in try await hooks.wipeStoreKitState() }
            handlers[.analyticsIdentity] = WipeStep { _ in try await hooks.resetAnalyticsIdentity() }
            handlers[.userInterfaceDefaults] = WipeStep { _ in try await hooks.wipeUserInterfaceDefaults() }
        }

        return WipeManifestExecutor(handlers: handlers)
    }

    private enum Constant {
        /// Soft budget for the best-effort revocation step; a call is not
        /// started once the budget is spent.
        static let revocationBudget: TimeInterval = 15
    }
}
