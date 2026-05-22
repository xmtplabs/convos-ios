import CryptoSwift
import Foundation
import os
@preconcurrency import XMTPiOS

public enum LivePairingServiceError: Error, LocalizedError, Equatable {
    case notReady
    case xmtpUnavailable
    case identityUnavailable
    case invalidSlug
    case dmUnavailable
    case alreadyHasIdentity

    public var errorDescription: String? {
        switch self {
        case .notReady:
            return "Pairing service is not ready"
        case .xmtpUnavailable:
            return "XMTP client is not available"
        case .identityUnavailable:
            return "Identity is not available for sharing"
        case .invalidSlug:
            return "Pairing invite is invalid"
        case .dmUnavailable:
            return "Pairing DM channel is unavailable"
        case .alreadyHasIdentity:
            return "This device already has a Convos identity. Delete data first to pair with a different account."
        }
    }
}

/// Live pairing service backed by real XMTP clients.
///
/// - Initiator: uses the user's already-running client (passed in). Streams
///   the user's DMs filtering for pairing content types, posts notifications
///   when `PairingJoinRequest` / `PinEcho` arrive.
/// - Joiner: builds an ephemeral `XMTPiOS.Client` with a fresh keypair and
///   a throwaway db directory. Streams its DMs filtering for pairing
///   content. On valid `IdentityShare`, the joiner saves the paired
///   identity to its `KeychainIdentityStore` and posts the
///   `pairingDidReceiveIdentityShare` notification so the host app can
///   re-bootstrap the session with the paired key.
///
/// @unchecked Sendable: wraps a non-Sendable XMTPiOS.Client behind an
/// NSLock for the few mutable fields. Same pattern as `MessagingService`.
public final class LivePairingService: PairingServiceProtocol, @unchecked Sendable {
    /// Snapshot of the initiator's profile that travels alongside the
    /// signing key in the `IdentityShareContent`. The joiner uses this
    /// to seed its own `DBMyProfile` and to skip the in-conversation
    /// onboarding prompts. Nil fields mean the initiator had no profile
    /// set yet (genuinely new user) — the joiner falls into the same
    /// onboarding flow as the initiator would.
    public struct InitiatorProfile: Sendable, Equatable {
        public let displayName: String?
        public let imageAssetIdentifier: String?

        public init(displayName: String?, imageAssetIdentifier: String?) {
            self.displayName = displayName
            self.imageAssetIdentifier = imageAssetIdentifier
        }
    }

    public enum Role {
        case initiator(client: any XMTPClientProvider,
                       identityStore: any KeychainIdentityStoreProtocol,
                       environment: AppEnvironment,
                       initiatorProfile: InitiatorProfile?)
        case joiner(identityStore: any KeychainIdentityStoreProtocol,
                    environment: AppEnvironment)
    }

    /// @unchecked Sendable because the non-Sendable `XMTPClientProvider`
    /// is held behind the `OSAllocatedUnfairLock` and accessed only under
    /// the lock or via a one-shot copy captured before any suspension.
    private final class State: @unchecked Sendable {
        var started: Bool = false
        var streamingTask: Task<Void, Never>?
        var joinerClient: (any XMTPClientProvider)?
        var joinerSigningKey: PrivateKey?
        var joinerDbDirectory: URL?
        /// Captured by the joiner side when it decodes the scanned
        /// `SignedInvite` slug. Used to validate the address recovered
        /// from the inbound `IdentityShareContent` so the joiner cannot
        /// be tricked into adopting an attacker-supplied key.
        var expectedInitiatorAddress: String?
    }

    private let role: Role
    private let state: OSAllocatedUnfairLock<State> = .init(initialState: State())

    public init(role: Role) {
        self.role = role
    }

    // MARK: - PairingServiceProtocol

