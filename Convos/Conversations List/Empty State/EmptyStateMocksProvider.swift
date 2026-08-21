import ConvosCore
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

/// Decoded shape of the empty-state mock payload. The same shape is used
/// for the bundled `empty-state-mocks.json` resource and the remote
/// `GET v2/empty-state-mocks` response.
struct EmptyStateMockPayload: Decodable {
    let conversations: [EmptyStateMockConversation]
}

/// Source of the mock data shown in the chats empty-state CTA.
/// Bundled data loads synchronously at init so the carousels render on
/// first appearance; `refreshFromRemoteIfNeeded()` then fetches the same
/// payload shape from the API once per launch, replacing the bundled data
/// when it succeeds and silently keeping the bundled data when it fails.
@MainActor
@Observable
final class EmptyStateMocksProvider {
    static let shared: EmptyStateMocksProvider = EmptyStateMocksProvider()

    private(set) var conversations: [EmptyStateMockConversation] = []

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
            let environment = ConfigManager.shared.currentEnvironment
            let apiClient = ConvosAPIClientFactory.client(environment: environment)
            let request = try apiClient.request(for: Constant.remotePath, method: "GET", queryParameters: nil)
            // Not URLSession.shared: this is one of ours, so it needs the
            // preview token on a preview build.
            let session = PreviewTokenSession.makeSession(for: environment)
            let (data, response) = try await session.data(for: request)
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

    /// Replaces the current data with the payload's, keeping what it would
    /// otherwise empty out.
    private func apply(_ payload: EmptyStateMockPayload) {
        guard !payload.conversations.isEmpty else { return }
        conversations = payload.conversations
    }

    private enum Constant {
        static let bundledPayloadName: String = "empty-state-mocks"
        static let remotePath: String = "v2/empty-state-mocks"
    }
}
