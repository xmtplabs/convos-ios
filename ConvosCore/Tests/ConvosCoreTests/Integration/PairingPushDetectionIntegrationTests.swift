@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Integration coverage for the NSE's welcome-push pairing detection, run
/// against a local XMTP node (`./dev/up`). Simulators never spawn the
/// real notification extension for `simctl push`, so this exercises the
/// exact code the NSE runs - `detectRecentPairingJoinRequest` over a real
/// synced DM and `pairingRequestNotification`'s stash + dedupe - with a
/// real joiner client sending a real `PairingJoinRequestContent`.
@Suite("Pairing Push Detection Integration", .serialized)
struct PairingPushDetectionIntegrationTests {
    @Test("Welcome-path scan surfaces only a self-signed join request")
    func welcomeScanSurfacesVerifiedRequest() async throws {
        let fixtures = TestFixtures()
        // Create the joiner first: `createClient` saves each identity into
        // the single keychain slot, and the service must verify against
        // the initiator's identity (the slot's final occupant).
        let (joiner, _, _) = try await fixtures.createClient()
        let (initiator, _, initiatorKeys) = try await fixtures.createClient()
        defer {
            try? joiner.deleteLocalDatabase()
            try? initiator.deleteLocalDatabase()
        }
        let service = fixtures.makeFreshMessagingService()

        let dm = try await joiner.conversationsProvider.findOrCreateDm(with: initiator.inboxId)

        // A forged request first: valid signature from a random key that
        // names the initiator's inboxId - the spoof the address check
        // rejects. With only this in the DM, nothing may surface.
        let attackerKey = try PrivateKey.generate()
        let forgedInvite = try await PairingInvite.signed(
            initiatorInboxId: initiator.inboxId,
            privateKey: attackerKey,
            expiresAt: Date().addingTimeInterval(300)
        )
        try await sendJoinRequest(
            slug: try forgedInvite.toURLSafeSlug(),
            deviceName: "Attacker Phone",
            from: joiner,
            on: dm
        )
        _ = try await initiator.conversationsProvider.syncAllConversations(consentStates: [.unknown])
        let forgedResult = await service.detectRecentPairingJoinRequest(client: initiator)
        #expect(forgedResult == nil)

        // The real request: slug minted from the initiator's own key,
        // exactly what the iCloud-discovery joiner sends.
        let invite = try await PairingInvite.signed(
            initiatorInboxId: initiator.inboxId,
            privateKey: initiatorKeys.privateKey,
            expiresAt: Date().addingTimeInterval(300)
        )
        let slug = try invite.toURLSafeSlug()
        try await sendJoinRequest(slug: slug, deviceName: "Joiner Phone", from: joiner, on: dm)
        _ = try await initiator.conversationsProvider.syncAllConversations(consentStates: [.unknown])

        let request = try #require(await service.detectRecentPairingJoinRequest(client: initiator))
        #expect(request.joinerInboxId == joiner.inboxId)
        #expect(request.deviceName == "Joiner Phone")
        #expect(request.slug == slug)

        // Notification building: first call stashes + notifies, the
        // immediate repeat (a resend hitting another NSE invocation)
        // dedupes against the stash.
        let appGroup = fixtures.environment.appGroupIdentifier
        _ = PendingPairRequestStore.consumePending(appGroup: appGroup)
        defer { _ = PendingPairRequestStore.consumePending(appGroup: appGroup) }

        let notification = service.pairingRequestNotification(request, userInfo: [:])
        #expect(notification.body == "\"Joiner Phone\" is requesting to pair")
        #expect(notification.isDroppedMessage == false)
        // conversationId doubles as the threadIdentifier the app's
        // delivered-banner cleanup matches on.
        #expect(notification.conversationId == PairingNotificationThread.identifier)
        let stashed = try #require(PendingPairRequestStore.pending(appGroup: appGroup))
        #expect(stashed.joinerInboxId == joiner.inboxId)

        let repeated = service.pairingRequestNotification(request, userInfo: [:])
        #expect(repeated.isDroppedMessage)
    }

    private func sendJoinRequest(
        slug: String,
        deviceName: String,
        from joiner: any XMTPClientProvider,
        on dm: Dm
    ) async throws {
        let content = PairingJoinRequestContent(
            slug: slug,
            joinerInboxId: joiner.inboxId,
            deviceName: deviceName
        )
        let encoded = try PairingJoinRequestCodec().encode(content: content)
        _ = try await dm.send(encodedContent: encoded)
    }
}
