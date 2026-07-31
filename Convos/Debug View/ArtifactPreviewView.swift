import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

/// Live preview for an HTML artifact written on the Mac.
///
/// Renders the file through the same two paths a real agent attachment
/// takes - `HTMLThumbnailRenderer` for the 160pt message tile and
/// `AttachmentHTMLContent` for the full-screen sheet - because the two
/// disagree on purpose: the thumbnail pass pins `data-convos-surface`
/// to "small", so an artifact can look right in one and broken in the
/// other. Seeing both at once is the point of the harness.
///
/// Delivery is `dev/artifact-preview <file.html>`, which copies the file
/// into the app container and re-copies it on every save.
struct ArtifactPreviewView: View {
    var onClose: (() -> Void)?

    @State private var store: ArtifactPreviewStore = ArtifactPreviewStore()
    @State private var thumbnail: UIImage?
    @State private var isRenderingThumbnail: Bool = false
    @State private var previewScheme: ColorScheme = .light

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let artifact = store.artifact {
                surfaces(for: artifact)
            } else {
                emptyState
            }
        }
        .background(Color.colorBackgroundSurfaceless)
        .task(id: thumbnailTaskKey) {
            await renderThumbnail()
        }
        .onAppear(perform: store.start)
        .onDisappear(perform: store.stop)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                VStack(alignment: .leading, spacing: 2.0) {
                    Text(store.artifact?.filename ?? "No artifact")
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.colorTextSecondary)
                }
                Spacer(minLength: 0.0)
                Button(action: store.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Picker("Appearance", selection: $previewScheme) {
                Text("Light").tag(ColorScheme.light)
                Text("Dark").tag(ColorScheme.dark)
            }
            .pickerStyle(.segmented)
            if let lastError = store.lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(DesignConstants.Spacing.step3x)
        .padding(.top, DesignConstants.Spacing.step2x)
    }

    private var subtitle: String {
        guard let artifact = store.artifact else {
            return "Waiting for a file"
        }
        let kilobytes: Double = Double(artifact.byteCount) / 1024.0
        let size: String = String(format: "%.1f KB", kilobytes)
        return "\(artifact.contentHash) - \(size) - reload #\(store.reloadCount)"
    }

    // MARK: - Surfaces

    @ViewBuilder
    private func surfaces(for artifact: ArtifactPreviewStore.Artifact) -> some View {
        VStack(spacing: 0) {
            tileSurface
            Divider()
            fullSurface(for: artifact)
        }
    }

    private var tileSurface: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step4x) {
            tileContent
                .frame(width: Constant.tileSize, height: Constant.tileSize)
                .background(Color.colorFillMinimal)
                .clipShape(RoundedRectangle(cornerRadius: Constant.tileCornerRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 4.0) {
                Text("Message tile")
                    .font(.footnote.weight(.medium))
                Text("160pt, data-convos-surface=small")
                    .font(.caption2)
                    .foregroundStyle(.colorTextSecondary)
            }
            Spacer(minLength: 0.0)
        }
        .padding(DesignConstants.Spacing.step3x)
    }

    @ViewBuilder
    private var tileContent: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Constant.tileSize, height: Constant.tileSize, alignment: .top)
                .clipped()
        } else {
            ZStack {
                Color.clear
                if isRenderingThumbnail {
                    ProgressView()
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Keyed on the reload count so every save tears down the representable
    /// and its coordinator. `AttachmentHTMLContent.updateUIView` short-
    /// circuits when the file URL is unchanged, and the path is stable
    /// across saves, so without a fresh identity an edit would never repaint.
    ///
    /// No `attachmentKey` is passed: that opts the sheet into borrowing a
    /// prewarmed WebView, which for a live preview is exactly the stale
    /// content we are trying to avoid.
    private func fullSurface(for artifact: ArtifactPreviewStore.Artifact) -> some View {
        AttachmentHTMLContent(fileURL: artifact.fileURL)
            .id(store.reloadCount)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, previewScheme)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Spacer()
            Text("Drop an artifact to preview it")
                .font(.headline)
            Text("dev/artifact-preview path/to/artifact.html")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.colorTextSecondary)
            Text(ArtifactPreviewStore.dropDirectory.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, DesignConstants.Spacing.step6x)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Thumbnail

    private var thumbnailTaskKey: AttachmentColorSchemeKey {
        AttachmentColorSchemeKey(
            key: store.artifact?.attachmentKey ?? "",
            scheme: previewScheme
        )
    }

    private func renderThumbnail() async {
        guard let artifact = store.artifact else {
            thumbnail = nil
            return
        }
        isRenderingThumbnail = true
        let rendered = await HTMLThumbnailRenderer.shared.thumbnail(
            for: artifact.attachmentKey,
            fileURL: artifact.fileURL,
            appearance: previewScheme.uiUserInterfaceStyle
        )
        isRenderingThumbnail = false
        thumbnail = rendered
    }

    private enum Constant {
        static let tileSize: CGFloat = 160.0
        static let tileCornerRadius: CGFloat = 20.0
    }
}
