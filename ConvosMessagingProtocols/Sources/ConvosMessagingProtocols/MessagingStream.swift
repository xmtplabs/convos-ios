import Foundation

// MARK: - Stream typealias

/// Unified stream type used across conversation + message subscriptions.
///
/// Current Convos code (`XMTPClientProvider.swift:107,122`,
/// `SyncingManager.swift`, `StreamProcessor`) uses
/// `AsyncThrowingStream<XMTPiOS.T, Error>` directly. This typealias is
/// the one-line seam the Stage 2 adapters can point at without every
/// call site having to think about errors or back-pressure.
public typealias MessagingStream<Element: Sendable> = AsyncThrowingStream<Element, Error>
