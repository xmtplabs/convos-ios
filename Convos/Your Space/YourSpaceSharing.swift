import ConvosCore
import Foundation
import UIKit
import UniformTypeIdentifiers

enum ConvosDocShare {
    static let phoneNumber: String = "+1 309-555-5555"
    static let smsURL: URL = URL(string: "sms:+13095555555")!
    static let invitation: String = "Made by Convos — you can text @doc directly at \(phoneNumber) to add anything or ask anything about this doc. You can also add me to your group chat to remember, share, research, or add anything to this group."

    static func applies(to kind: YourSpaceContextKind) -> Bool {
        [.file, .note, .link].contains(kind)
    }
}

@MainActor
protocol YourSpaceDraftStaging: AnyObject {
    var messageText: String { get set }
    func addPhotoAttachment(_ image: UIImage)
    func addVideoAttachment(url: URL)
    func addFileAttachment(url: URL, filename: String, mimeType: String, fileSize: Int)
}

extension ConversationViewModel: YourSpaceDraftStaging {}

struct YourSpaceShareStager {
    typealias PreviewLoader = @Sendable (_ key: String, _ filename: String) async throws -> URL

    static let live: YourSpaceShareStager = .init { key, filename in
        try await FileAttachmentPreviewLoader.loadPreviewURL(key: key, filename: filename)
    }

    private let loadPreviewURL: PreviewLoader

    init(loadPreviewURL: @escaping PreviewLoader) {
        self.loadPreviewURL = loadPreviewURL
    }

    @MainActor
    func stage(_ item: YourSpaceContextItem, in composer: any YourSpaceDraftStaging) async throws {
        if ConvosDocShare.applies(to: item.kind),
           !composer.messageText.contains(ConvosDocShare.invitation) {
            append(ConvosDocShare.invitation, to: composer)
        }

        switch item.source {
        case let .local(file):
            try stageLocal(file, kind: item.kind, in: composer)
        case let .conversation(context):
            try await stageConversationContext(context, kind: item.kind, in: composer)
        case let .rememberedField(field):
            append(field.shareText, to: composer)
        }

    }

    @MainActor
    private func stageLocal(
        _ file: YourSpaceStoredFile,
        kind: YourSpaceContextKind,
        in composer: any YourSpaceDraftStaging
    ) throws {
        if kind == .note || kind == .link,
           let text = try? String(contentsOf: file.url, encoding: .utf8) {
            append(text, to: composer)
            return
        }
        if kind == .photo,
           let image = UIImage(contentsOfFile: file.url.path) {
            composer.addPhotoAttachment(image)
            return
        }
        let url = try YourSpaceFileStore.temporaryCopy(of: file)
        if kind == .video {
            composer.addVideoAttachment(url: url)
            return
        }
        let mimeType = UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        composer.addFileAttachment(
            url: url,
            filename: file.name,
            mimeType: mimeType,
            fileSize: file.byteCount
        )
    }

    @MainActor
    private func stageConversationContext(
        _ context: ContextLibraryItem,
        kind: YourSpaceContextKind,
        in composer: any YourSpaceDraftStaging
    ) async throws {
        if kind == .link, let url = context.destinationURLString {
            append(url, to: composer)
            return
        }
        if [.address, .phone, .email].contains(kind) {
            append(context.title, to: composer)
            return
        }
        guard let key = context.attachmentKey else {
            throw YourSpaceShareError.missingAttachment
        }
        let filename = context.filename ?? context.title
        let url = try await loadPreviewURL(key, filename)
        if kind == .note,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            append(text, to: composer)
            return
        }
        if kind == .photo, let image = UIImage(contentsOfFile: url.path) {
            composer.addPhotoAttachment(image)
            return
        }
        if kind == .video {
            composer.addVideoAttachment(url: url)
            return
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        composer.addFileAttachment(
            url: url,
            filename: filename,
            mimeType: context.mimeType ?? "application/octet-stream",
            fileSize: values?.fileSize ?? 0
        )
    }

    @MainActor
    private func append(_ value: String, to composer: any YourSpaceDraftStaging) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composer.messageText = composer.messageText.isEmpty
            ? trimmed
            : "\(composer.messageText)\n\(trimmed)"
    }
}

enum YourSpaceShareError: LocalizedError {
    case composerUnavailable
    case missingAttachment

    var errorDescription: String? {
        switch self {
        case .composerUnavailable: "That convo is not ready yet. Try again in a moment."
        case .missingAttachment: "The original item is not available on this device."
        }
    }
}
