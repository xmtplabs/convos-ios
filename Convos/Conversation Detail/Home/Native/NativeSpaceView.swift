import ConvosComposer
import ConvosCore
import SwiftUI

/// The Context tab drawn from the Space document instead of its web page.
///
/// It draws the page's own title and description, and its tiles on the web
/// grid's geometry with each tile's preview rendered natively. Tapping one opens
/// the real page in the existing browsing chain, so nothing a reader could reach
/// before is unreachable now.
///
/// Gated behind `FeatureFlags.isNativeSpaceEnabled`; the web surface remains
/// the fallback for a Space that cannot serve documents.
struct NativeSpaceView: View {
    let spaceURL: URL
    let onOpen: (URL) -> Void
    /// Opens the invite picker, for the directory tile's spare cell — the same
    /// affordance the web tile offers through the native bridge.
    let onInvite: () -> Void
    /// Takes the reader to the agent, for the page's "Add anything" action.
    let onAsk: () -> Void
    /// What to draw when this Space cannot serve a document at all. A Space
    /// deployed before the document route existed answers the page itself, so
    /// the tab shows that page rather than an error a reader cannot act on.
    let webFallback: AnyView

    @State private var state: LoadState

    @MainActor
    init(
        spaceURL: URL,
        onOpen: @escaping (URL) -> Void,
        onInvite: @escaping () -> Void,
        onAsk: @escaping () -> Void,
        webFallback: AnyView
    ) {
        self.spaceURL = spaceURL
        self.onOpen = onOpen
        self.onInvite = onInvite
        self.onAsk = onAsk
        self.webFallback = webFallback
        // Seeded rather than defaulted to `.loading`: this view is rebuilt from
        // scratch every time a page is pushed or popped, and starting from what
        // the Space last answered is what keeps that invisible.
        _state = State(initialValue: Self.seed(for: spaceURL))
    }

    /// The state a freshly built view starts in, given what this Space last said.
    @MainActor
    private static func seed(for spaceURL: URL) -> LoadState {
        switch SpaceDocumentStore.shared.outcome(for: spaceURL) {
        case let .loaded(document): .loaded(document)
        case let .unsupported(reason): .unsupported(reason)
        case nil: .loading
        }
    }

