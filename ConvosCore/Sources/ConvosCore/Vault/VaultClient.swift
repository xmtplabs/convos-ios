import ConvosAppData
import Foundation
import os
@preconcurrency import XMTPiOS

public enum VaultClientState: Sendable {
    case disconnected
    case connecting
    case connected
    case error(any Error)
}

public protocol VaultClientDelegate: AnyObject, Sendable {
    func vaultClient(_ client: VaultClient, didReceiveKeyBundle bundle: DeviceKeyBundleContent, from senderInboxId: String)
    func vaultClient(_ client: VaultClient, didReceiveKeyShare share: DeviceKeyShareContent, from senderInboxId: String)
    func vaultClient(_ client: VaultClient, didReceiveDeviceRemoved removal: DeviceRemovedContent, from senderInboxId: String)
    func vaultClient(_ client: VaultClient, didReceiveConversationDeleted deletion: ConversationDeletedContent, from senderInboxId: String)
    func vaultClient(_ client: VaultClient, didChangeState state: VaultClientState)
    func vaultClient(_ client: VaultClient, didEncounterError error: any Error)
}

public extension VaultClientDelegate {
    func vaultClient(_ client: VaultClient, didReceiveKeyBundle bundle: DeviceKeyBundleContent, from senderInboxId: String) {}
    func vaultClient(_ client: VaultClient, didReceiveKeyShare share: DeviceKeyShareContent, from senderInboxId: String) {}
    func vaultClient(_ client: VaultClient, didReceiveDeviceRemoved removal: DeviceRemovedContent, from senderInboxId: String) {}
    func vaultClient(_ client: VaultClient, didReceiveConversationDeleted deletion: ConversationDeletedContent, from senderInboxId: String) {}
    func vaultClient(_ client: VaultClient, didChangeState state: VaultClientState) {}
    func vaultClient(_ client: VaultClient, didEncounterError error: any Error) {}
}

private struct VaultClientInternalState: Sendable {
    var state: VaultClientState = .disconnected
    var client: Client?
    var group: XMTPiOS.Group?
}

public final class VaultClient: @unchecked Sendable {
    private let stateLock: OSAllocatedUnfairLock<VaultClientInternalState> = .init(initialState: .init())
    private var streamTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    public weak var delegate: (any VaultClientDelegate)?

    public var state: VaultClientState {
        stateLock.withLock { $0.state }
    }

    public var inboxId: String? {
        stateLock.withLock { $0.client?.inboxID }
    }

    public var installationId: String? {
        stateLock.withLock { $0.client?.installationID }
    }

    public init() {}

    public func connect(
        signingKey: SigningKey,
        options: ClientOptions
    ) async throws {
        updateState(.connecting)

        let client: Client
        do {
            client = try await Client.build(
                publicIdentity: signingKey.identity,
                options: options,
                inboxId: nil
            )
        } catch {
            client = try await Client.create(
                account: signingKey,
                options: options
            )
        }

        try await client.conversations.sync()

        let group = try await findOrCreateVaultGroup(client: client)

        stateLock.withLock {
            $0.client = client
            $0.group = group
        }

        updateState(.connected)
        startStreaming(client: client, group: group)
        startLifecycleObservation()
    }

    public func disconnect() {
        stopLifecycleObservation()
        streamTask?.cancel()
        streamTask = nil

        stateLock.withLock {
            $0.client = nil
            $0.group = nil
        }

        updateState(.disconnected)
    }

    public func pause() {
        streamTask?.cancel()
        streamTask = nil

        let client = stateLock.withLock { $0.client }
        try? client?.dropLocalDatabaseConnection()
    }

    public func resume() async {
        let (client, group) = stateLock.withLock { ($0.client, $0.group) }
        guard let client, let group else { return }

        try? await client.reconnectLocalDatabase()
        try? await client.conversations.sync()
        try? await group.sync()

        startStreaming(client: client, group: group)
    }

