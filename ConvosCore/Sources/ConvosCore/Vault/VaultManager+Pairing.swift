import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

// MARK: - Pairing (Initiator - Device A)

extension VaultManager {
    public func createPairingInvite(expiresAt: Date) async throws -> String {
        guard let group = await vaultClient.vaultGroup else { throw PairingError.noVaultGroup }
        guard let client = await vaultClient.xmtpClient, let vaultInboxId = await vaultInboxId, let vaultKeyStore else {
            throw VaultClientError.notConnected
        }

        let identity = try await vaultKeyStore.load(inboxId: vaultInboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        try await group.ensureInviteTag()

        let coordinator = InviteCoordinator(
            privateKeyProvider: { _ in privateKey },
            tagStorage: ProtobufInviteTagStorage()
        )

        let adapter = VaultInviteClientAdapter(client: client)
        let result = try await coordinator.createInvite(
            for: group,
            client: adapter,
            options: InviteOptions(expiresAt: expiresAt, singleUse: true)
        )

        activePairingSlug = result.slug
        startDmStream()
        return result.slug
    }

    public func lockVault() async {
        guard let group = await vaultClient.vaultGroup else { return }
        try? await group.clearInviteTag()
    }

    public func stopPairing() async {
        dmStreamTask?.cancel()
        dmStreamTask = nil
        if activePairingSlug != nil {
            activePairingSlug = nil
            await lockVault()
        }
    }

    public func sendPinToJoiner(_ pin: String, joinerInboxId: String) async throws {
        let dm = try await vaultClient.findOrCreateDm(with: joinerInboxId)
        _ = try await dm.send(
            content: PairingMessageContent.pin(pin),
            options: SendOptions(contentType: ContentTypePairingMessage)
        )
    }

    func startDmStream() {
        dmStreamTask?.cancel()
        dmStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.vaultClient.streamAllDmMessages()
                for try await message in stream {
                    guard !Task.isCancelled else { break }
                    await self.handleDmMessage(message)
                }
            } catch {
                if !Task.isCancelled {
                    Log.error("Vault: DM stream error: \(error)")
                }
            }
        }
    }

    func handleDmMessage(_ message: DecodedMessage) async {
        guard let vaultInboxId = await vaultInboxId, message.senderInboxId != vaultInboxId else {
            return
        }

        if let activePairingSlug {
            var request: PairingJoinRequest?

            if let joinRequest: JoinRequestContent = try? message.content(),
               joinRequest.inviteSlug == activePairingSlug {
                let name = joinRequest.metadata?["deviceName"] ?? "Unknown device"
                request = PairingJoinRequest(
                    pin: "",
                    deviceName: name,
                    joinerInboxId: message.senderInboxId
                )
            } else if let text: String = try? message.content(),
                      text == activePairingSlug {
                request = PairingJoinRequest(pin: "", deviceName: "Unknown device", joinerInboxId: message.senderInboxId)
            }

            if let request {
                pendingPeerDeviceNames[request.joinerInboxId] = request.deviceName
                await lockVault()
                self.activePairingSlug = nil

                delegate?.vaultManager(self, didReceivePairingJoinRequest: request)
                return
            }
        }

        if let pairing: PairingMessageContent = try? message.content(),
           pairing.type == .pinEcho {
            delegate?.vaultManager(self, didReceivePinEcho: pairing.payload, from: message.senderInboxId)
        }
    }

    public func sendPairingError(to joinerInboxId: String, message: String) async {
        do {
            let dm = try await vaultClient.findOrCreateDm(with: joinerInboxId)
            _ = try await dm.send(
                content: PairingMessageContent.error(message),
                options: SendOptions(contentType: ContentTypePairingMessage)
            )
        } catch {
            Log.error("Failed to send pairing error to joiner: \(error)")
        }
    }
}

// MARK: - Pairing (Joiner - Device B)

extension VaultManager {
    public func sendPairingJoinRequest(
        slug: String,
        deviceName: String
    ) async throws {
        guard let client = await vaultClient.xmtpClient else {
            throw VaultClientError.notConnected
        }

        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(slug) else {
            throw PairingError.invalidInviteSlug
        }

        let adapter = VaultInviteClientAdapter(client: client)
        let coordinator = InviteCoordinator(
            privateKeyProvider: { _ in Data() },
            tagStorage: ProtobufInviteTagStorage()
        )

        _ = try await coordinator.sendJoinRequest(
            for: signedInvite,
            client: adapter,
            metadata: [
                "deviceName": deviceName,
            ]
        )
        startJoinerDmStream()
    }

    public func sendPinEcho(_ pin: String, to initiatorInboxId: String) async throws {
        let dm = try await vaultClient.findOrCreateDm(with: initiatorInboxId)
        _ = try await dm.send(
            content: PairingMessageContent.pinEcho(pin),
            options: SendOptions(contentType: ContentTypePairingMessage)
        )
    }

    private static let joinerPollInterval: TimeInterval = 3
    private static let joinerPollMaxDuration: TimeInterval = 120

    func startJoinerDmStream() {
        joinerDmStreamTask?.cancel()
        joinerDmStreamTask = Task { [weak self] in
            guard let self else { return }

            async let dmStream: Void = {
                do {
                    let stream = await self.vaultClient.streamAllDmMessages()
                    for try await message in stream {
                        guard !Task.isCancelled else { break }
                        await self.handleJoinerDmMessage(message)
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.error("Joiner DM stream error: \(error)")
                    }
                }
            }()

            async let vaultPoll: Void = {
                let deadline = Date().addingTimeInterval(Self.joinerPollMaxDuration)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(for: .seconds(Self.joinerPollInterval))
                    guard !Task.isCancelled else { break }
                    do {
                        try await self.vaultClient.resyncVaultGroup()
                        let messages = try await self.vaultClient.vaultGroupMessages()
                        for message in messages {
                            if let bundle: DeviceKeyBundleContent = try? message.content(),
                               !bundle.keys.isEmpty {
                                await self.importKeyBundle(bundle)
                                return
                            }
                        }
                    } catch {
                        continue
                    }
                }
                if !Task.isCancelled {
                    Log.warning("Joiner vault poll timed out after \(Self.joinerPollMaxDuration)s")
                    NotificationCenter.default.post(
                        name: .vaultPairingError,
                        object: nil,
                        userInfo: ["message": "Pairing timed out waiting for key bundle"]
                    )
                }
            }()

            _ = await (dmStream, vaultPoll)
        }
    }

    func handleJoinerDmMessage(_ message: DecodedMessage) async {
        guard let vaultInboxId = await vaultInboxId, message.senderInboxId != vaultInboxId else { return }

        guard let pairing: PairingMessageContent = try? message.content() else { return }

        switch pairing.type {
        case .error:
            joinerDmStreamTask?.cancel()
            joinerDmStreamTask = nil
            NotificationCenter.default.post(
                name: .vaultPairingError,
                object: nil,
                userInfo: ["message": pairing.payload]
            )
        case .pin:
            NotificationCenter.default.post(
                name: .vaultDidReceivePin,
                object: nil,
                userInfo: ["pin": pairing.payload, "initiatorInboxId": message.senderInboxId]
            )
        case .pinEcho:
            break
        }
    }

    public func stopJoinerPairing() {
        joinerDmStreamTask?.cancel()
        joinerDmStreamTask = nil
    }
}