    private enum LoadState: Equatable {
        case loading
        case loaded(SpaceDocument)
        case failed(String)
        /// This deployment does not serve documents; the web page does. The
        /// string is why, for the diagnostic strip.
        case unsupported(String)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Color.colorBackgroundSurfaceless
                    Color.colorBackgroundSubtle
                }
                .ignoresSafeArea()
            }
            .task(id: spaceURL) {
                await load()
            }
            .accessibilityIdentifier("native-space")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HomePreparingView(stage: .loadingPage)
        case .unsupported:
            webFallback
        case let .failed(reason):
            failure(reason)
        case let .loaded(document):
            loaded(document)
        }
    }

    /// Draws the page's own children in document order.
    ///
    /// Not just the tiles: the starter's home page is
    /// `Page([Intro, WidgetGrid, AskAgentButton])`, so drawing the grid alone
    /// drops the prose that introduces it and the action beneath it. Nor the
    /// front-matter — the web page spends `title` and `description` on the
    /// document head, never on visible content.
    private func loaded(_ document: SpaceDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let root = document.rootNode {
                    ForEach(Array(root.children.enumerated()), id: \.offset) { _, child in
                        SpacePageContent(
                            node: child,
                            widgetGrid: { widgets in AnyView(grid(widgets)) },
                            onAsk: onAsk
                        )
                    }
                }
            }
            .padding(.horizontal, Constant.gutter)
            .padding(.top, ConversationChromeMetrics.contentClearance)
            .padding(.bottom, DesignConstants.Spacing.step12x)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The same two-column geometry the web grid uses, so a tile lands where a
    /// reader who has seen the web page expects it: two columns of at most
    /// 165pt, 24pt gutters, and a full-width row for anything wider than 1x1.
    ///
    /// Rows are laid out by hand rather than with `LazyVGrid`, because a lazy
    /// grid has no way to let one cell span both columns.
    private func grid(_ widgets: [SpaceWidget]) -> some View {
        VStack(spacing: Constant.gutter) {
            ForEach(Self.rows(widgets)) { row in
                HStack(spacing: Constant.gutter) {
                    ForEach(row.widgets) { widget in
                        tile(widget)
                    }
                    // A row holding one small tile keeps it in the left column
                    // instead of stretching it across both.
                    if row.widgets.count == 1, row.widgets[0].columnSpan == 1 {
                        Color.clear
                    }
                }
            }
        }
        .frame(maxWidth: Constant.gridMaximum)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func tile(_ widget: SpaceWidget) -> some View {
        Button {
            open(widget)
        } label: {
            WidgetTile(widget: widget, onInvite: onInvite)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("native-space-widget-\(widget.route)")
    }

    /// One row of tiles, filled left to right, with a wide tile on its own row.
    private struct TileRow: Identifiable {
        let id: Int
        let widgets: [SpaceWidget]
    }

    private static func rows(_ widgets: [SpaceWidget]) -> [TileRow] {
        var rows: [TileRow] = []
        var current: [SpaceWidget] = []
        func flush() {
            guard !current.isEmpty else { return }
            rows.append(TileRow(id: rows.count, widgets: current))
            current = []
        }
        for widget in widgets {
            if widget.columnSpan == 2 {
                flush()
                rows.append(TileRow(id: rows.count, widgets: [widget]))
                continue
            }
            current.append(widget)
            if current.count == 2 { flush() }
        }
        flush()
        return rows
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text("This space could not load.")
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
            Button("Try again") {
                Task { await load() }
            }
            .font(.footnote.weight(.medium))
        }
        .multilineTextAlignment(.center)
        .padding(DesignConstants.Spacing.step6x)
        .accessibilityIdentifier("native-space-error")
    }

    private func open(_ widget: SpaceWidget) {
        guard let url = SpaceDocumentLoader.documentURL(
            base: spaceURL,
            route: widget.destination
        ) else { return }
        // Strip the JSON variant: a tap opens the page a reader can look at,
        // not the document the tile was drawn from.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }
        components.queryItems = nil
        guard let pageURL = components.url else { return }
        onOpen(pageURL)
    }

    private func load() async {
        // Only an unseeded view shows the loading state. A rebuild, or a revisit
        // with something already cached, redraws what it had and quietly checks
        // for a newer document behind it.
        if state == .loading, SpaceDocumentStore.shared.outcome(for: spaceURL) == nil {
            state = .loading
        }
        do {
            let document = try await SpaceDocumentLoader.load(base: spaceURL)
            SpaceDocumentStore.shared.record(.loaded(document), for: spaceURL)
            state = .loaded(document)
        } catch let error as SpaceDocumentLoader.LoadError {
            // A deployment that predates the document route serves its page as
            // HTML whatever the query string says, so an undecodable body means
            // "this Space has no documents", not "this Space is broken".
            // `unavailable` is the opposite: the route answered, its data did
            // not, and that is worth saying out loud.
            switch error {
            case .malformed:
                record(.unsupported("not a document"))
            case let .status(code):
                record(.unsupported("HTTP \(code)"))
            case .invalidURL, .unavailable:
                // A failure is transient and is not remembered; a reader who
                // comes back gets a fresh attempt rather than a stale error.
                // Anything already drawn stays drawn.
                if case .loaded = state { return }
                state = .failed(Self.describe(error))
            }
        } catch {
            if case .loaded = state { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func record(_ outcome: SpaceDocumentStore.Outcome) {
        SpaceDocumentStore.shared.record(outcome, for: spaceURL)
        switch outcome {
        case let .loaded(document): state = .loaded(document)
        case let .unsupported(reason): state = .unsupported(reason)
        }
    }

    private static func describe(_ error: SpaceDocumentLoader.LoadError) -> String {
        switch error {
        case .invalidURL: "The space address could not be read."
        case let .unavailable(reason): "The agent's data is not answering (\(reason))."
        case let .status(code): "The space answered \(code)."
        case .malformed: "The space sent something this build cannot read."
        }
    }

    private enum Constant {
        /// Mirrors `--tile-size` and `--space-lg` in the Space stylesheet.
        static let tileMaximum: CGFloat = 165.0
        static let gutter: CGFloat = 24.0
        /// Two columns plus the gutter between them.
        static let gridMaximum: CGFloat = tileMaximum * 2 + gutter
    }
}

/// One tile in the native grid.
///
/// The card is a placeholder for the typed preview that will draw here: it
/// carries the tile's item count when the document reports one, and its
/// caption underneath, which is where the web puts it too.
private struct WidgetTile: View {
    let widget: SpaceWidget
    let onInvite: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            // Mirrors `.space-index-tile`: the stylesheet's own radius, ground
            // and hairline, so the card reads as the one the page draws.
            RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
                .fill(SpaceTileStyle.fillMinimal)
                .overlay {
                    SpaceWidgetPreview(
                        widget: widget,
                        preview: widget.preview,
                        onInvite: onInvite
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: SpaceTileStyle.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
                        .strokeBorder(SpaceTileStyle.surface)
                }
                .aspectRatio(widget.aspectRatio, contentMode: .fit)
            // `.space-index-caption`
            Text(widget.title)
                .font(.system(size: 12))
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
