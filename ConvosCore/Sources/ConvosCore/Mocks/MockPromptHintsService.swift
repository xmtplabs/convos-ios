import Foundation

/// Test/preview double for `PromptHintsServiceProtocol`. Serves a fixed list
/// of hints (or throws a supplied error) and records the call count so tests
/// can assert fetch + retry behavior. Mirrors `MockSuggestedAgentsService`.
public final class MockPromptHintsService: PromptHintsServiceProtocol, @unchecked Sendable {
    public private(set) var fetchCount: Int = 0

    private let hints: [String]
    private let error: Error?
    private let delay: Duration?

    public init(
        hints: [String] = MockPromptHintsService.defaultHints,
        error: Error? = nil,
        delay: Duration? = nil
    ) {
        self.hints = hints
        self.error = error
        self.delay = delay
    }

    public func promptHints() async throws -> [String] {
        fetchCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error {
            throw error
        }
        return hints
    }

    public static let defaultHints: [String] = [
        "Plan a 3-day trip to Lisbon with a $1000 budget",
        "Draft a weekly meal plan and a grocery list",
        "Summarize long articles into five quick bullet points",
        "Be my daily Spanish conversation partner",
        "Track my workouts and suggest the next session",
    ]
}
