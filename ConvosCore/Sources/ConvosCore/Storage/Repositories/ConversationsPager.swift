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
    init(
        dbReader: any DatabaseReader,
        consent: [Consent],
        pageSize: Int = 60,
        throttleInterval: TimeInterval = 0.3
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
                    throttleInterval: throttleInterval
                )
            }
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    var filter: ConversationsListFilter {
        get { requestSubject.value.filter }
        set {
            guard newValue != requestSubject.value.filter else { return }
            requestSubject.send(PageRequest(filter: newValue, limit: pageSize))
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
        throttleInterval: TimeInterval
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
            .replaceError(with: .empty)
            .eraseToAnyPublisher()
        guard throttleInterval > 0 else { return base }
        return base
            .throttle(for: .seconds(throttleInterval), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
    }
}
