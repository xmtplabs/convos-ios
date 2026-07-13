@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Integration coverage for post-pairing history sync against the local
/// XMTP node and message-history server (`./dev/up`). Message history is
/// not carried by device sync automatically: a new installation only
/// receives pre-existing messages when it explicitly asks its peers for
/// an archive, which is what `XMTPClientProvider.requestHistorySync()`
/// (wired into `SessionManager.refreshAfterPairingCompleted`) does on the
/// joiner right after pairing. These tests pin the two layers of that
/// promise: the request round-trips to the history server, and a live
/// peer installation answers it with an archive the requester imports.
///
/// Both tests are disabled until libxmtp fixes its rustls crypto-provider
/// initialization on Apple platforms. The provider is installed via the
/// `ctor` crate's static constructor (xmtp_cryptography/src/lib.rs), but
/// ctor 0.12's dispatcher never registers as a Mach-O initializer when
/// libxmtpv3.a is linked, so the provider is never set and the device-sync
/// worker's first history-server HTTP call dies in reqwest's
/// `panic!("No provider set")` - which aborts the process (the xcframework
/// builds with `panic = 'abort'`). Validated here up to that point: the
/// sync request lands in the sync group, the peer's worker answers and
/// starts the archive upload, then the panic kills the test run. Remove
/// the `.disabled` traits once a fixed libxmtp lands.
@Suite("History Sync Integration Tests", .serialized)
struct HistorySyncIntegrationTests {
    private static let upstreamBlocker: Comment = """
    blocked upstream: libxmtp's rustls provider ctor never runs on Apple \
    platforms; the device-sync archive upload panics and aborts the process
    """
    /// Creates a client in its own temp database directory. Passing the
    /// same `account` twice yields two installations of one inbox - the
    /// same shape pairing produces (initiator + joiner).
    private func createClient(account: PrivateKey) async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let dbKey = Data(keyBytes)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let options = ClientOptions(
            api: .init(env: .local, appVersion: "convos-tests/1.0.0"),
            codecs: [
                TextCodec(),
                GroupUpdatedCodec(),
            ],
            dbEncryptionKey: dbKey,
            dbDirectory: tmpDir.path
        )
        return try await Client.create(account: account, options: options)
    }

    @Test(
        "A second installation's history sync request reaches the history server",
        .disabled(Self.upstreamBlocker)
    )
    func historySyncRequestSucceeds() async throws {
        let account = try PrivateKey.generate()
        let first = try await createClient(account: account)
        let second = try await createClient(account: account)
        defer {
            try? first.deleteLocalDatabase()
            try? second.deleteLocalDatabase()
        }
        #expect(first.inboxId == second.inboxId)
        #expect(first.installationId != second.installationId)

        // Pull welcomes so the second installation lands in the inbox's
        // sync group before placing the request into it.
        _ = try await second.conversations.syncAllConversations(consentStates: nil)

        // The provider-protocol method under test - the same call
        // SessionManager makes on the joiner after pairing adoption.
        let provider: any XMTPClientProvider = second
        try await provider.requestHistorySync()
    }

    @Test(
        "History sync delivers pre-pairing messages to a new installation",
        .disabled(Self.upstreamBlocker),
        .timeLimit(.minutes(3))
    )
    func historySyncDeliversOldMessages() async throws {
        let account = try PrivateKey.generate()
        let peer = try await createClient(account: try PrivateKey.generate())

        // The first installation builds up history before the "pairing":
        // a group with a peer and a few messages in it.
        let first = try await createClient(account: account)
        defer {
            try? peer.deleteLocalDatabase()
            try? first.deleteLocalDatabase()
        }
        let group = try await first.conversations.newGroup(with: [peer.inboxId])
        let sentMessages = ["history one", "history two", "history three"]
        for text in sentMessages {
            _ = try await group.send(content: text)
        }

        // The second installation registers after the messages exist, so
        // forward secrecy hides them from it - exactly a joiner's state
        // right after pairing adoption.
        let second = try await createClient(account: account)
        defer { try? second.deleteLocalDatabase() }
        _ = try await second.conversations.syncAllConversations(consentStates: nil)

        let provider: any XMTPClientProvider = second
        try await provider.requestHistorySync()

        // The first installation's sync worker answers the request with an
        // archive; the second installation's worker imports it. Both run
        // on their own cadence, so nudge each side's device-sync groups
        // while polling for the imported history.
        var importedTexts: [String] = []
        for _ in 0..<60 {
            _ = try? await first.syncAllDeviceSyncGroups()
            _ = try? await second.syncAllDeviceSyncGroups()
            _ = try? await second.conversations.syncAllConversations(consentStates: nil)
            if let conversation = try await second.conversations.findConversation(conversationId: group.id) {
                let messages = try await conversation.messages()
                importedTexts = messages.compactMap { message in
                    (try? message.content()) as String?
                }
                if sentMessages.allSatisfy(importedTexts.contains) {
                    break
                }
            }
            try await Task.sleep(for: .seconds(2))
        }

        for text in sentMessages {
            #expect(importedTexts.contains(text), "missing pre-pairing message: \(text)")
        }
    }
}