    public func start() async throws {
        let alreadyStarted = state.withLock { s -> Bool in
            if s.started { return true }
            s.started = true
            return false
        }
        if alreadyStarted { return }

        // Roll back `started` if any throwing path below fails, so callers
        // can retry. Without this, a transient `createJoinerClient` failure
        // leaves the service permanently un-startable.
        var succeeded = false
        defer {
            if !succeeded {
                state.withLock { $0.started = false }
            }
        }

        switch role {
        case let .initiator(client, _, _, _):
            let box = NonSendableBox(client)
            startMessageStream(clientBox: box, isJoiner: false)
        case let .joiner(_, environment):
            // Note: we used to refuse pairing here if any identity existed
            // in the keychain. That's too strict — silent identity
            // creation on launch means every fresh install has one. The
            // VM-level gate (`checkHasExistingData`) decides whether the
            // user has *real* data to warn about; this layer just
            // bootstraps the ephemeral joiner client. Placeholder
            // identities get silently overwritten on a successful share.
            let bundle = try await Self.createJoinerClient(environment: environment)
            state.withLock { s in
                s.joinerClient = bundle.client
                s.joinerSigningKey = bundle.signingKey
                s.joinerDbDirectory = bundle.dbDir
            }
            startMessageStream(clientBox: NonSendableBox(bundle.client), isJoiner: true)
        }
        succeeded = true
    }

    public func pairingInboxId() async -> String? {
        switch role {
        case let .initiator(client, _, _, _):
            return client.inboxId
        case .joiner:
            let box = state.withLock { s in NonSendableBox(s.joinerClient) }
            return box.value?.inboxId
        }
    }

    public func createPairingInvite(expiresAt: Date) async throws -> String {
        switch role {
        case let .initiator(_, identityStore, _, _):
            return try await signInviteSlug(identityStore: identityStore, expiresAt: expiresAt)
        case .joiner:
            throw LivePairingServiceError.notReady
        }
    }

    public func sendPairingJoinRequest(slug: String, deviceName: String) async throws {
        guard case .joiner = role else { throw LivePairingServiceError.notReady }
        let box = state.withLock { s in NonSendableBox(s.joinerClient) }
        guard let joinerClient = box.value else { throw LivePairingServiceError.xmtpUnavailable }
        let invite: PairingInvite
        do {
            invite = try PairingInvite.fromURLSafeSlug(slug)
        } catch {
            Log.warning("Pairing: joiner failed to decode slug: \(error)")
            throw LivePairingServiceError.invalidSlug
        }
        Log.info("Pairing: joiner sending JoinRequest to initiatorInboxId=\(invite.initiatorInboxId)")
        // Cache the initiator address so `handleIdentityShare` can verify
        // the incoming key was signed by the same party that signed the
        // scanned QR slug.
        state.withLock { $0.expectedInitiatorAddress = invite.initiatorAddress.lowercased() }
        let dm = try await joinerClient.conversationsProvider.findOrCreateDm(
            with: invite.initiatorInboxId
        )
        let content = PairingJoinRequestContent(
            slug: slug,
            joinerInboxId: joinerClient.inboxId,
            deviceName: deviceName
        )
        try await dm.send(
            content: content,
            options: SendOptions(contentType: ContentTypePairingJoinRequest)
        )
        Log.info("Pairing: joiner JoinRequest sent")
    }

    public func sendPinToJoiner(_ pin: String, joinerInboxId: String) async throws {
        guard case let .initiator(client, _, _, _) = role else { throw LivePairingServiceError.notReady }
        let dm = try await client.conversationsProvider.findOrCreateDm(with: joinerInboxId)
        try await dm.send(
            content: PairingMessageContent.pin(pin),
            options: SendOptions(contentType: ContentTypePairingMessage)
        )
    }

    public func sendPinEcho(_ pin: String, to initiatorInboxId: String) async throws {
        guard case .joiner = role else { throw LivePairingServiceError.notReady }
        let box = state.withLock { s in NonSendableBox(s.joinerClient) }
        guard let joinerClient = box.value else { throw LivePairingServiceError.xmtpUnavailable }
        let dm = try await joinerClient.conversationsProvider.findOrCreateDm(with: initiatorInboxId)
        try await dm.send(
            content: PairingMessageContent.pinEcho(pin),
            options: SendOptions(contentType: ContentTypePairingMessage)
        )
    }

