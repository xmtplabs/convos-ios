import AVFoundation
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum VideoCompressionError: Error {
    case exportSessionCreationFailed
    case exportFailed(String)
    case fileTooLarge(bytes: Int64, maxBytes: Int64)
    case thumbnailGenerationFailed
    case invalidAsset
}

public struct CompressedVideo: Sendable {
    public let fileURL: URL
    public let fileSize: Int64
    public let duration: Double
    public let width: Int
    public let height: Int
    public let thumbnail: Data
    public let mimeType: String

    public init(
        fileURL: URL,
        fileSize: Int64,
        duration: Double,
        width: Int,
        height: Int,
        thumbnail: Data,
        mimeType: String
    ) {
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.duration = duration
        self.width = width
        self.height = height
        self.thumbnail = thumbnail
        self.mimeType = mimeType
    }
}

public protocol VideoCompressionServiceProtocol: Sendable {
    func compressVideo(at sourceURL: URL) async throws -> CompressedVideo
    func generateThumbnail(for asset: AVAsset) async throws -> Data
}

public final class VideoCompressionService: VideoCompressionServiceProtocol, Sendable {
    public static let maxFileSizeBytes: Int64 = 25 * 1024 * 1024
    private static let thumbnailMaxDimension: CGFloat = 200

    public init() {}

    public func compressVideo(at sourceURL: URL) async throws -> CompressedVideo {
        let asset = AVURLAsset(url: sourceURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCompressionError.invalidAsset
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        let videoWidth = Int(abs(transformedSize.width))
        let videoHeight = Int(abs(transformedSize.height))
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        let thumbnail = try await generateThumbnail(for: asset)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("video_\(UUID().uuidString).mp4")

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetMediumQuality
        ) else {
            throw VideoCompressionError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            break
        case .failed:
            let errorMessage = exportSession.error?.localizedDescription ?? "unknown error"
            throw VideoCompressionError.exportFailed(errorMessage)
        case .cancelled:
            throw VideoCompressionError.exportFailed("export cancelled")
        default:
            throw VideoCompressionError.exportFailed("unexpected status: \(exportSession.status.rawValue)")
        }

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0

        if fileSize > Self.maxFileSizeBytes {
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoCompressionError.fileTooLarge(bytes: fileSize, maxBytes: Self.maxFileSizeBytes)
        }

        return CompressedVideo(
            fileURL: outputURL,
            fileSize: fileSize,
            duration: durationSeconds,
            width: videoWidth,
            height: videoHeight,
            thumbnail: thumbnail,
            mimeType: "video/mp4"
        )
    }

    public func generateThumbnail(for asset: AVAsset) async throws -> Data {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(
            width: Self.thumbnailMaxDimension,
            height: Self.thumbnailMaxDimension
        )

        let cgImage: CGImage
        do {
            let (image, _) = try await imageGenerator.image(at: .zero)
            cgImage = image
        } catch {
            throw VideoCompressionError.thumbnailGenerationFailed
        }

        #if os(macOS)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw VideoCompressionError.thumbnailGenerationFailed
        }
        return jpegData
        #else
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.7) else {
            throw VideoCompressionError.thumbnailGenerationFailed
        }
        return jpegData
        #endif
    }
}
