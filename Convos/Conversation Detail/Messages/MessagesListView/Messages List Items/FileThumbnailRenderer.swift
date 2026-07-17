import ConvosCore
import ConvosLogging
import QuickLookThumbnailing
import UIKit

@MainActor
final class FileThumbnailRenderer {
    static let shared: FileThumbnailRenderer = FileThumbnailRenderer()

    struct Result: Sendable {
        let image: UIImage
        let isContentThumbnail: Bool
    }

    private static let renderSize: CGSize = CGSize(width: 720, height: 1200)

    private var inflight: [String: Task<Result?, Never>] = [:]

    nonisolated static func cacheKey(for attachmentKey: String) -> String {
        "file-thumb-v1-" + attachmentKey
    }

    nonisolated private static func contentMetadataKey(for attachmentKey: String) -> String {
        "file-thumb-iscontent-v1-" + attachmentKey
    }

    func cachedThumbnail(for attachmentKey: String) -> Result? {
        guard let image = ImageCache.shared.image(for: Self.cacheKey(for: attachmentKey)) else { return nil }
        let isContent = UserDefaults.standard.bool(forKey: Self.contentMetadataKey(for: attachmentKey))
        return Result(image: image, isContentThumbnail: isContent)
    }

    func thumbnail(for attachmentKey: String, fileURL: URL) async -> Result? {
        let cacheKey = Self.cacheKey(for: attachmentKey)
        if let cachedImage = await ImageCache.shared.imageAsync(for: cacheKey) {
            let isContent = UserDefaults.standard.bool(forKey: Self.contentMetadataKey(for: attachmentKey))
            return Result(image: cachedImage, isContentThumbnail: isContent)
        }

        if let existing = inflight[attachmentKey] {
            return await existing.value
        }

        let task = Task<Result?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.renderThumbnail(attachmentKey: attachmentKey, fileURL: fileURL)
        }
        inflight[attachmentKey] = task
        let result = await task.value
        inflight.removeValue(forKey: attachmentKey)
        return result
    }

    private func renderThumbnail(attachmentKey: String, fileURL: URL) async -> Result? {
        let scale = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.scale) ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: Self.renderSize,
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )

        return await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let error {
                    Log.error("FileThumbnailRenderer failed for \(attachmentKey): \(error)")
                }
                guard let representation else {
                    continuation.resume(returning: nil)
                    return
                }
                let isContent: Bool
                switch representation.type {
                case .thumbnail, .lowQualityThumbnail:
                    isContent = true
                case .icon:
                    isContent = false
                @unknown default:
                    isContent = false
                }
                let image = representation.uiImage
                ImageCache.shared.cacheImage(image, for: Self.cacheKey(for: attachmentKey), storageTier: .cache)
                UserDefaults.standard.set(isContent, forKey: Self.contentMetadataKey(for: attachmentKey))
                continuation.resume(returning: Result(image: image, isContentThumbnail: isContent))
            }
        }
    }
}