    public func send<T: Codable, C: ContentCodec>(
        _ content: T,
        codec: C
    ) async throws where C.T == T {
        guard let group = stateLock.withLock({ $0.group }) else {
            throw VaultClientError.notConnected
        }

        _ = try await group.send(
            content: content,
            options: .init(contentType: codec.contentType)
        )
    }

    public func members() async throws -> [XMTPiOS.Member] {
        guard let group = stateLock.withLock({ $0.group }) else {
            throw VaultClientError.notConnected
        }
        return try await group.members
    }

    public func addMember(inboxId: String) async throws {
        guard let group = stateLock.withLock({ $0.group }) else {
            throw VaultClientError.notConnected
        }
        try await group.addMembers(inboxIds: [inboxId])
    }

    public func removeMember(inboxId: String) async throws {
        guard let group = stateLock.withLock({ $0.group }) else {
            throw VaultClientError.notConnected
        }
        try await group.removeMembers(inboxIds: [inboxId])
    }

    public func vaultGroupMessages() async throws -> [DecodedMessage] {
        guard let group = stateLock.withLock({ $0.group }) else {
            throw VaultClientError.notConnected
        }
        try await group.sync()
        return try await group.messages()
    }

    public var vaultGroup: XMTPiOS.Group? {
        stateLock.withLock { $0.group }
    }

    public func resyncVaultGroup() async throws {
        guard let client = stateLock.withLock({ $0.client }) else {
            throw VaultClientError.notConnected
        }

        try await client.conversations.sync()

        let groups = try client.conversations.listGroups(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityAfterNs: nil,
            lastActivityBeforeNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .createdAt
        )

        var vaultGroups: [XMTPiOS.Group] = []
        for group in groups {
            let appData = try group.appData()
            let metadata = ConversationCustomMetadata.parseAppData(appData)
            if metadata.hasConversationType && metadata.conversationType == "vault" {
                vaultGroups.append(group)
            }
        }

        guard !vaultGroups.isEmpty else { return }

        var memberCounts: [Int] = []
        for group in vaultGroups {
            memberCounts.append(try await group.members.count)
        }

        var bestIndex: Int = 0
        for i in 1 ..< memberCounts.count where memberCounts[i] > memberCounts[bestIndex] {
            bestIndex = i
        }

        let selectedGroup = vaultGroups[bestIndex]
        let currentGroup = stateLock.withLock { $0.group }
        if selectedGroup.id != currentGroup?.id {
            stateLock.withLock { $0.group = selectedGroup }
            startStreaming(client: client, group: selectedGroup)
        }

        if memberCounts[bestIndex] > 1 {
            for (i, group) in vaultGroups.enumerated() where i != bestIndex && memberCounts[i] <= 1 {
                try? await group.leaveGroup()
                Log.info("Left orphaned solo vault group: \(group.id)")
            }
        }
    }

    public var xmtpClient: Client? {
        stateLock.withLock { $0.client }
    }

    public func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm {
        guard let client = stateLock.withLock({ $0.client }) else {
            throw VaultClientError.notConnected
        }
        return try await client.conversations.findOrCreateDm(with: inboxId)
    }

    public func streamAllDmMessages() -> AsyncThrowingStream<DecodedMessage, Error> {
        guard let client = stateLock.withLock({ $0.client }) else {
            return AsyncThrowingStream { $0.finish(throwing: VaultClientError.notConnected) }
        }
        return client.conversations.streamAllMessages(type: .dms)
    }

