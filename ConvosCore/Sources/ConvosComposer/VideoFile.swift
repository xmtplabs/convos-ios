#if canImport(UIKit)
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct VideoFile: Transferable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let outputURL = tempDir.appendingPathComponent("video_\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: outputURL)
            return VideoFile(url: outputURL)
        }
    }
}
#endif
