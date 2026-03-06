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
        guard let activePairingSlug else {
            return
        }
        guard let vaultInboxId = await vaultInboxId, message.senderInboxId != vaultInboxId else {
            return
        }

        var request: PairingJoinRequest?

        if let joinRequest: JoinRequestContent = try? message.content(),
           joinRequest.inviteSlug == activePairingSlug {
            let pin = joinRequest.metadata?["pin"] ?? ""
            let name = joinRequest.metadata?["deviceName"] ?? "Unknown device"
            request = PairingJoinRequest(
                pin: pin,
                deviceName: name,
                joinerInboxId: message.senderInboxId
            )
        } else if let text: String = try? message.content(),
                  text == activePairingSlug {
            request = PairingJoinRequest(pin: "", deviceName: "Unknown device", joinerInboxId: message.senderInboxId)
        }

        guard let request else { return }

        pendingPeerDeviceNames[request.joinerInboxId] = request.deviceName
        await lockVault()
        self.activePairingSlug = nil
        dmStreamTask?.cancel()
        dmStreamTask = nil

        delegate?.vaultManager(self, didReceivePairingJoinRequest: request)
    }

    public func sendPairingError(to joinerInboxId: String, message: String) async {
        do {
            let dm = try await vaultClient.findOrCreateDm(with: joinerInboxId)
            _ = try await dm.send(content: "PAIRING_ERROR:\(message)")
        } catch {
            Log.error("Failed to send pairing error to joiner: \(error)")
        }
    }
}

// MARK: - Pairing (Joiner - Device B)

extension VaultManager {
    public func sendPairingJoinRequest(
        slug: String,
        pin: String,
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
                "pin": pin,
                "deviceName": deviceName,
            ]
        )
        startJoinerDmStream()
    }

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
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
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
            }()

            _ = await (dmStream, vaultPoll)
        }
    }

    func handleJoinerDmMessage(_ message: DecodedMessage) async {
        guard let vaultInboxId = await vaultInboxId, message.senderInboxId != vaultInboxId else { return }

        if let text: String = try? message.content(),
           text.hasPrefix("PAIRING_ERROR:") {
            let errorMessage = String(text.dropFirst("PAIRING_ERROR:".count))
            joinerDmStreamTask?.cancel()
            joinerDmStreamTask = nil
            NotificationCenter.default.post(
                name: .vaultPairingError,
                object: nil,
                userInfo: ["message": errorMessage]
            )
        }
    }

    public func stopJoinerPairing() {
        joinerDmStreamTask?.cancel()
        joinerDmStreamTask = nil
    }
}