    private func findOrCreateVaultGroup(client: Client) async throws -> XMTPiOS.Group {
        let groups = try client.conversations.listGroups(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityAfterNs: nil,
            lastActivityBeforeNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .createdAt
        )

        var vaultGroups: [XMTPiOS.Group] = []
        for group in groups {
            let appData = try group.appData()
            let metadata = ConversationCustomMetadata.parseAppData(appData)
            if metadata.hasConversationType && metadata.conversationType == "vault" {
                vaultGroups.append(group)
            }
        }

        if !vaultGroups.isEmpty {
            var bestIndex: Int = 0
            var bestCount = try await vaultGroups[0].members.count
            for i in 1 ..< vaultGroups.count {
                let count = try await vaultGroups[i].members.count
                if count > bestCount {
                    bestIndex = i
                    bestCount = count
                }
            }
            if bestCount > 1 {
                for (i, group) in vaultGroups.enumerated() where i != bestIndex {
                    let count = try await group.members.count
                    if count <= 1 {
                        try? await group.leaveGroup()
                        Log.info("Left orphaned solo vault group at bootstrap: \(group.id)")
                    }
                }
            }
            return vaultGroups[bestIndex]
        }

        let group = try await client.conversations.newGroup(
            with: [],
            name: "Convos Vault",
            imageUrl: "",
            description: ""
        )

        var metadata: ConversationCustomMetadata = .init()
        metadata.conversationType = "vault"
        let appDataString = try metadata.toCompactString()
        try await group.updateAppData(appData: appDataString)

        return group
    }

    private func startStreaming(client: Client, group: XMTPiOS.Group) {
        streamTask?.cancel()
        let clientInboxId = client.inboxID
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in group.streamMessages() {
                    guard !Task.isCancelled else { break }
                    guard message.senderInboxId != clientInboxId else { continue }
                    self.handleMessage(message)
                }
            } catch {
                if !Task.isCancelled {
                    self.delegate?.vaultClient(self, didEncounterError: error)
                    self.updateState(.error(error))
                }
            }
        }
    }

    private func handleMessage(_ message: DecodedMessage) {
        guard let contentType = try? message.encodedContent.type else { return }

        if contentType == ContentTypeDeviceKeyBundle {
            guard let bundle: DeviceKeyBundleContent = try? message.content() else { return }
            delegate?.vaultClient(self, didReceiveKeyBundle: bundle, from: message.senderInboxId)
        } else if contentType == ContentTypeDeviceKeyShare {
            guard let share: DeviceKeyShareContent = try? message.content() else { return }
            delegate?.vaultClient(self, didReceiveKeyShare: share, from: message.senderInboxId)
        } else if contentType == ContentTypeDeviceRemoved {
            guard let removal: DeviceRemovedContent = try? message.content() else { return }
            delegate?.vaultClient(self, didReceiveDeviceRemoved: removal, from: message.senderInboxId)
        } else if contentType == ContentTypeConversationDeleted {
            guard let deletion: ConversationDeletedContent = try? message.content() else { return }
            delegate?.vaultClient(self, didReceiveConversationDeleted: deletion, from: message.senderInboxId)
        }
    }

    private func startLifecycleObservation() {
        stopLifecycleObservation()

        lifecycleTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    let stream = NotificationCenter.default.notifications(
                        named: .vaultDidEnterBackground
                    )
                    for await _ in stream {
                        self?.pause()
                    }
                }

                group.addTask { [weak self] in
                    let stream = NotificationCenter.default.notifications(
                        named: .vaultWillEnterForeground
                    )
                    for await _ in stream {
                        await self?.resume()
                    }
                }

                await group.waitForAll()
            }
        }
    }

    private func stopLifecycleObservation() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    private func updateState(_ newState: VaultClientState) {
        stateLock.withLock { $0.state = newState }
        delegate?.vaultClient(self, didChangeState: newState)
    }
}

public extension Notification.Name {
    static let vaultDidEnterBackground: Notification.Name = .init("ConvosVaultDidEnterBackground")
    static let vaultWillEnterForeground: Notification.Name = .init("ConvosVaultWillEnterForeground")
    static let vaultDidReceiveKeyBundle: Notification.Name = .init("ConvosVaultDidReceiveKeyBundle")
    static let vaultPairingError: Notification.Name = .init("ConvosVaultPairingError")
}

public enum VaultClientError: Error, LocalizedError {
    case notConnected
    case vaultGroupNotFound

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Vault client is not connected"
        case .vaultGroupNotFound:
            return "Vault group conversation not found"
        }
    }
}
