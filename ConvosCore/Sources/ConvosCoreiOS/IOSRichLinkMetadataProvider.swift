#if canImport(UIKit)
import ConvosCore
import Foundation
import LinkPresentation
import UIKit
import UniformTypeIdentifiers

public final class IOSRichLinkMetadataProvider: RichLinkMetadataProviding, Sendable {
    public init() {}

    public func fetchMetadata(for url: URL) async -> OpenGraphService.OpenGraphMetadata? {
        guard !LinkPreview.isPrivateHost(url) else {
            Log.warning("RichLink rejected private host: \(url)")
            return nil
        }

        do {
            let extracted = try await fetchLinkMetadata(for: url)

            var imageURL: String?
            if let imageProvider = extracted.imageProvider {
                imageURL = try? await extractImageURL(from: imageProvider, originalURL: url)
            }

            guard extracted.title != nil || imageURL != nil else { return nil }

            return OpenGraphService.OpenGraphMetadata(
                title: extracted.title,
                imageURL: imageURL,
                siteName: url.host,
                imageWidth: nil,
                imageHeight: nil
            )
        } catch {
            Log.error("RichLink fetch failed for \(url): \(error)")
            return nil
        }
    }

    private struct ExtractedMetadata: @unchecked Sendable {
        let title: String?
        let imageProvider: NSItemProvider?
    }

    private func fetchLinkMetadata(for url: URL) async throws -> ExtractedMetadata {
        try await withCheckedThrowingContinuation { continuation in
            let provider = LPMetadataProvider()
            provider.startFetchingMetadata(for: url) { metadata, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let metadata {
                    let extracted = ExtractedMetadata(
                        title: metadata.title,
                        imageProvider: metadata.imageProvider
                    )
                    continuation.resume(returning: extracted)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "IOSRichLinkMetadataProvider",
                            code: -1
                        )
                    )
                }
            }
        }
    }

    private func extractImageURL(
        from provider: NSItemProvider,
        originalURL: URL
    ) async throws -> String? {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(
                        throwing: error ?? NSError(
                            domain: "IOSRichLinkMetadataProvider",
                            code: -2
                        )
                    )
                }
            }
        }

        guard OpenGraphService.isValidImageData(data) else { return nil }
        guard let image = UIImage(data: data),
              OpenGraphService.isValidImageSize(width: image.size.width, height: image.size.height)
        else { return nil }

        let imageURL = originalURL.absoluteString
        ImageCache.shared.cacheImage(image, for: imageURL, storageTier: .cache)

        return imageURL
    }
}
#endif
