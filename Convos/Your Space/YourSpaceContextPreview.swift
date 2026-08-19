import AVFoundation
import ConvosCore
import ConvosCoreiOS
import MapKit
import QuickLookThumbnailing
import SwiftUI
import UIKit

struct YourSpaceContextPreview: View {
    let item: YourSpaceContextItem

    @State private var previewImage: UIImage?
    @State private var previewText: String?
    @State private var audioDuration: String?
    @State private var isLoading: Bool = true

    init(item: YourSpaceContextItem) {
        self.item = item
        _previewImage = State(initialValue: Self.immediateImage(for: item))
        _previewText = State(initialValue: item.detail)
    }

    var body: some View {
        ZStack {
            background

            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else if item.kind == .voice {
                voicePreview
            } else if let previewText, !previewText.isEmpty {
                textPreview(previewText)
            } else if item.kind == .link {
                linkFallback
            } else if isLoading {
                ProgressView()
                    .tint(.colorTextSecondary)
            } else {
                fileFallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: item.id) {
            await hydratePreview()
        }
        .accessibilityHidden(true)
    }

    private var background: Color {
        switch item.kind {
        case .photo, .video: .colorBackgroundMedia
        case .link, .address: .colorFillTertiary
        case .voice: Color.colorLava.opacity(0.16)
        case .phone, .email, .detail, .note: .colorFillMinimal
        case .file, .all: .colorFillSubtle
        }
    }

    private var voicePreview: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            HStack(alignment: .center, spacing: DesignConstants.Spacing.stepHalf) {
                ForEach(Self.waveformHeights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.colorLava)
                        .frame(width: 3, height: Self.waveformHeights[index])
                }
            }
            Text(audioDuration ?? "Voice note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private func textPreview(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.colorTextPrimary)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DesignConstants.Spacing.step3x)
    }

    private var linkFallback: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            Text(linkHost.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
            Text(item.title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(DesignConstants.Spacing.step3x)
    }

    private var fileFallback: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            Text(fileTypeLabel)
                .font(.title3.weight(.bold))
                .foregroundStyle(.colorTextPrimary)
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(DesignConstants.Spacing.step3x)
    }