    public func sendIdentityShare(toJoinerInboxId: String) async throws {
        guard case let .initiator(client, identityStore, _, initiatorProfile) = role else {
            throw LivePairingServiceError.notReady
        }
        let identity = try identityStore.loadSync()
        guard let identity else { throw LivePairingServiceError.identityUnavailable }

        let share = IdentityShareContent(
            privateKeyData: identity.keys.privateKey.secp256K1.bytes,
            inboxId: identity.inboxId,
            initiatorDeviceName: DeviceInfo.deviceName,
            displayName: initiatorProfile?.displayName,
            imageAssetIdentifier: initiatorProfile?.imageAssetIdentifier
        )
        let dm = try await client.conversationsProvider.findOrCreateDm(with: toJoinerInboxId)
        try await dm.send(
            content: share,
            options: SendOptions(contentType: ContentTypeIdentityShare)
        )
    }

    public func sendPairingError(to peerInboxId: String, message: String) async {
        do {
            switch role {
            case let .initiator(client, _, _, _):
                let dm = try await client.conversationsProvider.findOrCreateDm(with: peerInboxId)
                try await dm.send(
                    content: PairingMessageContent.error(message),
                    options: SendOptions(contentType: ContentTypePairingMessage)
                )
            case .joiner:
                let box = state.withLock { s in NonSendableBox(s.joinerClient) }
                guard let joinerClient = box.value else { return }
                let dm = try await joinerClient.conversationsProvider.findOrCreateDm(with: peerInboxId)
                try await dm.send(
                    content: PairingMessageContent.error(message),
                    options: SendOptions(contentType: ContentTypePairingMessage)
                )
            }
        } catch {
            Log.warning("Failed to send pairing error DM: \(error)")
        }
    }

    public func stop() async {
        let teardown = state.withLock { s -> NonSendableBox<((any XMTPClientProvider)?, URL?)> in
            s.streamingTask?.cancel()
            s.streamingTask = nil
            let c = s.joinerClient
            let d = s.joinerDbDirectory
            if case .joiner = role {
                s.joinerClient = nil
                s.joinerSigningKey = nil
                s.joinerDbDirectory = nil
            }
            s.started = false
            return NonSendableBox((c, d))
        }
        if case .joiner = role {
            let (client, dbDir) = teardown.value
            try? client?.deleteLocalDatabase()
            if let dbDir {
                try? FileManager.default.removeItem(at: dbDir)
            }
        }
    }

    // MARK: - Internals

