import Foundation

/// Test/preview double for `SuggestedAgentsServiceProtocol`. Serves a fixed
/// list of pages in order and records the requested limits/cursors so tests
/// can assert paging behavior (initial page size, cursor threading).
public final class MockSuggestedAgentsService: SuggestedAgentsServiceProtocol, @unchecked Sendable {
    public private(set) var requestedLimits: [Int] = []
    public private(set) var requestedCursors: [String?] = []

    private let pages: [SuggestedAgentsPage]
    private var nextPageIndex: Int = 0
    private let delay: Duration?

    public init(pages: [SuggestedAgentsPage], delay: Duration? = nil) {
        self.pages = pages
        self.delay = delay
    }

    /// Single-page convenience: all agents in one page with no further cursor.
    public convenience init(agents: [SuggestedAgent], delay: Duration? = nil) {
        self.init(pages: [SuggestedAgentsPage(agents: agents, nextCursor: nil)], delay: delay)
    }

    public func featuredAgents(limit: Int, cursor: String?) async throws -> SuggestedAgentsPage {
        requestedLimits.append(limit)
        requestedCursors.append(cursor)
        if let delay {
            try await Task.sleep(for: delay)
        }
        guard nextPageIndex < pages.count else {
            return SuggestedAgentsPage(agents: [], nextCursor: nil)
        }
        let page = pages[nextPageIndex]
        nextPageIndex += 1
        return page
    }
}

public extension SuggestedAgent {
    static func mock(
        templateId: String = UUID().uuidString,
        name: String = "Mock Agent",
        description: String? = "A mock suggested agent",
        emoji: String? = "🤖",
        avatarURL: String? = nil
    ) -> SuggestedAgent {
        SuggestedAgent(
            templateId: templateId,
            name: name,
            description: description,
            emoji: emoji,
            avatarURL: avatarURL
        )
    }
}
