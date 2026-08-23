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
/// These tests require a libxmtp build that installs its rustls crypto
/// provider explicitly from the binding entry points (nightly 20260714 or
/// later). Earlier builds relied on a ctor-crate static constructor that
/// never runs when libxmtpv3.a is linked into a Swift binary, so the
/// device-sync worker's first history-server HTTP call panicked
/// ("No provider set") and aborted the process.
@Suite("History Sync Integration Tests", .serialized)
struct HistorySyncIntegrationTests {
    /// Whether the local message-history server (`./dev/up`, port 5558) is
    /// reachable. CI deploys only an ephemeral XMTP node - no history
    /// server - so archive-delivery coverage runs locally and skips there.
    /// The request-only test needs just the node (the request travels
    /// through the sync group) and runs everywhere.
    private static let historyServerReachable: Bool = {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(5558).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(sock, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }()
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

    @Test("A second installation's history sync request reaches the history server")
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
        .enabled(if: Self.historyServerReachable, "requires the local message-history server on port 5558 (./dev/up)"),
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
