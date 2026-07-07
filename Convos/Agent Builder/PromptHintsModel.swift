import ConvosCore
import Foundation
import Observation

/// Disk persistence seam for the agent builder's prompt hints. The default
/// implementation uses `UserDefaults` (the app's lightweight key-value store,
/// matching other simple caches like `GlobalConvoDefaults`). Injectable so
/// tests and previews can supply an in-memory double.
struct PromptHintsDiskCache {
    let load: () -> [String]
    let save: ([String]) -> Void

    static let userDefaultsKey: String = "convos.agentBuilder.promptHints"

    /// Backed by `UserDefaults.standard`. Hints are short, low-cardinality
    /// strings, so a plain string-array default is the lightest fit.
    static var userDefaults: PromptHintsDiskCache {
        PromptHintsDiskCache(
            load: { UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? [] },
            save: { hints in UserDefaults.standard.set(hints, forKey: userDefaultsKey) }
        )
    }
}

/// In-memory cache of curated agent prompt hints. Owned at `MainTabView`
/// scope, prewarmed once on launch, and read by the agent builder's dice
/// control through the SwiftUI environment.
///
/// Mirrors `SuggestedAgentsModel`'s fetch/cache shape, with the two
/// differences the dice feature requires:
///   - the hints are persisted to disk and re-hydrated in-memory on launch, so
///     the dice can appear on a warm launch before the first network round-trip
///   - the network refresh retries with exponential backoff + jitter and never
///     clears the last good hints on a failed refetch
///
/// The in-memory `hints` is the single source of truth for dice visibility:
/// the dice is hidden whenever it is empty (see `AgentBuilderView.isDiceVisible`).
@Observable
@MainActor
final class PromptHintsModel {
    private let service: (any PromptHintsServiceProtocol)?
    private let store: PromptHintsDiskCache

    /// Seconds to wait before retry `attempt` (0-based). Defaults to the shared
    /// exponential-backoff-with-jitter curve; injectable so tests can drive the
    /// retry loop without real sleeps.
    @ObservationIgnored
    private let backoffSeconds: (Int) -> TimeInterval

    private(set) var hints: [String] = []

    @ObservationIgnored
    private var hasStartedLaunchLoad: Bool = false

    init(
        service: (any PromptHintsServiceProtocol)?,
        store: PromptHintsDiskCache = .userDefaults,
        backoffSeconds: @escaping (Int) -> TimeInterval = { TimeInterval.calculateExponentialBackoff(for: $0) }
    ) {
        self.service = service
        self.store = store
        self.backoffSeconds = backoffSeconds
        // Hydrate the in-memory copy from disk immediately so a warm launch can
        // show the dice without waiting for the network refresh below.
        self.hints = Self.sanitize(store.load())
    }

    /// True when a service is wired and the cache should refresh on launch.
    var isActive: Bool {
        service != nil
    }

    /// Fetch once per app launch. Disk hydration already happened in `init`, so
    /// this only refreshes from the network with exponential backoff + jitter,
    /// overwriting both memory and disk on success. Total failure leaves the
    /// hydrated hints untouched -- a failed refetch never clears a good cache.
    func loadOnLaunch() async {
        guard let service, !hasStartedLaunchLoad else { return }
        hasStartedLaunchLoad = true
        var attempt: Int = 0
        while attempt < Constant.maxAttempts {
            if Task.isCancelled { return }
            do {
                let fetched: [String] = try await service.promptHints()
                let sanitized: [String] = Self.sanitize(fetched)
                // Only overwrite when the fetch yields usable hints; an empty
                // payload should not wipe a previously good cache.
                if !sanitized.isEmpty {
                    hints = sanitized
                    store.save(sanitized)
                }
                return
            } catch {
                attempt += 1
                if attempt >= Constant.maxAttempts || Task.isCancelled {
                    Log.error("PromptHintsModel: fetch failed after \(attempt) attempt(s): \(error.localizedDescription)")
                    return
                }
                let delaySecs: TimeInterval = backoffSeconds(attempt - 1)
                if delaySecs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySecs * 1_000_000_000))
                }
            }
        }
    }

    /// Trim, drop empties, and clamp each hint to the backend's 350-char
    /// contract so a malformed row can't blow out the composer.
    private static func sanitize(_ raw: [String]) -> [String] {
        raw
            .map { (hint: String) -> String in
                let trimmed: String = hint.trimmingCharacters(in: .whitespacesAndNewlines)
                return String(trimmed.prefix(Constant.maxHintLength))
            }
            .filter { !$0.isEmpty }
    }

    private enum Constant {
        static let maxAttempts: Int = 5
        static let maxHintLength: Int = 350
    }
}
