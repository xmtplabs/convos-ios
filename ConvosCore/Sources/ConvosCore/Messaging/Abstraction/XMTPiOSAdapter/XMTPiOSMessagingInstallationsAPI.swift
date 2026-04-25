import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingInstallationsAPI`.
///
/// Wraps the installation-management surface on `XMTPiOS.Client`
/// (instance methods) and `XMTPiOS.Client`'s static
/// `revokeInstallations(api:signingKey:inboxId:installationIds:)` for
/// the out-of-band revocation path.
public final class XMTPiOSMessagingInstallationsAPI: MessagingInstallationsAPI, @unchecked Sendable {
    let xmtpClient: XMTPiOS.Client

    public init(xmtpClient: XMTPiOS.Client) {
        self.xmtpClient = xmtpClient
    }

    public func inboxState(refreshFromNetwork: Bool) async throws -> MessagingInbox {
        let xmtpState = try await xmtpClient.inboxState(refreshFromNetwork: refreshFromNetwork)
        return MessagingInbox(xmtpState)
    }

    public func inboxStates(
        inboxIds: [MessagingInboxID],
        refreshFromNetwork: Bool
    ) async throws -> [MessagingInbox] {
        let xmtpStates = try await xmtpClient.inboxStatesForInboxIds(
            refreshFromNetwork: refreshFromNetwork,
            inboxIds: inboxIds
        )
        return xmtpStates.map(MessagingInbox.init)
    }

    public func revokeInstallations(
        signer: any MessagingSigner,
        installationIds: [MessagingInstallationID]
    ) async throws {
        try await xmtpClient.revokeInstallations(
            signingKey: XMTPiOSSigningKeyAdapter(signer),
            installationIds: installationIds
        )
    }

    public func revokeAllOtherInstallations(signer: any MessagingSigner) async throws {
        try await xmtpClient.revokeAllOtherInstallations(
            signingKey: XMTPiOSSigningKeyAdapter(signer)
        )
    }

    public static func revokeInstallations(
        config: MessagingClientConfig,
        signer: any MessagingSigner,
        inboxId: MessagingInboxID,
        installationIds: [MessagingInstallationID]
    ) async throws {
        // Apply the per-instance config to the adapter-owned
        // XMTPEnvironment global. The factory owns the single site
        // that writes this; reusing that function keeps us from
        // sprinkling `XMTPEnvironment.customLocalAddress` writes
        // around.
        let apiOptions = XMTPiOSMessagingClientFactory.shared.apiOptions(config: config)
        try await XMTPiOS.Client.revokeInstallations(
            api: apiOptions,
            signingKey: XMTPiOSSigningKeyAdapter(signer),
            inboxId: inboxId,
            installationIds: installationIds
        )
    }
}
