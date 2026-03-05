import ConvosAppData
import Foundation
import os
@preconcurrency import XMTPiOS

public struct VaultDevice: Sendable {
    public let inboxId: String
    public let name: String
    public let isCurrentDevice: Bool

    public init(inboxId: String, name: String, isCurrentDevice: Bool) {
        self.inboxId = inboxId
        self.name = name
        self.isCurrentDevice = isCurrentDevice
    }
}

public protocol VaultIdentityStoreProtocol: Actor {
    func generateKeys() throws -> VaultIdentityKeys
    func allIdentities() throws -> [VaultIdentityEntry]
    func save(entry: VaultIdentityEntry) throws
    func hasIdentity(for inboxId: String) -> Bool
}

public struct VaultIdentityKeys: Codable, Sendable {
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(privateKeyData: Data, databaseKey: Data) {
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}

public struct VaultIdentityEntry: Codable, Sendable {
    public let conversationId: String
    public let inboxId: String
    public let clientId: String
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(
        conversationId: String,
        inboxId: String,
        clientId: String,
        privateKeyData: Data,
        databaseKey: Data
    ) {
        self.conversationId = conversationId
        self.inboxId = inboxId
        self.clientId = clientId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}

public protocol VaultManagerDelegate: AnyObject, Sendable {
    func vaultManager(_ manager: VaultManager, didImportKey entry: VaultIdentityEntry)
    func vaultManager(_ manager: VaultManager, didRemoveDevice inboxId: String)
    func vaultManager(_ manager: VaultManager, didEncounterError error: any Error)
}

public extension VaultManagerDelegate {
    func vaultManager(_ manager: VaultManager, didImportKey entry: VaultIdentityEntry) {}
    func vaultManager(_ manager: VaultManager, didRemoveDevice inboxId: String) {}
    func vaultManager(_ manager: VaultManager, didEncounterError error: any Error) {}
}

public final class VaultManager: @unchecked Sendable {
    private let vaultClient: VaultClient
    private let identityStore: any VaultIdentityStoreProtocol
    private let deviceName: String
    private let memberCountLock: OSAllocatedUnfairLock<Int> = .init(initialState: 1)

    public weak var delegate: (any VaultManagerDelegate)?

    public var isConnected: Bool {
        if case .connected = vaultClient.state { return true }
        return false
    }

    public var hasMultipleDevices: Bool {
        memberCountLock.withLock { $0 > 1 }
    }

    public var vaultInboxId: String? {
        vaultClient.inboxId
    }

    public init(
        identityStore: any VaultIdentityStoreProtocol,
        deviceName: String
    ) {
        self.vaultClient = VaultClient()
        self.identityStore = identityStore
        self.deviceName = deviceName
        self.vaultClient.delegate = self
    }

    public func connect(signingKey: SigningKey, options: ClientOptions) async throws {
        try await vaultClient.connect(signingKey: signingKey, options: options)
        await refreshMemberCount()
    }

    public func disconnect() {
        vaultClient.disconnect()
    }

    public func pause() {
        vaultClient.pause()
    }

    public func resume() async {
        await vaultClient.resume()
        await refreshMemberCount()
    }

    public func shareKey(_ entry: VaultIdentityEntry) async throws {
        guard let installationId = vaultClient.installationId else {
            throw VaultClientError.notConnected
        }

        let share = DeviceKeyShareContent(
            conversationId: entry.conversationId,
            inboxId: entry.inboxId,
            clientId: entry.clientId,
            privateKeyData: entry.privateKeyData,
            databaseKey: entry.databaseKey,
            senderInstallationId: installationId
        )

        try await vaultClient.send(share, codec: DeviceKeyShareCodec())
    }

    public func shareAllKeys() async throws {
        guard let installationId = vaultClient.installationId else {
            throw VaultClientError.notConnected
        }

        let identities = try await identityStore.allIdentities()
        let keys = identities.map { entry in
            DeviceKeyEntry(
                conversationId: entry.conversationId,
                inboxId: entry.inboxId,
                clientId: entry.clientId,
                privateKeyData: entry.privateKeyData,
                databaseKey: entry.databaseKey
            )
        }

        let bundle = DeviceKeyBundleContent(
            keys: keys,
            senderInstallationId: installationId
        )

        try await vaultClient.send(bundle, codec: DeviceKeyBundleCodec())
    }

    public func listDevices() async throws -> [VaultDevice] {
        let members = try await vaultClient.members()
        let currentInboxId = vaultClient.inboxId

        return members.map { member in
            VaultDevice(
                inboxId: member.inboxId,
                name: member.inboxId == currentInboxId ? deviceName : member.inboxId,
                isCurrentDevice: member.inboxId == currentInboxId
            )
        }
    }

    public func removeDevice(inboxId: String) async throws {
        let removal = DeviceRemovedContent(
            removedInboxId: inboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        try await vaultClient.removeMember(inboxId: inboxId)
        await refreshMemberCount()
    }

    public func unpairSelf() async throws {
        guard let selfInboxId = vaultInboxId else {
            throw VaultClientError.notConnected
        }

        let removal = DeviceRemovedContent(
            removedInboxId: selfInboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        vaultClient.disconnect()
    }

    private func refreshMemberCount() async {
        let count = (try? await vaultClient.members().count) ?? 1
        memberCountLock.withLock { $0 = count }
    }

    private func importKeyShare(_ share: DeviceKeyShareContent) async {
        let entry = VaultIdentityEntry(
            conversationId: share.conversationId,
            inboxId: share.inboxId,
            clientId: share.clientId,
            privateKeyData: share.privateKeyData,
            databaseKey: share.databaseKey
        )

        let alreadyExists = await identityStore.hasIdentity(for: share.inboxId)
        guard !alreadyExists else { return }

        do {
            try await identityStore.save(entry: entry)
            delegate?.vaultManager(self, didImportKey: entry)
        } catch {
            delegate?.vaultManager(self, didEncounterError: error)
        }
    }

    private func importKeyBundle(_ bundle: DeviceKeyBundleContent) async {
        for key in bundle.keys {
            let entry = VaultIdentityEntry(
                conversationId: key.conversationId,
                inboxId: key.inboxId,
                clientId: key.clientId,
                privateKeyData: key.privateKeyData,
                databaseKey: key.databaseKey
            )

            let alreadyExists = await identityStore.hasIdentity(for: key.inboxId)
            guard !alreadyExists else { continue }

            do {
                try await identityStore.save(entry: entry)
                delegate?.vaultManager(self, didImportKey: entry)
            } catch {
                delegate?.vaultManager(self, didEncounterError: error)
            }
        }
    }
}

extension VaultManager: VaultClientDelegate {
    public func vaultClient(_ client: VaultClient, didReceiveKeyBundle bundle: DeviceKeyBundleContent, from senderInboxId: String) {
        Task { await importKeyBundle(bundle) }
    }

    public func vaultClient(_ client: VaultClient, didReceiveKeyShare share: DeviceKeyShareContent, from senderInboxId: String) {
        Task { await importKeyShare(share) }
    }

    public func vaultClient(_ client: VaultClient, didReceiveDeviceRemoved removal: DeviceRemovedContent, from senderInboxId: String) {
        delegate?.vaultManager(self, didRemoveDevice: removal.removedInboxId)
    }

    public func vaultClient(_ client: VaultClient, didChangeState state: VaultClientState) {}

    public func vaultClient(_ client: VaultClient, didEncounterError error: any Error) {
        delegate?.vaultManager(self, didEncounterError: error)
    }
}
