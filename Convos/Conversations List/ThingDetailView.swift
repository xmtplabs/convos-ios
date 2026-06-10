import ConvosCore
import ConvosLogging
import ConvosMetrics
import SwiftUI

/// Push-friendly companion to `AttachmentPreviewSheet`: shows the same
/// rendered HTML preview the in-conversation tap shows, but inside the
/// Things tab's navigation stack (no inner NavigationStack of its own —
/// the parent stack owns the back button).
///
/// On appear, loads the local file URL for the attachment via
/// `FileAttachmentLoader`. While the file is downloading we render a
/// `colorFillTertiary` placeholder so the push transition has something
/// to land on.
struct ThingDetailView: View {
    let item: ThingOverviewItem

    @State private var fileURL: URL?
    @State private var htmlBodyBackgroundColor: Color?
    @State private var loadError: String?
    @State private var navState: StuffDetailNavigatorImpl = .init()
    @State private var navigator: StuffDetailCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = StuffDetailCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        content
            .background(htmlBodyBackgroundColor ?? Color.colorFillMinimal)
            .ignoresSafeArea()
            .toolbarVisibility(.hidden, for: .tabBar)
            .toolbar { trailingShareButton }
            .task(id: item.attachmentKey) {
                await loadFile()
            }
            .onAppear {
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
            }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let fileURL {
                AttachmentHTMLContent(
                    fileURL: fileURL,
                    onBodyBackgroundColor: { color in
                        withAnimation(.easeOut(duration: 0.35)) {
                            htmlBodyBackgroundColor = color
                        }
                    }
                )
                .transition(.opacity)
            }
            if loadError != nil {
                VStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.colorTextSecondary)
                    Text("Couldn't load preview")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: fileURL)
        .animation(.easeOut(duration: 0.35), value: loadError)
    }

    @ToolbarContentBuilder
    private var trailingShareButton: some ToolbarContent {
        if let fileURL {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                .accessibilityIdentifier("thing-detail-share")
            }
        }
    }

    private func loadFile() async {
        do {
            let url = try await FileAttachmentLoader.loadFile(for: item.hydratedAttachment)
            fileURL = url
        } catch {
            Log.error("ThingDetailView: failed to load file for \(item.conversation.id): \(error)")
            loadError = error.localizedDescription
        }
    }
}
