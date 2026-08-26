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
    /// This conversation's Space, or nothing while one is still being made.
    let spaceURL: URL?
    /// Who is in the group, for the directory tile of the page drawn before the
    /// Space can answer for itself.
    let memberNames: [String]
    let onOpen: (URL, String?) -> Void
    /// Opens the group's own member list, for the directory tile — the same
    /// destination the conversation's info view opens.
    let onOpenMembers: () -> Void
    /// Opens the invite picker, for the directory tile's spare cell — the same
    /// affordance the web tile offers through the native bridge.
    let onInvite: () -> Void
    /// Takes the reader to the agent, for the page's "Add anything" action.
    let onAsk: () -> Void
    /// The window's top safe area. The Context tab is laid out full-bleed, so
    /// the chrome's own clearance — which is measured from below the safe area —
    /// does not by itself put content under the control.
    let topSafeAreaInset: CGFloat
    /// How far the page has scrolled up under the chrome, so the wash behind
    /// the segmented control can appear only once something is passing beneath
    /// it. At rest there is nothing to separate, and a wash over a page that is
    /// not moving just greys its own heading.
    let onScrollUnderChrome: (CGFloat) -> Void
    /// What to draw when this Space cannot serve a document at all. A Space
    /// deployed before the document route existed answers the page itself, so
    /// the tab shows that page rather than an error a reader cannot act on.
    let webFallback: AnyView

    @State private var state: LoadState
    @State private var events: SpaceEventsState = .empty
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    @MainActor
    init(
        spaceURL: URL?,
        memberNames: [String],
        topSafeAreaInset: CGFloat,
        onOpen: @escaping (URL, String?) -> Void,
        onOpenMembers: @escaping () -> Void,
        onInvite: @escaping () -> Void,
        onAsk: @escaping () -> Void,
        onScrollUnderChrome: @escaping (CGFloat) -> Void,
        webFallback: AnyView
    ) {
        self.spaceURL = spaceURL
        self.memberNames = memberNames
        self.topSafeAreaInset = topSafeAreaInset
        self.onOpen = onOpen
        self.onOpenMembers = onOpenMembers
        self.onInvite = onInvite
        self.onAsk = onAsk
        self.onScrollUnderChrome = onScrollUnderChrome
        self.webFallback = webFallback
        // Seeded rather than defaulted to `.loading`: this view is rebuilt from
        // scratch every time a page is pushed or popped, and starting from what
        // the Space last answered is what keeps that invisible.
        _state = State(initialValue: Self.seed(for: spaceURL, memberNames: memberNames))
    }

    /// The state a freshly built view starts in, given what this Space last said.
    ///
    /// A conversation with no Space yet starts on the page every Space opens
    /// with rather than on a spinner: the wait is for a URL, not for anything a
    /// reader would see change, so there is nothing to make them watch.
    @MainActor
    private static func seed(for spaceURL: URL?, memberNames: [String]) -> LoadState {
        let opening: LoadState = SpaceDocument.firstRun(memberNames: memberNames)
            .map { LoadState.loaded($0) } ?? .loading
        guard let spaceURL else { return opening }
        switch SpaceDocumentStore.shared.outcome(for: spaceURL) {
        case let .loaded(document): return .loaded(document)
        case let .unsupported(reason): return .unsupported(reason)
        case nil: return opening
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
            // Following costs a held request, so it runs only while the reader
            // is actually looking at it. `.task` is what makes that true in both
            // directions: it cancels when the tab is left or the app is
            // backgrounded, and starts again on the way back, keyed so a change
            // of Space or scene phase restarts it rather than leaving the old
            // one running.
            .task(id: FollowKey(space: spaceURL, phase: scenePhase)) {
                guard scenePhase == .active else { return }
                await follow()
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
                // Work the host could not tie to one route — an edited asset
                // rather than a page, which is what most content edits are —
                // belongs to the page rather than to any one tile.
                if let site = events.siteWideWork {
                    SiteWideWorkBanner(message: site.message)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let root = document.rootNode {
                    ForEach(Array(root.children.enumerated()), id: \.offset) { _, child in
                        SpacePageContent(
                            node: child,
                            widgetGrid: { widgets in
                                AnyView(grid(widgets, fileBase: fileBase(document)))
                            },
                            onAsk: onAsk
                        )
                    }
                }
            }
            // `.space-page`: a 402pt column, centred, with 24pt gutters.
            //
            // Its 56pt top band is deliberately not added on top of the chrome
            // clearance. In the web view that band and the scroll inset overlap
            // under the same floating bar; stacking both here put the first
            // heading a clear 56pt below where the page puts it.
            .padding(.horizontal, Constant.gutter)
            .padding(.top, topSafeAreaInset + ConversationChromeMetrics.contentClearance)
            .padding(.bottom, SpaceTileStyle.pageBottom)
            .frame(maxWidth: SpaceTileStyle.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // Reported rather than acted on here: the wash is a sibling of this
        // view, drawn over every tab by the conversation's own layout, so what
        // it does with this is the layout's business.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            onScrollUnderChrome(offset)
        }
        // A page that ends taller than the screen is not scrolled yet, and a
        // page swapped underneath a reader keeps whatever offset it had.
        .onDisappear { onScrollUnderChrome(0) }
    }

    /// Follows the Space, applying each new state as an animated change.
    ///
    /// Two things arrive on one snapshot: which routes an agent is editing, and
    /// which deployment is serving. The first decorates tiles in place. The
    /// second is what says the page itself changed, and it refetches rather
    /// than reloading, so the tab crossfades to the new document instead of
    /// emptying and drawing itself again.
    private func follow() async {
        guard let spaceURL else { return }
        await SpaceEventsFollower.follow(base: spaceURL) { next in
            let replaced = next.activeDeploymentId != nil
                && next.activeDeploymentId != currentDeploymentId
            withAnimation(.easeInOut(duration: 0.2)) { events = next }
            if replaced {
                Task { await load() }
            }
        }
    }

    /// What restarts following: a different Space, or a return to the
    /// foreground. Both have to re-open the held request, and neither should
    /// leave the previous one in flight.
    private struct FollowKey: Equatable {
        let space: URL?
        let phase: ScenePhase
    }

    private var currentDeploymentId: String? {
        if case let .loaded(document) = state { return document.deploymentId }
        return nil
    }

    /// Where a committed asset path resolves against for this document.
    private func fileBase(_ document: SpaceDocument) -> URL? {
        guard let spaceURL, let path = document.fileBasePath else { return nil }
        return URL(string: path, relativeTo: spaceURL)
    }

    /// The same two-column geometry the web grid uses, so a tile lands where a
    /// reader who has seen the web page expects it: two columns of at most
    /// 165pt, 24pt gutters, and a full-width row for anything wider than 1x1.
    ///
    /// Rows are laid out by hand rather than with `LazyVGrid`, because a lazy
    /// grid has no way to let one cell span both columns.
    private func grid(_ widgets: [SpaceWidget], fileBase: URL?) -> some View {
        VStack(spacing: Constant.gutter) {
            ForEach(Self.rows(widgets)) { row in
                HStack(spacing: Constant.gutter) {
                    ForEach(row.widgets) { widget in
                        tile(widget, fileBase: fileBase, work: events.work(at: widget.route))
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

    private func tile(_ widget: SpaceWidget, fileBase: URL?, work: PendingChange?) -> some View {
        Button {
            open(widget)
        } label: {
            WidgetTile(
                widget: widget,
                fileBase: fileBase,
                work: work,
                onInvite: onInvite
            )
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
        // The group's own members are a thing this app already knows how to
        // show, and shows from the conversation's info view. Opening the Space's
        // rendering of the same people instead would be a second, worse members
        // list — one that cannot tap through to a profile. Keyed on the
        // component rather than the route, because drawing the roster is what
        // makes a tile the directory.
        if widget.preview?.typeName == Constant.directoryPreview {
            onOpenMembers()
            return
        }
        // A tile drawn before the Space exists has no page behind it. Doing
        // nothing is the honest answer; the tile becomes live when the document
        // it stands in for arrives.
        guard let spaceURL else { return }
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
        onOpen(pageURL, widget.title)
    }

    private func load() async {
        // No Space yet: the first-run page stands until one is published, and
        // this runs again when it is, because the task is keyed on the URL.
        guard let spaceURL else { return }
        // Only an unseeded view shows the loading state. A rebuild, or a revisit
        // with something already cached, redraws what it had and quietly checks
        // for a newer document behind it.
        if state == .loading, SpaceDocumentStore.shared.outcome(for: spaceURL) == nil {
            state = .loading
        }
        do {
            let document = try await SpaceDocumentLoader.load(base: spaceURL)
            SpaceDocumentStore.shared.record(.loaded(document), for: spaceURL)
            // Animated, so a promotion arriving under the reader crossfades
            // rather than snapping — and a redelivery of the same document is
            // not an animation at all, because the state does not change.
            withAnimation(.easeInOut(duration: 0.25)) { state = .loaded(document) }
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
        if let spaceURL {
            SpaceDocumentStore.shared.record(outcome, for: spaceURL)
        }
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
        /// The component that makes a tile the group's member list.
        static let directoryPreview: String = "DirectoryPreview"
    }
}

/// What the page says while an agent is working somewhere it cannot name.
///
/// A quiet line rather than a progress bar: the page underneath is still the
/// page, and nothing here is finished enough to replace it with a wait.
private struct SiteWideWorkBanner: View {
    let message: String?

    @State private var pulsing: Bool = false

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Circle()
                .fill(SpaceTileStyle.lava)
                .frame(width: 6.0, height: 6.0)
                .opacity(pulsing ? 0.3 : 1.0)
            Text(message ?? "Your agent is updating this space")
                .font(SpaceTileStyle.noteFont)
                .foregroundStyle(SpaceTileStyle.lava)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpaceTileStyle.extraSmall)
        .task {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/// One tile in the native grid.
///
/// The card is a placeholder for the typed preview that will draw here: it
/// carries the tile's item count when the document reports one, and its
/// caption underneath, which is where the web puts it too.
private struct WidgetTile: View {
    let widget: SpaceWidget
    let fileBase: URL?
    /// The edit an agent has announced at this tile's route, if any.
    let work: PendingChange?
    let onInvite: () -> Void

    @State private var pulsing: Bool = false

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
                        fileBase: fileBase,
                        onInvite: onInvite
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: SpaceTileStyle.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
                        .strokeBorder(SpaceTileStyle.surface)
                }
                // A tile being edited breathes, rather than blinking: the border
                // is the signal and the content underneath is left alone, so
                // nothing a reader is looking at is replaced or hidden.
                .overlay {
                    if work != nil {
                        RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
                            .strokeBorder(SpaceTileStyle.lava, lineWidth: 2.0)
                            .opacity(pulsing ? 0.25 : 0.9)
                    }
                }
                .aspectRatio(widget.aspectRatio, contentMode: .fit)
            // While an agent is working the caption says what it is doing, in
            // the agent's own words, and returns to the tile's name after.
            // `.space-index-caption`
            Text(work?.message ?? widget.title)
                .font(.system(size: 12))
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(work == nil ? SpaceTileStyle.textPrimary : SpaceTileStyle.lava)
                .contentTransition(.opacity)
        }
        .task(id: work != nil) {
            guard work != nil else {
                pulsing = false
                return
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}