    private var linkHost: String {
        guard case let .conversation(context) = item.source,
              let urlString = context.destinationURLString,
              let host = URL(string: urlString)?.host else {
            return "Saved link"
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private var fileTypeLabel: String {
        let pathExtension = (item.title as NSString).pathExtension
        if !pathExtension.isEmpty { return pathExtension.uppercased() }
        return item.kind.title
    }

    @MainActor
    private func hydratePreview() async {
        defer { isLoading = false }

        switch item.source {
        case let .rememberedField(field):
            previewText = field.info
            if field.category == .address {
                previewImage = await YourSpacePreviewLoader.mapSnapshot(for: field.info)
            }

        case let .local(file):
            await hydrateFile(at: file.url, kind: item.kind, cacheKey: nil)

        case let .conversation(context):
            if item.kind == .link {
                await hydrateLink(context)
                return
            }

            if let key = context.attachmentKey,
               let cached = await ImageCache.shared.imageAsync(for: key) {
                previewImage = cached
                return
            }

            guard let key = context.attachmentKey else { return }
            do {
                let url = try await FileAttachmentPreviewLoader.loadPreviewURL(
                    key: key,
                    filename: context.filename ?? context.title
                )
                await hydrateFile(at: url, kind: item.kind, cacheKey: key)
            } catch {
                return
            }
        }
    }

    @MainActor
    private func hydrateFile(at url: URL, kind: YourSpaceContextKind, cacheKey: String?) async {
        switch kind {
        case .note:
            previewText = await YourSpacePreviewLoader.textPreview(at: url)
        case .voice:
            audioDuration = await YourSpacePreviewLoader.audioDuration(at: url)
        default:
            if let image = await YourSpacePreviewLoader.thumbnail(at: url) {
                previewImage = image
                if let cacheKey {
                    ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
                }
            }
        }
    }

    @MainActor
    private func hydrateLink(_ context: ContextLibraryItem) async {
        if let destination = context.destinationURLString,
           let destinationURL = URL(string: destination),
           Self.isSafeWebURL(destinationURL),
           Self.isMapLink(destinationURL),
           let map = await YourSpacePreviewLoader.mapSnapshot(for: item.title) {
            previewImage = map
            return
        }

        var imageCandidates: [String] = []
        if let imageURL = context.imageURLString {
            imageCandidates.append(imageURL)
        }

        if let destination = context.destinationURLString,
           let destinationURL = URL(string: destination),
           Self.isSafeWebURL(destinationURL),
           let metadata = await OpenGraphService.shared.fetchMetadata(for: destination),
           let imageURL = metadata.imageURL,
           !imageCandidates.contains(imageURL) {
            imageCandidates.append(imageURL)
        }

        for candidate in imageCandidates {
            if let cached = await ImageCache.shared.imageAsync(for: candidate) {
                previewImage = cached
                return
            }
            if let cached = await ImageCache.shared.imageAsync(forURL: candidate) {
                previewImage = cached
                return
            }

            guard candidate != context.destinationURLString,
                  let url = URL(string: candidate),
                  Self.isSafeWebURL(url),
                  let image = await OpenGraphService.shared.loadImage(from: url) else {
                continue
            }
            ImageCache.shared.cacheImage(image, for: candidate, storageTier: .cache)
            previewImage = image
            return
        }
    }

    private static func immediateImage(for item: YourSpaceContextItem) -> UIImage? {
        guard case let .conversation(context) = item.source else { return nil }
        if let base64 = context.thumbnailDataBase64,
           let data = Data(base64Encoded: base64),
           let image = UIImage(data: data) {
            return image
        }
        if let key = context.attachmentKey,
           let image = ImageCache.shared.image(for: key) {
            return image
        }
        if let imageURL = context.imageURLString {
            return ImageCache.shared.image(for: imageURL)
        }
        return nil
    }

    private static func isMapLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("maps.apple")
            || host.contains("google") && url.path.lowercased().contains("maps")
            || host == "maps.app.goo.gl"
            || host == "goo.gl" && url.path.lowercased().contains("maps")
    }

    private static func isSafeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return !LinkPreview.isPrivateHost(url)
    }

    private static let waveformHeights: [CGFloat] = [12, 24, 36, 20, 42, 30, 16, 34, 22, 12]
}

private enum YourSpacePreviewLoader {
    static func thumbnail(at url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 640, height: 320),
                scale: 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                continuation.resume(returning: thumbnail?.uiImage)
            }
        }
    }

    static func textPreview(at url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let collapsed = value
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !collapsed.isEmpty else { return nil }
            return String(collapsed.prefix(220))
        }.value
    }

    static func audioDuration(at url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = max(0, Int(duration.seconds.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @MainActor
    static func mapSnapshot(for query: String) async -> UIImage? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        let cacheKey = "your-space-map-\(trimmedQuery.lowercased())"
        if let cached = await ImageCache.shared.imageAsync(for: cacheKey) {
            return cached
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery
        guard let response = try? await MKLocalSearch(request: request).start(),
              let coordinate = response.mapItems.first?.location.coordinate else {
            return nil
        }

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        )
        options.size = CGSize(width: 640, height: 320)
        options.scale = 2
        options.showsBuildings = true

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        let image = renderer.image { _ in
            snapshot.image.draw(at: .zero)
            let point = snapshot.point(for: coordinate)
            let marker = UIImage(systemName: "mappin.circle.fill")?.withTintColor(
                .systemRed,
                renderingMode: .alwaysOriginal
            )
            marker?.draw(in: CGRect(x: point.x - 18, y: point.y - 36, width: 36, height: 36))
        }
        ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
        return image
    }
}
