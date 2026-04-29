import Foundation

/// Static `ActionSchema` values published by `MusicDataSink`.
///
/// All actions target `MPMusicPlayerController.systemMusicPlayer` — the same player
/// observed by `MusicDataSource`. Third-party apps (Spotify, YouTube Music) are not
/// reachable through this API.
///
/// `queue_store_items` requires `MPMediaLibraryAuthorizationStatus.authorized`, queues a
/// set of Apple Music store product identifiers, and starts playback. For local library
/// items, agents should use persistent-id queuing via a future expansion.
public enum MusicActionSchemas {
    public static let play: ActionSchema = ActionSchema(
        kind: .music,
        actionName: "play",
        capability: .writeUpdate,
        summary: "Resume playback on the system music player.",
        inputs: [],
        outputs: []
    )

    public static let pause: ActionSchema = ActionSchema(
        kind: .music,
        actionName: "pause",
        capability: .writeUpdate,
        summary: "Pause playback on the system music player.",
        inputs: [],
        outputs: []
    )

    public static let skipToNext: ActionSchema = ActionSchema(
        kind: .music,
        actionName: "skip_to_next",
        capability: .writeUpdate,
        summary: "Skip to the next track in the queue.",
        inputs: [],
        outputs: []
    )

    public static let skipToPrevious: ActionSchema = ActionSchema(
        kind: .music,
        actionName: "skip_to_previous",
        capability: .writeUpdate,
        summary: "Skip to the previous track in the queue.",
        inputs: [],
        outputs: []
    )

    public static let queueStoreItems: ActionSchema = ActionSchema(
        kind: .music,
        actionName: "queue_store_items",
        capability: .writeCreate,
        summary: "Queue one or more Apple Music store product IDs and begin playback.",
        inputs: [
            ActionParameter(name: "storeIds", type: .arrayOf(.string), description: "Apple Music store identifiers.", isRequired: true),
        ],
        outputs: [
            ActionParameter(name: "queuedCount", type: .int, description: "Number of items queued.", isRequired: true),
        ]
    )

    public static let all: [ActionSchema] = [play, pause, skipToNext, skipToPrevious, queueStoreItems]
}
