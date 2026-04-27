import Foundation

// MARK: - Stream typealias

/// Unified stream type used across conversation + message subscriptions.
///
/// `SyncingManager` and `StreamProcessor` consume conversation /
/// message subscriptions as `AsyncThrowingStream<Element, Error>`. This
/// typealias is the one-line seam adapters point at without every call
/// site having to think about errors or back-pressure.
public typealias MessagingStream<Element: Sendable> = AsyncThrowingStream<Element, Error>
