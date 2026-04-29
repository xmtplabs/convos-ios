import Foundation
#if canImport(Photos)
@preconcurrency import Photos
#endif

/// Bridges the user's photo library into `ConvosConnections` via PhotoKit.
///
/// Observes `PHPhotoLibraryChangeObserver` while the app is running; on each change it
/// re-fetches a small metadata window and emits a summary payload. No background delivery.
///
/// Volume control: the library is never dumped wholesale — we emit total counts plus a
/// bounded window of the most recent `recentLimit` assets with only metadata (never pixel
/// data). Location is included when the asset carries it.
public final class PhotosDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .photos
    public let recentLimit: Int

    public init(recentLimit: Int = 20) {
        self.recentLimit = recentLimit
        #if canImport(Photos)
        self.state = StateBox()
        #endif
    }

    #if canImport(Photos)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        let note: String? = {
            if case .partial = status {
                return "Limited library selected. Only user-picked assets are visible — change to All Photos in Settings to see the full library."
            }
            return nil
        }()
        return [
            AuthorizationDetail(
                identifier: "photo_library",
                displayName: "Photo Library",
                status: status,
                note: note
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        await state.start(emit: emit, recentLimit: recentLimit)
    }

    public func stop() async {
        await state.stop()
    }

    public func snapshotCurrent() async throws -> PhotosPayload {
        Self.buildPayload(recentLimit: recentLimit)
    }

    static func map(_ status: PHAuthorizationStatus) -> ConnectionAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .partial(missing: ["full-library"])
        @unknown default: return .notDetermined
        }
    }

    static func buildPayload(recentLimit: Int) -> PhotosPayload {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let allAssets = PHAsset.fetchAssets(with: options)
        let total = allAssets.count
        var photoCount = 0
        var videoCount = 0
        var screenshotCount = 0
        var livePhotoCount = 0

        allAssets.enumerateObjects { asset, _, _ in
            switch asset.mediaType {
            case .image: photoCount += 1
            case .video: videoCount += 1
            default: break
            }
            if asset.mediaSubtypes.contains(.photoScreenshot) { screenshotCount += 1 }
            if asset.mediaSubtypes.contains(.photoLive) { livePhotoCount += 1 }
        }

        let recentOptions = PHFetchOptions()
        recentOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        recentOptions.fetchLimit = recentLimit
        let recentFetch = PHAsset.fetchAssets(with: recentOptions)

        var recent: [PhotoAssetSummary] = []
        recentFetch.enumerateObjects { asset, _, _ in
            recent.append(
                PhotoAssetSummary(
                    id: asset.localIdentifier,
                    mediaType: map(mediaType: asset.mediaType),
                    subtype: map(subtypes: asset.mediaSubtypes),
                    creationDate: asset.creationDate,
                    isFavorite: asset.isFavorite,
                    latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude
                )
            )
        }

        var summaryParts: [String] = ["\(total) asset\(total == 1 ? "" : "s")"]
        if photoCount > 0 { summaryParts.append("\(photoCount) photo\(photoCount == 1 ? "" : "s")") }
        if videoCount > 0 { summaryParts.append("\(videoCount) video\(videoCount == 1 ? "" : "s")") }

        return PhotosPayload(
            summary: summaryParts.joined(separator: ", "),
            totalAssetCount: total,
            photoCount: photoCount,
            videoCount: videoCount,
            screenshotCount: screenshotCount,
            livePhotoCount: livePhotoCount,
            recentAssets: recent
        )
    }

    private static func map(mediaType: PHAssetMediaType) -> PhotoMediaType {
        switch mediaType {
        case .image: return .photo
        case .video: return .video
        case .audio: return .audio
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    private static func map(subtypes: PHAssetMediaSubtype) -> PhotoMediaSubtype {
        if subtypes.contains(.photoScreenshot) { return .screenshot }
        if subtypes.contains(.photoLive) { return .livePhoto }
        if subtypes.contains(.photoPanorama) { return .panorama }
        if subtypes.contains(.photoHDR) { return .hdr }
        if subtypes.contains(.videoHighFrameRate) { return .slomo }
        if subtypes.contains(.videoTimelapse) { return .timelapse }
        return .none
    }

    private actor StateBox {
        private var observer: ChangeObserver?
        private var emitter: ConnectionPayloadEmitter?
        private var recentLimit: Int = 20

        func start(emit: @escaping ConnectionPayloadEmitter, recentLimit: Int) async {
            if observer != nil { return }
            self.emitter = emit
            self.recentLimit = recentLimit

            let observer = ChangeObserver(state: self)
            PHPhotoLibrary.shared().register(observer)
            self.observer = observer

            emitCurrent()
        }

        func stop() async {
            if let observer {
                PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            }
            observer = nil
            emitter = nil
        }

        fileprivate func onLibraryChange() {
            emitCurrent()
        }

        private func emitCurrent() {
            guard let emitter else { return }
            let payload = PhotosDataSource.buildPayload(recentLimit: recentLimit)
            emitter(ConnectionPayload(source: .photos, body: .photos(payload)))
        }
    }

    private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        weak var state: StateBox?

        init(state: StateBox) {
            self.state = state
        }

        func photoLibraryDidChange(_ changeInstance: PHChange) {
            let ref = state
            Task { await ref?.onLibraryChange() }
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotCurrent() async throws -> PhotosPayload {
        PhotosPayload(
            summary: "Photos not available.",
            totalAssetCount: 0,
            photoCount: 0,
            videoCount: 0,
            screenshotCount: 0,
            livePhotoCount: 0,
            recentAssets: []
        )
    }
    #endif
}
