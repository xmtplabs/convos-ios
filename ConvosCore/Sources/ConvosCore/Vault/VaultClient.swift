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

public actor VaultClient {
    private var state: VaultClientState = .disconnected
    private var client: Client?
    private var group: XMTPiOS.Group?
    private var streamTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    public weak var delegate: (any VaultClientDelegate)?

    public func setDelegate(_ delegate: any VaultClientDelegate) {
        self.delegate = delegate
    }

    public var currentState: VaultClientState { state }
    public var inboxId: String? { client?.inboxID }
    public var installationId: String? { client?.installationID }
    public var vaultGroup: XMTPiOS.Group? { group }
    public var xmtpClient: Client? { client }

    public init() {}

    public func connect(
        signingKey: SigningKey,
        options: ClientOptions
    ) async throws {
        updateState(.connecting)

        let xmtpClient: Client
        do {
            xmtpClient = try await Client.build(
                publicIdentity: signingKey.identity,
                options: options,
                inboxId: nil
            )
        } catch {
            xmtpClient = try await Client.create(
                account: signingKey,
                options: options
            )
        }

        try await xmtpClient.conversations.sync()

        let vaultGroup = try await findOrCreateVaultGroup(client: xmtpClient)

        self.client = xmtpClient
        self.group = vaultGroup

        updateState(.connected)
        startStreaming(client: xmtpClient, group: vaultGroup)
        startLifecycleObservation()
    }

    public func disconnect() {
        stopLifecycleObservation()
        streamTask?.cancel()
        streamTask = nil
        client = nil
        group = nil
        updateState(.disconnected)
    }

    public func pause() {
        streamTask?.cancel()
        streamTask = nil
        try? client?.dropLocalDatabaseConnection()
    }

    public func resume() async {
        guard let client, let group else { return }

        try? await client.reconnectLocalDatabase()
        try? await client.conversations.sync()
        try? await group.sync()

        startStreaming(client: client, group: group)
    }

    public func send<T: Codable, C: ContentCodec>(
        _ content: sending T,
        codec: C
    ) async throws where C.T == T {
        guard let group else {
            throw VaultClientError.notConnected
        }

        _ = try await group.send(
            content: content,
            options: .init(contentType: codec.contentType)
        )
    }

    public func members() async throws -> sending [XMTPiOS.Member] {
        guard let group else {
            throw VaultClientError.notConnected
        }
        return try await group.members
    }

    public func addMember(inboxId: String) async throws {
        guard let group else {
            throw VaultClientError.notConnected
        }
        try await group.addMembers(inboxIds: [inboxId])
    }

    public func removeMember(inboxId: String) async throws {
        guard let group else {
            throw VaultClientError.notConnected
        }
        try await group.removeMembers(inboxIds: [inboxId])
    }

    public func vaultGroupMessages() async throws -> sending [DecodedMessage] {
        guard let group else {
            throw VaultClientError.notConnected
        }
        try await group.sync()
        return try await group.messages()
    }

    public func createArchive(path: String, encryptionKey: Data, opts: XMTPiOS.ArchiveOptions = ArchiveOptions()) async throws {
        guard let client else {
            throw VaultClientError.notConnected
        }
        try await client.createArchive(path: path, encryptionKey: encryptionKey, opts: opts)
    }

    public func importArchive(path: String, encryptionKey: Data) async throws {
        guard let client else {
            throw VaultClientError.notConnected
        }
        try await client.importArchive(path: path, encryptionKey: encryptionKey)
    }

    public func archiveMetadata(path: String, encryptionKey: Data) async throws -> XMTPiOS.ArchiveMetadata {
        guard let client else {
            throw VaultClientError.notConnected
        }
        return try await client.archiveMetadata(path: path, encryptionKey: encryptionKey)
    }

    public func resyncVaultGroup() async throws {
        guard let client else {
            throw VaultClientError.notConnected
        }

        try await client.conversations.sync()
        let vaultGroups = try filterVaultGroups(client: client)
        guard !vaultGroups.isEmpty else { return }

        let selectedGroup = try await selectBestVaultGroup(from: vaultGroups, cleanupOrphans: true)
        if selectedGroup.id != group?.id {
            group = selectedGroup
            startStreaming(client: client, group: selectedGroup)
        }
    }

    public func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm {
        guard let client else {
            throw VaultClientError.notConnected
        }
        return try await client.conversations.findOrCreateDm(with: inboxId)
    }

    public nonisolated func streamAllDmMessages() -> AsyncThrowingStream<DecodedMessage, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                guard let client = await self.client else {
                    continuation.finish(throwing: VaultClientError.notConnected)
                    return
                }
                let stream = client.conversations.streamAllMessages(type: .dms)
                do {
                    for try await message in stream {
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func findOrCreateVaultGroup(client: Client) async throws -> XMTPiOS.Group {
        let vaultGroups = try filterVaultGroups(client: client)

        if !vaultGroups.isEmpty {
            return try await selectBestVaultGroup(from: vaultGroups, cleanupOrphans: true)
        }

        let newGroup = try await client.conversations.newGroup(
            with: [],
            name: "Convos Vault",
            imageUrl: "",
            description: ""
        )

        var metadata: ConversationCustomMetadata = .init()
        metadata.conversationType = "vault"
        let appDataString = try metadata.toCompactString()
        try await newGroup.updateAppData(appData: appDataString)

        return newGroup
    }

    private func filterVaultGroups(client: Client) throws -> [XMTPiOS.Group] {
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
        return vaultGroups
    }

    private func selectBestVaultGroup(
        from vaultGroups: [XMTPiOS.Group],
        cleanupOrphans: Bool
    ) async throws -> XMTPiOS.Group {
        var memberCounts: [Int] = []
        for group in vaultGroups {
            memberCounts.append(try await group.members.count)
        }

        var bestIndex: Int = 0
        for i in 1 ..< memberCounts.count where memberCounts[i] > memberCounts[bestIndex] {
            bestIndex = i
        }

        if cleanupOrphans, memberCounts[bestIndex] > 1 {
            for (i, group) in vaultGroups.enumerated() where i != bestIndex && memberCounts[i] <= 1 {
                try? await group.leaveGroup()
                Log.info("Left orphaned solo vault group: \(group.id)")
            }
        }

        return vaultGroups[bestIndex]
    }

    private var lastStreamDate: Date?

    private func startStreaming(client: Client, group: XMTPiOS.Group) {
        streamTask?.cancel()
        let clientInboxId = client.inboxID
        streamTask = Task { [weak self] in
            guard let self else { return }
            var reconnectDelay: UInt64 = 1_000_000_000
            let maxDelay: UInt64 = 30_000_000_000

            while !Task.isCancelled {
                do {
                    try? await group.sync()
                    await self.processMissedMessages(group: group, clientInboxId: clientInboxId)
                    await self.updateLastStreamDate(Date())

                    for try await message in group.streamMessages() {
                        guard !Task.isCancelled else { return }
                        guard message.senderInboxId != clientInboxId else { continue }
                        await self.handleMessage(message)
                        await self.updateLastStreamDate(message.sentAt)
                        reconnectDelay = 1_000_000_000
                    }
                    guard !Task.isCancelled else { return }
                    Log.warning("Vault: stream ended naturally, reconnecting in \(reconnectDelay / 1_000_000_000)s")
                } catch {
                    guard !Task.isCancelled else { return }
                    Log.warning("Vault: stream error, reconnecting in \(reconnectDelay / 1_000_000_000)s: \(error)")
                }

                try? await Task.sleep(nanoseconds: reconnectDelay)
                reconnectDelay = min(reconnectDelay * 2, maxDelay)
            }
        }
    }

    private func updateLastStreamDate(_ date: Date) {
        lastStreamDate = date
    }

    private func processMissedMessages(group: XMTPiOS.Group, clientInboxId: String) async {
        guard let cutoff = lastStreamDate else { return }
        let cutoffNs = Int64(cutoff.timeIntervalSince1970 * 1_000_000_000)
        guard let messages = try? await group.messages(
            afterNs: cutoffNs,
            direction: .ascending
        ) else { return }
        let missed = messages.filter { $0.senderInboxId != clientInboxId }
        guard !missed.isEmpty else { return }
        Log.info("Vault: processing \(missed.count) missed message(s) after reconnect")
        for message in missed {
            handleMessage(message)
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
            await withTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask { [weak self] in
                    let stream = NotificationCenter.default.notifications(
                        named: .vaultDidEnterBackground
                    )
                    for await _ in stream {
                        await self?.pause()
                    }
                }

                taskGroup.addTask { [weak self] in
                    let stream = NotificationCenter.default.notifications(
                        named: .vaultWillEnterForeground
                    )
                    for await _ in stream {
                        await self?.resume()
                    }
                }

                await taskGroup.waitForAll()
            }
        }
    }

    private func stopLifecycleObservation() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    private func updateState(_ newState: VaultClientState) {
        state = newState
        delegate?.vaultClient(self, didChangeState: newState)
    }
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
