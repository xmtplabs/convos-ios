import ConvosComposer
import ConvosCore
import SwiftUI

/// The Context tab drawn from the Space document instead of its web page.
///
/// A first pass: it draws the page's own title and description and a grid of
/// its tiles, and opens a tapped tile in the existing web surface. The typed
/// previews inside each tile (`NotesPreview`, `EventsPreview`, …) arrive in the
/// same document and are deliberately not drawn yet — the cells carry a caption
/// and a count for now, and become native one type at a time.
///
/// Gated behind `FeatureFlags.isNativeSpaceEnabled`; the web surface remains
/// the default and the fallback.
struct NativeSpaceView: View {
    let spaceURL: URL
    let onOpen: (URL) -> Void
    /// What to draw when this Space cannot serve a document at all. A Space
    /// deployed before the document route existed answers the page itself, so
    /// the tab shows that page rather than an error a reader cannot act on.
    let webFallback: AnyView

    @State private var state: LoadState = .loading

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
            .overlay(alignment: .top) { diagnostic }
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

    /// A one-line answer to "why am I looking at this?".
    ///
    /// The fallback is otherwise indistinguishable from the tab never having
    /// changed, which is exactly the question that comes up while this surface
    /// is being brought up. Outside production only, and it goes before merge.
    @ViewBuilder
    private var diagnostic: some View {
        if !ConfigManager.shared.currentEnvironment.isProduction, let note = diagnosticNote {
            Text(note)
                .font(.caption2.monospaced())
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .padding(.vertical, DesignConstants.Spacing.stepHalf)
                .background(Capsule().fill(Color.colorBackgroundSurfaceless))
                .overlay(Capsule().strokeBorder(Color.colorBorderSubtle))
                .padding(.top, ConversationChromeMetrics.contentClearance)
                .accessibilityIdentifier("native-space-diagnostic")
        }
    }

    private var diagnosticNote: String? {
        // Two facts answer every question this surface raises. The host says
        // which environment served the Space — a shared-dev host cannot serve
        // documents at all. The variant says whether this build is even asking
        // for the paired backend, which separates "the pin never applied" from
        // "the pin applied and routing dropped it".
        let host = spaceURL.host() ?? "?"
        let variant = FeatureFlags.shared.effectiveAgentVariantSlug ?? "none"
        switch state {
        case .loading: return nil
        case .loaded: return "native · \(host) · v:\(variant)"
        case let .unsupported(reason): return "web · \(reason) · \(host) · v:\(variant)"
        case .failed: return "error · \(host) · v:\(variant)"
        }
    }

    private func loaded(_ document: SpaceDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
                header(document)
                if document.widgets.isEmpty {
                    Text("This space has no tiles yet.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                } else {
                    grid(document.widgets)
                }
                provenance(document)
            }
            .padding(.horizontal, Constant.gutter)
            // The diagnostic floats above the content, so the page starts below
            // it rather than under it.
            .padding(
                .top,
                ConversationChromeMetrics.contentClearance
                    + (diagnosticNote == nil ? 0 : Constant.diagnosticClearance)
            )
            .padding(.bottom, DesignConstants.Spacing.step12x)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func header(_ document: SpaceDocument) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text(document.metadata.title ?? "Space")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            if let description = document.metadata.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
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
            WidgetTile(widget: widget)
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

    private func provenance(_ document: SpaceDocument) -> some View {
        // Which deployment drew this is the first thing worth knowing when a
        // tile looks stale, and it is the key a later cache will invalidate on.
        Text(verbatim: "\(document.widgets.count) tiles · \(document.commitSha.prefix(7))")
            .font(.caption2)
            .foregroundStyle(.colorTextSecondary)
            .accessibilityIdentifier("native-space-provenance")
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
        state = .loading
        do {
            let document = try await SpaceDocumentLoader.load(base: spaceURL)
            state = .loaded(document)
        } catch let error as SpaceDocumentLoader.LoadError {
            // A deployment that predates the document route serves its page as
            // HTML whatever the query string says, so an undecodable body means
            // "this Space has no documents", not "this Space is broken".
            // `unavailable` is the opposite: the route answered, its data did
            // not, and that is worth saying out loud.
            switch error {
            case .malformed:
                state = .unsupported("not a document")
            case let .status(code):
                state = .unsupported("HTTP \(code)")
            case .invalidURL, .unavailable:
                state = .failed(Self.describe(error))
            }
        } catch {
            state = .failed(error.localizedDescription)
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
        /// Room for the floating diagnostic above the page.
        static let diagnosticClearance: CGFloat = 28.0
    }
}

/// One tile in the native grid.
///
/// The card is a placeholder for the typed preview that will draw here: it
/// carries the tile's item count when the document reports one, and its
/// caption underneath, which is where the web puts it too.
private struct WidgetTile: View {
    let widget: SpaceWidget

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                .fill(Color.colorBackgroundSurfaceless)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                        .strokeBorder(Color.colorBorderSubtle)
                }
                .overlay {
                    // Most tiles carry no count — it is only set where the page
                    // queried a collection — so the route stands in rather than
                    // leaving a card that reads as failed to load.
                    if let count = widget.itemCount {
                        Text(verbatim: "\(count)")
                            .font(.title.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                    } else {
                        Text(widget.route)
                            .font(.caption.monospaced())
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, DesignConstants.Spacing.step2x)
                    }
                }
                .aspectRatio(widget.aspectRatio, contentMode: .fit)
            Text(widget.title)
                .font(.footnote)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)
        }
    }
}
