import ConvosCore
import CryptoKit
import Foundation
import Observation

/// One mock conversation cycled through by the chats-tab empty-state
/// carousel. Rendered with the pinned-conversation component, so it
/// carries exactly what that component needs: a display name, an emoji
/// for the avatar, and an unread message preview.
struct EmptyStateMockConversation: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let emoji: String
    let messageText: String
}

/// One mock "thing" item cycled through by the Things-tab empty-state
/// carousel. The preview is rendered from real HTML, the same way actual
/// thing cells render agent-produced files, with the name of the mock
/// conversation the thing came from captioned underneath. Exactly one of
/// the two HTML sources is expected:
/// - `htmlFile`: name of a bundled resource (the payload the app ships with)
/// - `html`: inline markup (the remote payload)
struct EmptyStateMockThing: Decodable, Hashable, Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let conversationName: String?
    let htmlFile: String?
    let html: String?
}

/// Decoded shape of the empty-state mock payload. The same shape is used
/// for the bundled `empty-state-mocks.json` resource and the remote
/// `GET v2/empty-state-mocks` response.
struct EmptyStateMockPayload: Decodable {
    let conversations: [EmptyStateMockConversation]
    let things: [EmptyStateMockThing]
}

/// A mock thing item resolved to a local HTML file URL that
/// [[HTMLThumbnailRenderer]] can load, plus a content-versioned cache key
/// so an updated payload re-renders instead of hitting a stale thumbnail.
struct EmptyStateResolvedMockThing: Hashable, Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let conversationName: String?
    let fileURL: URL
    let thumbnailKey: String
}

/// Source of the mock data shown in the Chats and Things empty-state CTAs.
/// Bundled data loads synchronously at init so the carousels render on
/// first appearance; `refreshFromRemoteIfNeeded()` then fetches the same
/// payload shape from the API once per launch, replacing the bundled data
/// when it succeeds and silently keeping the bundled data when it fails.
///
/// Shared between the two tabs so they show consistent data and the
/// remote fetch happens once.
@MainActor
@Observable
final class EmptyStateMocksProvider {
    static let shared: EmptyStateMocksProvider = EmptyStateMocksProvider()

    private(set) var conversations: [EmptyStateMockConversation] = []
    private(set) var things: [EmptyStateResolvedMockThing] = []

    @ObservationIgnored private var hasStartedRemoteRefresh: Bool = false

    init() {
        loadBundledPayload()
    }

    /// Fetches the remote payload the first time it is called; later calls
    /// are no-ops. Any failure (endpoint missing, offline, bad payload)
    /// leaves the bundled data in place. A cancelled fetch (the hosting
    /// empty-state view disappeared, cancelling its `.task`) does not
    /// count as the once-per-launch attempt; the next appearance retries.
    func refreshFromRemoteIfNeeded() async {
        guard !hasStartedRemoteRefresh else { return }
        hasStartedRemoteRefresh = true
        do {
            let apiClient = ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)
            let request = try apiClient.request(for: Constant.remotePath, method: "GET", queryParameters: nil)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                Log.info("EmptyStateMocksProvider: remote mocks unavailable, keeping bundled payload")
                return
            }
            let payload = try JSONDecoder().decode(EmptyStateMockPayload.self, from: data)
            apply(payload)
        } catch {
            // URLSession surfaces task cancellation as URLError.cancelled
            // rather than CancellationError, so check both.
            let wasCancelled: Bool = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            if wasCancelled {
                hasStartedRemoteRefresh = false
                return
            }
            Log.info("EmptyStateMocksProvider: remote refresh failed, keeping bundled payload: \(error)")
        }
    }

    // MARK: - Loading

    private func loadBundledPayload() {
        guard let url = Bundle.main.url(forResource: Constant.bundledPayloadName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            Log.error("EmptyStateMocksProvider: bundled \(Constant.bundledPayloadName).json missing")
            return
        }
        do {
            apply(try JSONDecoder().decode(EmptyStateMockPayload.self, from: data))
        } catch {
            Log.error("EmptyStateMocksProvider: failed decoding bundled payload: \(error)")
        }
    }

    /// Replaces the current data with the payload's, keeping whichever
    /// current section the payload would empty out.
    private func apply(_ payload: EmptyStateMockPayload) {
        let resolvedThings: [EmptyStateResolvedMockThing] = payload.things.compactMap(resolve(_:))
        if !payload.conversations.isEmpty {
            conversations = payload.conversations
        }
        if !resolvedThings.isEmpty {
            things = resolvedThings
        }
    }

    // MARK: - Thing HTML resolution

    private func resolve(_ thing: EmptyStateMockThing) -> EmptyStateResolvedMockThing? {
        if let html = thing.html, !html.isEmpty {
            return resolveInline(thing, html: html)
        }
        if let htmlFile = thing.htmlFile, !htmlFile.isEmpty {
            return resolveBundled(thing, fileName: htmlFile)
        }
        Log.error("EmptyStateMocksProvider: thing \(thing.id) has neither html nor htmlFile")
        return nil
    }

    private func resolveBundled(_ thing: EmptyStateMockThing, fileName: String) -> EmptyStateResolvedMockThing? {
        let baseName: String = (fileName as NSString).deletingPathExtension
        let fileExtension: String = (fileName as NSString).pathExtension
        guard let url = Bundle.main.url(
            forResource: baseName,
            withExtension: fileExtension.isEmpty ? "html" : fileExtension
        ), let data = try? Data(contentsOf: url) else {
            Log.error("EmptyStateMocksProvider: bundled HTML \(fileName) missing for thing \(thing.id)")
            return nil
        }
        return resolved(thing, fileURL: url, contentHash: Self.shortHash(of: data))
    }

    /// Persists inline HTML from the remote payload into the caches
    /// directory so the thumbnail renderer has a file URL to load.
    private func resolveInline(_ thing: EmptyStateMockThing, html: String) -> EmptyStateResolvedMockThing? {
        let data = Data(html.utf8)
        let contentHash: String = Self.shortHash(of: data)
        do {
            let directory = try Self.cacheDirectory()
            let fileURL = directory.appendingPathComponent("\(thing.id)-\(contentHash).html")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
            }
            return resolved(thing, fileURL: fileURL, contentHash: contentHash)
        } catch {
            Log.error("EmptyStateMocksProvider: failed persisting inline HTML for thing \(thing.id): \(error)")
            return nil
        }
    }

    private func resolved(
        _ thing: EmptyStateMockThing,
        fileURL: URL,
        contentHash: String
    ) -> EmptyStateResolvedMockThing {
        EmptyStateResolvedMockThing(
            id: thing.id,
            title: thing.title,
            emoji: thing.emoji,
            conversationName: thing.conversationName,
            fileURL: fileURL,
            thumbnailKey: "empty-state-mock-thing-\(thing.id)-\(contentHash)"
        )
    }

    private static func cacheDirectory() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appendingPathComponent(Constant.cacheDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func shortHash(of data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private enum Constant {
        static let bundledPayloadName: String = "empty-state-mocks"
        static let remotePath: String = "v2/empty-state-mocks"
        static let cacheDirectoryName: String = "EmptyStateMocks"
    }
}
