import Foundation
#if canImport(MediaPlayer) && os(iOS)
@preconcurrency import MediaPlayer
#endif

/// Write-side counterpart to `MusicDataSource`.
///
/// Drives `MPMusicPlayerController.systemMusicPlayer` directly. Transport controls don't
/// require additional authorization — iOS allows any app to drive the shared player.
/// Only `queue_store_items` needs `MPMediaLibrary.authorizationStatus()` to be authorized.
public final class MusicDataSink: DataSink, @unchecked Sendable {
    public let kind: ConnectionKind = .music

    public init() {}

    public func actionSchemas() async -> [ActionSchema] {
        MusicActionSchemas.all
    }

    #if canImport(MediaPlayer) && os(iOS)
    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        MusicDataSource.map(MPMediaLibrary.authorizationStatus())
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let status: MPMediaLibraryAuthorizationStatus = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return MusicDataSource.map(status)
    }

    @MainActor
    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        let player = MPMusicPlayerController.systemMusicPlayer
        switch invocation.action.name {
        case MusicActionSchemas.play.actionName:
            player.play()
            return Self.makeResult(for: invocation, status: .success)
        case MusicActionSchemas.pause.actionName:
            player.pause()
            return Self.makeResult(for: invocation, status: .success)
        case MusicActionSchemas.skipToNext.actionName:
            player.skipToNextItem()
            return Self.makeResult(for: invocation, status: .success)
        case MusicActionSchemas.skipToPrevious.actionName:
            player.skipToPreviousItem()
            return Self.makeResult(for: invocation, status: .success)
        case MusicActionSchemas.queueStoreItems.actionName:
            return queueStoreItems(invocation, player: player)
        default:
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "Music sink does not know action '\(invocation.action.name)'."
            )
        }
    }

    @MainActor
    private func queueStoreItems(_ invocation: ConnectionInvocation, player: MPMusicPlayerController) -> ConnectionInvocationResult {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Media library authorization is required for queuing store items.")
        }
        guard case .array(let values) = invocation.action.arguments["storeIds"] ?? .null else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'storeIds' (expected an array of strings).")
        }
        let storeIds = values.compactMap(\.stringValue)
        guard !storeIds.isEmpty else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "'storeIds' must contain at least one identifier.")
        }

        let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: storeIds)
        player.setQueue(with: descriptor)
        player.play()

        return Self.makeResult(
            for: invocation,
            status: .success,
            result: ["queuedCount": .int(storeIds.count)]
        )
    }

    private static func makeResult(
        for invocation: ConnectionInvocation,
        status: ConnectionInvocationResult.Status,
        errorMessage: String? = nil,
        result: [String: ArgumentValue] = [:]
    ) -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: status,
            result: result,
            errorMessage: errorMessage
        )
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: .music,
            actionName: invocation.action.name,
            status: .executionFailed,
            errorMessage: "MediaPlayer not available on this platform."
        )
    }
    #endif
}
