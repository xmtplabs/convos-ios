import Combine
import Foundation
import GRDB

/// The list filter the conversations screen exposes. Mirrors the view
/// model's `ConversationFilter`; lives in Core so the pager can push the
/// predicate into SQL instead of filtering a partial window in memory.
public enum ConversationsListFilter: Equatable, Sendable {
    case all
    case unread
    case exploding
}

/// One emission of the paged conversations list.
public struct ConversationsPage: Equatable, Sendable {
    /// Every pinned row, unlimited and unfiltered - bounded by the pin
    /// limit (see `ConversationLocalStateWriter.maxPinnedConversations`),
    /// so it never needs the window treatment. The view model applies the
    /// active filter and the `pinnedOrder` sort, same as before.
    public let pinned: [Conversation]
    /// The filtered, windowed unpinned rows in list order.
    public let unpinned: [Conversation]
    /// Whether rows exist beyond the current window.
    public let hasMore: Bool
    /// Whether any unpinned row exists ignoring the filter - drives the
    /// "nothing matches this filter" (vs "no conversations") empty states.
    public let hasAnyUnpinned: Bool

    public static let empty: ConversationsPage = ConversationsPage(
        pinned: [],
        unpinned: [],
        hasMore: false,
        hasAnyUnpinned: false
    )
}

/// A growing-window pager over the conversations list.
///
/// One live GRDB observation whose query carries `LIMIT <window>`; the
/// window grows on `loadMore()` and resets when `filter` changes. Growing
/// swaps the inner observation (cheap - GRDB re-subscribes and re-emits),
/// while `pagePublisher` stays a single stable publisher via
/// `switchToLatest`. Callers gate `loadMore()` on the latest page's
/// `hasMore` plus their own in-flight flag; the pager itself is
/// deliberately stateless about emissions.
public protocol ConversationsPagerProtocol: AnyObject {
    var pagePublisher: AnyPublisher<ConversationsPage, Never> { get }
    /// Setting resets the window to the first page.
    var filter: ConversationsListFilter { get set }
    /// Grow the window by one page.
    func loadMore()
    /// One-shot first-page read for the cold-start prime
    /// (`BoundedInitialRead`), bypassing the observation machinery.
    func fetchInitialPage() throws -> ConversationsPage
    /// A single conversation by id under the same list-eligibility filters
    /// as the page. Nil means gone from the list's perspective (deleted,
    /// removed, blocked, expired), not merely outside the window.
    func fetchConversation(id: String) throws -> Conversation?
}

final class ConversationsPager: ConversationsPagerProtocol {
    private struct PageRequest: Equatable {
        var filter: ConversationsListFilter
        var limit: Int
        /// Bumped after an observation error so the resend survives
        /// `removeDuplicates` and spawns a fresh inner observation.
        var generation: Int = 0
    }

    private let dbReader: any DatabaseReader
    private let consent: [Consent]
    private let pageSize: Int
    private let throttleInterval: TimeInterval
    private let requestSubject: CurrentValueSubject<PageRequest, Never>

    let pagePublisher: AnyPublisher<ConversationsPage, Never>

    /// `throttleInterval` matches `ConversationsRepository`'s: leading-edge
    /// delivery coalescing during write bursts, applied per inner
    /// observation so a window change always emits promptly.
    /// `observationRetryDelay` spaces the resubscribe attempts after an
    /// observation error; see `scheduleRetry`.
    init(
        dbReader: any DatabaseReader,
        consent: [Consent],
        pageSize: Int = 60,
        throttleInterval: TimeInterval = 0.3,
        observationRetryDelay: TimeInterval = 1
    ) {
        self.dbReader = dbReader
        self.consent = consent
        self.pageSize = pageSize
        self.throttleInterval = throttleInterval
        let subject = CurrentValueSubject<PageRequest, Never>(
            PageRequest(filter: .all, limit: pageSize)
        )
        self.requestSubject = subject
        self.pagePublisher = subject
            .removeDuplicates()
            .map { (request: PageRequest) -> AnyPublisher<ConversationsPage, Never> in
                Self.observationPublisher(
                    dbReader: dbReader,
                    consent: consent,
                    request: request,
                    throttleInterval: throttleInterval,
                    onError: {
                        Self.scheduleRetry(of: request, on: subject, after: observationRetryDelay)
                    }
                )
            }
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    var filter: ConversationsListFilter {
        get { requestSubject.value.filter }
        set {
            guard newValue != requestSubject.value.filter else { return }
            var request = requestSubject.value
            request.filter = newValue
            request.limit = pageSize
            requestSubject.send(request)
        }
    }

    func loadMore() {
        var request = requestSubject.value
        request.limit += pageSize
        requestSubject.send(request)
    }

    func fetchInitialPage() throws -> ConversationsPage {
        let request = requestSubject.value
        return try dbReader.read { db in
            try db.composeConversationsPage(
                consent: self.consent,
                filter: request.filter,
                limit: request.limit
            )
        }
    }

    func fetchConversation(id: String) throws -> Conversation? {
        try dbReader.read { db in
            try db.composeListConversation(id: id, consent: self.consent)
        }
    }

    private static func observationPublisher(
        dbReader: any DatabaseReader,
        consent: [Consent],
        request: PageRequest,
        throttleInterval: TimeInterval,
        onError: @escaping () -> Void
    ) -> AnyPublisher<ConversationsPage, Never> {
        let base: AnyPublisher<ConversationsPage, Never> = ValueObservation
            .tracking { db in
                do {
                    return try db.composeConversationsPage(
                        consent: consent,
                        filter: request.filter,
                        limit: request.limit
                    )
                } catch {
                    Log.error("Error composing conversations page: \(error)")
                    throw error
                }
            }
            // The tracked region spans every conversation-related table, so
            // an unrelated write would re-emit an identical page.
            .removeDuplicates()
            .publisher(in: dbReader)
            // An error terminates the observation, and a substituted value
            // (replaceError) would both blank the list and complete this
            // inner publisher, leaving switchToLatest frozen with nothing
            // to re-trigger it. Keep the last delivered page on screen and
            // let the caller resubscribe with a fresh observation instead.
            .catch { (error: any Error) -> Empty<ConversationsPage, Never> in
                Log.error("Conversations page observation failed, scheduling retry: \(error)")
                onError()
                return Empty(completeImmediately: false)
            }
            .eraseToAnyPublisher()
        guard throttleInterval > 0 else { return base }
        return base
            .throttle(for: .seconds(throttleInterval), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
    }

    /// Resubscribes after an observation error by resending the failed
    /// request with a bumped generation. Skipped when a newer request has
    /// already replaced the failed one - its observation is unaffected by
    /// the error - and when the pager itself is gone.
    private static func scheduleRetry(
        of request: PageRequest,
        on subject: CurrentValueSubject<PageRequest, Never>,
        after delay: TimeInterval
    ) {
        let box = WeakRequestSubjectBox(subject: subject)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let subject = box.subject, subject.value == request else { return }
            var next = request
            next.generation += 1
            subject.send(next)
        }
    }

    /// Combine subjects are thread-safe for `send` but carry no Sendable
    /// annotation; the weak reference also lets a deallocated pager drop
    /// its pending retry instead of being kept alive by the dispatch queue.
    private struct WeakRequestSubjectBox: @unchecked Sendable {
        weak var subject: CurrentValueSubject<PageRequest, Never>?
    }
}