    private func signInviteSlug(
        identityStore: any KeychainIdentityStoreProtocol,
        expiresAt: Date
    ) async throws -> String {
        guard let identity = try identityStore.loadSync() else {
            throw LivePairingServiceError.identityUnavailable
        }
        var nonce = Data(count: 16)
        let nonceStatus: OSStatus = nonce.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecUnknownFormat }
            return SecRandomCopyBytes(kSecRandomDefault, 16, baseAddress)
        }
        guard nonceStatus == errSecSuccess else {
            Log.warning("Pairing: nonce generation failed status=\(nonceStatus); refusing to sign invite")
            throw LivePairingServiceError.xmtpUnavailable
        }
        let issuedAt = Int64(Date().timeIntervalSince1970)
        let expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        let address = identity.keys.privateKey.walletAddress
        let payload = PairingInvite.signingPayload(
            initiatorInboxId: identity.inboxId,
            initiatorAddress: address,
            nonce: nonce,
            issuedAt: issuedAt,
            expiresAt: expiresAtUnix
        )
        let signed = try await identity.keys.privateKey.sign(payload.toHexString())
        let invite = PairingInvite(
            initiatorInboxId: identity.inboxId,
            initiatorAddress: address,
            nonce: nonce,
            issuedAt: issuedAt,
            expiresAt: expiresAtUnix,
            signature: signed.rawData
        )
        return try invite.toURLSafeSlug()
    }

    private func startMessageStream(clientBox: NonSendableBox<any XMTPClientProvider>, isJoiner: Bool) {
        let task = Task { [weak self] in
            Log.info("Pairing: starting message stream (isJoiner=\(isJoiner)) inbox=\(clientBox.value.inboxId)")
            do {
                _ = try await clientBox.value.conversationsProvider.syncAllConversations(consentStates: nil)
                Log.info("Pairing: initial syncAllConversations complete (isJoiner=\(isJoiner))")
            } catch {
                Log.warning("Pairing: initial syncAllConversations failed (isJoiner=\(isJoiner)): \(error)")
            }
            let stream = clientBox.value.conversationsProvider.streamAllMessages(
                type: .all,
                consentStates: nil,
                onClose: {
                    Log.warning("Pairing: stream onClose fired (isJoiner=\(isJoiner))")
                }
            )
            do {
                for try await message in stream {
                    if Task.isCancelled { break }
                    self?.handleIncoming(message: message, isJoiner: isJoiner)
                }
            } catch {
                if !Task.isCancelled {
                    Log.warning("Pairing: stream ended (isJoiner=\(isJoiner)): \(error)")
                }
            }
            Log.info("Pairing: message stream task exited (isJoiner=\(isJoiner))")
        }
        state.withLock { s in
            s.streamingTask?.cancel()
            s.streamingTask = task
        }
    }

    private func handleIncoming(message: XMTPiOS.DecodedMessage, isJoiner: Bool) {
        guard let typeId = try? message.encodedContent.type.typeID else {
            Log.warning("Pairing: incoming message missing encodedContent.type")
            return
        }
        Log.info("Pairing: incoming message typeId=\(typeId) sender=\(message.senderInboxId) isJoiner=\(isJoiner)")
        switch typeId {
        case ContentTypePairingMessage.typeID:
            handlePairingMessage(message: message, isJoiner: isJoiner)
        case ContentTypePairingJoinRequest.typeID where !isJoiner:
            handleJoinRequest(message: message)
        case ContentTypeIdentityShare.typeID where isJoiner:
            Task { await self.handleIdentityShare(message: message) }
        default:
            break
        }
    }

    private func handlePairingMessage(message: XMTPiOS.DecodedMessage, isJoiner: Bool) {
        guard let content = try? message.content() as PairingMessageContent else { return }
        switch content.type {
        case .pin where isJoiner:
            NotificationCenter.default.post(
                name: .pairingDidReceivePin,
                object: nil,
                userInfo: [
                    "pin": content.payload,
                    "initiatorInboxId": message.senderInboxId
                ]
            )
        case .pinEcho where !isJoiner:
            NotificationCenter.default.post(
                name: .pairingDidReceivePinEcho,
                object: nil,
                userInfo: [
                    "pin": content.payload,
                    "joinerInboxId": message.senderInboxId
                ]
            )
        case .error:
            NotificationCenter.default.post(
                name: .pairingDidReceiveError,
                object: nil,
                userInfo: ["message": content.payload]
            )
        default:
            break
        }
    }

    private func handleJoinRequest(message: XMTPiOS.DecodedMessage) {
        guard let content = try? message.content() as PairingJoinRequestContent else { return }
        // Use the MLS-authenticated `senderInboxId` rather than the payload's
        // `joinerInboxId` — the payload field is attacker-controlled, while
        // the sender id is verified by libxmtp. Sending the PIN to the wrong
        // inbox would let a spoofed payload divert the handshake.
        NotificationCenter.default.post(
            name: .pairingDidReceiveJoinRequest,
            object: nil,
            userInfo: [
                "joinerInboxId": message.senderInboxId,
                "deviceName": content.deviceName,
                "slug": content.slug
            ]
        )
    }

    private func handleIdentityShare(message: XMTPiOS.DecodedMessage) async {
        guard case let .joiner(identityStore, environment) = role else { return }
        guard let content = try? message.content() as IdentityShareContent else { return }

        do {
            let privateKey = try PrivateKey(content.privateKeyData)
            let derivedAddress = privateKey.walletAddress.lowercased()
            let expectedAddress = state.withLock { $0.expectedInitiatorAddress }
            if let expectedAddress, derivedAddress != expectedAddress {
                Log.warning("Pairing: address mismatch — expected \(expectedAddress) got \(derivedAddress)")
                NotificationCenter.default.post(
                    name: .pairingDidReceiveError,
                    object: nil,
                    userInfo: ["message": "Pairing rejected: identity mismatch"]
                )
                return
            }

            var databaseKey = Data(count: 32)
            let status: OSStatus = databaseKey.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return errSecUnknownFormat }
                return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
            }
            guard status == errSecSuccess else {
                NotificationCenter.default.post(
                    name: .pairingDidReceiveError,
                    object: nil,
                    userInfo: ["message": "Failed to generate database key"]
                )
                return
            }

            let keys = KeychainIdentityKeys(
                privateKey: privateKey,
                databaseKey: databaseKey
            )
            let clientId = UUID().uuidString
            _ = try await identityStore.save(
                inboxId: content.inboxId,
                clientId: clientId,
                keys: keys
            )

            // Stash initiator's deviceName so DevicesViewModel can claim
            // it for the initiator's installation on the next refresh.
            if let initiatorName = content.initiatorDeviceName, !initiatorName.isEmpty {
                PairedDeviceNameStore.setPending(initiatorName, appGroup: environment.appGroupIdentifier)
            }

            var userInfo: [String: Any] = ["inboxId": content.inboxId]
            if let displayName = content.displayName {
                userInfo["displayName"] = displayName
            }
            if let imageAssetIdentifier = content.imageAssetIdentifier {
                userInfo["imageAssetIdentifier"] = imageAssetIdentifier
            }
            NotificationCenter.default.post(
                name: .pairingDidReceiveIdentityShare,
                object: nil,
                userInfo: userInfo
            )
        } catch {
            Log.error("Pairing: failed to import identity share: \(error)")
            NotificationCenter.default.post(
                name: .pairingDidReceiveError,
                object: nil,
                userInfo: ["message": "Failed to adopt identity: \(error.localizedDescription)"]
            )
        }
    }

    // MARK: - Joiner ephemeral client bootstrap

    struct JoinerClientBundle {
        let client: any XMTPClientProvider
        let signingKey: PrivateKey
        let dbDir: URL
    }

    /// Creates a fresh `XMTPiOS.Client` with a brand-new keypair, registered
    /// pairing codecs, and a throwaway db directory. The client never
    /// touches the host's `KeychainIdentityStore` — the only place its
    /// keypair lives is inside `LivePairingService` for the duration of
    /// the handshake.
    private static func createJoinerClient(
        environment: AppEnvironment
    ) async throws -> JoinerClientBundle {
        let signingKey = try PrivateKey.generate()
        var dbEncryptionKey = Data(count: 32)
        let keyStatus: OSStatus = dbEncryptionKey.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecUnknownFormat }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard keyStatus == errSecSuccess else {
            throw LivePairingServiceError.xmtpUnavailable
        }

        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convos-pairing-joiner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let apiOptions: ClientOptions.Api = .init(
            env: environment.xmtpEnv,
            appVersion: "convos/\(Bundle.appVersion)"
        )
        let options = ClientOptions(
            api: apiOptions,
            codecs: [
                PairingMessageCodec(),
                PairingJoinRequestCodec(),
                IdentityShareCodec()
            ],
            dbEncryptionKey: dbEncryptionKey,
            dbDirectory: dbDir.path,
            deviceSyncEnabled: false
        )
        if let customHost = environment.customLocalAddress {
            XMTPEnvironment.customLocalAddress = customHost
        }
        let client = try await Client.create(account: signingKey, options: options)
        return JoinerClientBundle(client: client, signingKey: signingKey, dbDir: dbDir)
    }
}

/// Carries a non-Sendable value across a `@Sendable` boundary. Used so the
/// pairing streaming task can capture an `XMTPClientProvider` without the
/// compiler complaining. The caller is responsible for ensuring the
/// captured value isn't mutated concurrently — for the pairing service
/// this is fine because we hand the box to exactly one Task.
public final class NonSendableBox<T>: @unchecked Sendable {
    public var value: T
    public init(_ value: T) { self.value = value }
}
