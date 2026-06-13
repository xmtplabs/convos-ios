// Thin wrapper that defers construction of the real initiator
// `LivePairingService` until `start()` is called. The Devices entry
// point holds a `SessionManagerProtocol`, but the messaging service
// isn't ready synchronously — we await it inside `start()`.

import ConvosCore
import Foundation
import os

final class DeferredInitiatorPairingService: PairingServiceProtocol, @unchecked Sendable {
    private let session: any SessionManagerProtocol
    private let underlying: OSAllocatedUnfairLock<NonSendableBox<(any PairingServiceProtocol)?>> = .init(
        initialState: NonSendableBox(nil)
    )

    init(session: any SessionManagerProtocol) {
        self.session = session
    }

    func start() async throws {
        let messagingService = session.messagingService()
        let service = try await messagingService.initiatorPairingService()
        underlying.withLock { box in
            box.value = service
        }
        try await service.start()
    }

    func pairingInboxId() async -> String? {
        let box = underlying.withLock { NonSendableBox($0.value) }
        return await box.value?.pairingInboxId()
    }

    func createPairingInvite(expiresAt: Date) async throws -> String {
        let box = underlying.withLock { NonSendableBox($0.value) }
        guard let service = box.value else { throw LivePairingServiceError.notReady }
        return try await service.createPairingInvite(expiresAt: expiresAt)
    }

    func sendPairingJoinRequest(slug: String, deviceName: String) async throws {
        let box = underlying.withLock { NonSendableBox($0.value) }
        guard let service = box.value else { throw LivePairingServiceError.notReady }
        try await service.sendPairingJoinRequest(slug: slug, deviceName: deviceName)
    }

    func sendPinToJoiner(_ pin: String, joinerInboxId: String) async throws {
        let box = underlying.withLock { NonSendableBox($0.value) }
        guard let service = box.value else { throw LivePairingServiceError.notReady }
        try await service.sendPinToJoiner(pin, joinerInboxId: joinerInboxId)
    }

    func sendPinEcho(_ pin: String, to initiatorInboxId: String) async throws {
        let box = underlying.withLock { NonSendableBox($0.value) }
        guard let service = box.value else { throw LivePairingServiceError.notReady }
        try await service.sendPinEcho(pin, to: initiatorInboxId)
    }

    func sendIdentityShare(toJoinerInboxId: String) async throws {
        let box = underlying.withLock { NonSendableBox($0.value) }
        guard let service = box.value else { throw LivePairingServiceError.notReady }
        try await service.sendIdentityShare(toJoinerInboxId: toJoinerInboxId)
    }

    func sendPairingError(to peerInboxId: String, message: String) async {
        let box = underlying.withLock { NonSendableBox($0.value) }
        guard let service = box.value else { return }
        await service.sendPairingError(to: peerInboxId, message: message)
    }

    func stop() async {
        let box = underlying.withLock { box -> NonSendableBox<(any PairingServiceProtocol)?> in
            let captured = box.value
            box.value = nil
            return NonSendableBox(captured)
        }
        await box.value?.stop()
    }
}
