import ConvosCore
import Foundation

/// What a Space is doing right now, as the tab draws it.
struct SpaceEventsState: Equatable {
    /// The deployment currently serving, or `nil` where none has activated yet.
    let activeDeploymentId: String?
    /// The work agents have announced, one entry per path they are editing.
    let pendingChanges: [PendingChange]

    static let empty: SpaceEventsState = SpaceEventsState(
        activeDeploymentId: nil,
        pendingChanges: []
    )

    /// Work announced at a route or anywhere below it.
    ///
    /// Matching is by whole path segments, so `/note` never claims work on
    /// `/notebook`, and the freshest entry carrying a message wins.
    func work(at route: String) -> PendingChange? {
        pendingChanges
            .filter { $0.path == route || $0.path.hasPrefix(route == "/" ? "/" : "\(route)/") }
            .filter { $0.path != PendingChange.siteWide }
            .max { left, right in
                (left.message == nil ? 0 : 1, left.lastSeenAt)
                    < (right.message == nil ? 0 : 1, right.lastSeenAt)
            }
    }

    /// Work the host could not tie to one route — an edited asset rather than a
    /// page, which is what most content changes are. It belongs to the page as
    /// a whole rather than to any one tile.
    var siteWideWork: PendingChange? {
        pendingChanges
            .filter { $0.path == PendingChange.siteWide }
            .max { $0.lastSeenAt < $1.lastSeenAt }
    }
}

/// One announced edit in flight.
struct PendingChange: Equatable {
    /// The host projects a routable page to its route and everything else to
    /// this, so an asset edit is site-wide rather than mis-attributed.
    static let siteWide: String = "*"

    let path: String
    let message: String?
    let lastSeenAt: Double
}

/// Follows one Space's live state.
///
/// The host streams it, but only a deployment's `/mcp` path may hold a
/// connection open for minutes; every other Space route is cut at 15 seconds.
/// So the Space server holds instead and answers the moment its state changes,
/// and this loops — one short request per change, carrying back the marker it
/// last saw.
@MainActor
final class SpaceEventsFollower {
    private var task: Task<Void, Never>?

    /// Starts following, delivering each new state until `stop` or deinit.
    ///
    /// `onState` is called on the main actor, only when the state actually
    /// changed, so a caller can animate every delivery without animating a
    /// redelivery of what it already drew.
    func start(base: URL, session: URLSession = .shared, onState: @escaping (SpaceEventsState) -> Void) {
        stop()
        task = Task { [weak self] in
            var marker: String?
            var attempt = 0
            var delivered: SpaceEventsState?
            while !Task.isCancelled {
                do {
                    let answer = try await Self.poll(base: base, since: marker, session: session)
                    // A valid answer clears the backoff, so the next change is
                    // followed immediately however long the last outage was.
                    attempt = 0
                    marker = answer.marker
                    if let state = answer.state, state != delivered {
                        delivered = state
                        onState(state)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                    guard await self?.pause(attempt: attempt) == true else { return }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }

    /// Full jitter, 250 ms doubling to a 10 s cap — every open page fails
    /// together when a Space runs out of waiter slots, so a fixed fraction of
    /// the window would send them all back in the same instant.
    private func pause(attempt: Int) async -> Bool {
        let ceiling = min(Constant.backoffCap, Constant.backoffFloor * pow(2, Double(attempt - 1)))
        let seconds = Double.random(in: 0...ceiling)
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }

    private struct Answer {
        let marker: String?
        let state: SpaceEventsState?
    }

    private static func poll(base: URL, since: String?, session: URLSession) async throws -> Answer {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var items = [URLQueryItem(name: "format", value: "events")]
        if let since {
            items.append(URLQueryItem(name: "since", value: since))
        }
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = Constant.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    private static func decode(_ data: Data) throws -> Answer {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let marker = object["marker"] as? String
        guard let raw = object["state"] as? [String: Any] else {
            return Answer(marker: marker, state: nil)
        }
        // One unreadable entry makes the whole snapshot untrustworthy: the wire
        // is a replacement, so a partial one would silently drop live work.
        var changes: [PendingChange] = []
        for entry in raw["pending_changes"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String else {
                throw URLError(.cannotParseResponse)
            }
            changes.append(
                PendingChange(
                    path: path,
                    message: entry["message"] as? String,
                    lastSeenAt: entry["lastSeenAt"] as? Double ?? 0
                )
            )
        }
        return Answer(
            marker: marker,
            state: SpaceEventsState(
                activeDeploymentId: raw["activeDeploymentId"] as? String,
                pendingChanges: changes
            )
        )
    }

    private enum Constant {
        static let backoffFloor: Double = 0.25
        static let backoffCap: Double = 10.0
        /// Longer than the server's own hold, so an idle answer is not a timeout.
        static let requestTimeout: TimeInterval = 25.0
    }
}
