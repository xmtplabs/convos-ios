import ConvosBridge
import ConvosCore
import UIKit
import WebKit

/// Keeps one home web view built and warm, so opening a conversation adopts it
/// instead of paying to create one.
///
/// A freshly created `WKWebView` takes roughly a third of a second to reach its
/// first provisional navigation - measured, and near identical whether the load
/// is cold or warm, because it is WebKit standing the view up rather than
/// anything on the network. On a warm open that was most of the wait. Warming a
/// *separate* view does not help: the cost belongs to the instance the surface
/// actually renders, so the warm one has to be the one handed over.
///
/// The pool holds a single view. That is what the app needs (one home is on
/// screen at a time) and it keeps the memory of an idle web content process to
/// one, rather than one per conversation ever visited.
@MainActor
final class HomeWebViewPool {
    static let shared: HomeWebViewPool = HomeWebViewPool()

    /// The view waiting to be adopted, parked behind the app so WebKit treats
    /// it as live and finishes its setup. Nil while it is out on loan.
    private var idle: WKWebView?
    /// What the spare view has been pointed at, and how far it got, so a
    /// surface adopting it knows whether it still has to load anything.
    private var prepared: Prepared = .none
    /// The window the spare view waits in. See `parkingWindow()`.
    private var parking: UIWindow?

    /// How ready the spare view is for a given destination.
    enum Adoption: Equatable {
        /// Nothing useful loaded; the surface loads the page itself.
        case unprepared
        /// This exact page is already on its way.
        case loading
        /// This exact page is already drawn - there is nothing to wait for.
        case painted
    }

    private enum Prepared: Equatable {
        case none
        case loading(URL)
        case painted(URL, at: Date)

        var url: URL? {
            switch self {
            case .none: nil
            case .loading(let url): url
            case let .painted(url, _): url
            }
        }
    }

    private init() {}

    /// Points the spare view at a page before anything asks to see it.
    ///
    /// Called when a conversation is selected, which is a push animation ahead
    /// of the home surface existing. The load and the transition then overlap
    /// instead of running back to back, which is the difference between the
    /// home arriving with the screen and arriving after it.
    func prepare(url: URL) {
        warm()
        guard let idle, !Self.isSameDestination(prepared.url, url) else {
            Log.info("[PERF] HomeWebViewPool.prepare skipped: idle=\(idle != nil) alreadyPrepared=\(prepared.url == url)")
            return
        }
        Log.info("[PERF] HomeWebViewPool.prepare: \(url.host() ?? "?")\(url.path())")
        prepared = .loading(url)
        armPaint(on: idle)
        paintReporter(of: idle)?.onPaint = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .loading(let loading) = self.prepared, loading == url else { return }
                self.prepared = .painted(url, at: Date())
            }
        }
        idle.load(URLRequest(url: url))
    }

    /// How ready the spare view is for this destination, were it adopted now.
    func adoption(for url: URL?) -> Adoption {
        guard let url, idle != nil else {
            Log.info("[PERF] HomeWebViewPool.adoption: unprepared (url=\(url != nil) idle=\(idle != nil))")
            return .unprepared
        }
        switch prepared {
        case let .painted(painted, at) where Self.isSameDestination(painted, url)
            && Date().timeIntervalSince(at) < Constant.freshness:
            Log.info("[PERF] HomeWebViewPool.adoption: painted")
            return .painted
        case let .loading(loading) where Self.isSameDestination(loading, url):
            Log.info("[PERF] HomeWebViewPool.adoption: loading")
            return .loading
        default:
            Log.info("[PERF] HomeWebViewPool.adoption: mismatch (prepared=\(prepared.url?.path() ?? "none") wanted=\(url.path()))")
            return .unprepared
        }
    }

    /// Builds the spare view if there isn't one. Safe to call repeatedly.
    func warm() {
        guard idle == nil else { return }
        let webView = makeWebView()
        parkOffscreen(webView)
        // A real load, so WebKit finishes the work it defers until one is
        // asked for. `about:blank` costs nothing and touches no network.
        if let blank = URL(string: "about:blank") {
            webView.load(URLRequest(url: blank))
        }
        idle = webView
    }

    /// Hands over a ready view, building one only if the spare is already out.
    ///
    /// The caller owns the view until it is released, and is responsible for
    /// pointing the delegates and the paint reporter at itself - the pool
    /// leaves both empty so a view in the pool cannot report to whoever used it
    /// last.
    func acquire() -> WKWebView {
        let webView: WKWebView = idle ?? makeWebView()
        idle = nil
        prepared = .none
        webView.removeFromSuperview()
        // Undo the parking. A view is untouchable while it waits, and handing
        // it over in that state gives the surface a web view that loads
        // perfectly and ignores every touch.
        webView.isHidden = false
        webView.isUserInteractionEnabled = true
        return webView
    }

    /// Takes a view back, cleared, and keeps it as the spare.
    ///
    /// Cleared means: no delegates, no paint reporter, nothing loading, and
    /// `about:blank` in place of the page it was showing - so the next
    /// conversation cannot inherit the last one's home, and nothing is retained
    /// through the configuration.
    func release(_ webView: WKWebView, showing url: URL? = nil, painted: Bool = false) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        paintReporter(of: webView)?.onPaint = nil
        paintReporter(of: webView)?.currentToken = nil
        // A view the pool is not keeping says nothing about the one it is. The
        // metadata describes the spare's page, so a second surface handing its
        // view back must not clear it: doing so left an idle view still loading
        // or already drawn while the next adoption was told it was unprepared,
        // and the page was loaded a second time.
        guard idle == nil else {
            webView.stopLoading()
            return
        }
        // A page that was on screen a moment ago is kept, not blanked. Popping
        // back to the list and going straight in again is the commonest way to
        // open a home, and reloading from scratch for it put the progress bar
        // back in front of a page the pool had already drawn once.
        if let url, painted {
            prepared = .painted(url, at: Date())
        } else {
            prepared = .none
            webView.stopLoading()
            if let blank = URL(string: "about:blank") {
                webView.load(URLRequest(url: blank))
            }
        }
        idle = webView
        // Parking moves a screen-sized view into a window, and a release
        // happens during the pop that caused it. Left in that transaction it
        // disturbs the transition running around it, so the view is put away
        // once the pop has finished with it.
        Task { @MainActor [weak self] in
            guard let self, self.idle === webView else { return }
            self.parkOffscreen(webView)
        }
    }

    /// The paint reporter installed on a pooled view, for the surface to point
    /// at itself while it holds the view.
    func paintReporter(of webView: WKWebView) -> HomeWebViewPaintReporter? {
        webView.configuration.userContentController.paintReporter
    }

    /// The convos bridge and host installed on a pooled view, for the surface
    /// to point the host's navigation at itself while it holds the view.
    func bridgeBinding(of webView: WKWebView) -> HomeBridgeBinding? {
        HomeBridgeBindingRegistry.shared.binding(for: webView.configuration.userContentController)
    }

    /// Builds a view that never enters the pool.
    ///
    /// The pool exists to give the Home's *first* paint a head start: one view,
    /// prewarmed on the likeliest space URL. A page browsed from the Home wants
    /// none of that. It loads a different URL, so there is nothing warm to
    /// inherit — and taking the idle view means inheriting the last page's
    /// painted frame and its parked geometry until the new load commits, which
    /// a reader sees as the previous page flashing at the wrong width.
    ///
    /// Its reporter and bridge register the same way, so everything keyed off
    /// the view still resolves.
    func makeDetachedWebView() -> WKWebView {
        makeWebView()
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The paint script is not installed here: it carries the token of the
        // load it belongs to, so it is reinstalled per load. See `armPaint`.
        //
        // The reporter is installed once, with the view, because a
        // configuration cannot be changed after the view is built. The reporter
        // forwards to whichever surface currently holds the view, and to nobody
        // while it is idle.
        let reporter = HomeWebViewPaintReporter()
        configuration.userContentController.add(
            reporter,
            name: HomeWebViewPaintReporter.messageName
        )
        HomeWebViewPaintReporterRegistry.shared.register(
            reporter,
            for: configuration.userContentController
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // The convos bridge is installed with the view, not by the surface that
        // adopts it. The pool's `prepare` loads the space URL before any surface
        // exists, and a bridge attached only on adoption would miss that load:
        // its document-start `convos.js` runs on the next navigation, and an
        // adopted page is not reloaded, so `window.convos` would never appear.
        // The message handler outlives every surface; the host it dispatches to
        // is repointed at whichever surface currently holds the view, and reset
        // when the view returns to the pool. See `HomeWebView.makeUIView`.
        let host = HomeBridgeHost()
        let bridge = ConvosWebBridge(plugins: HomeBridgePlugins.dispatchers(host: host))
        bridge.attach(to: webView)
        HomeBridgeBindingRegistry.shared.register(
            HomeBridgeBinding(bridge: bridge, host: host),
            for: configuration.userContentController
        )
        return webView
    }

    /// Arms the paint reporter for a load about to be issued on this view.
    ///
    /// The script is reinstalled per load with that load's token baked in,
    /// because a page reports its paint from the web content process and the
    /// report can arrive after the load that replaced it has already started.
    /// Without something to tell the two documents apart, the outgoing page's
    /// paint lifted the incoming page's cover and had it filed as drawn.
    ///
    /// Call it immediately before `load`, on the view that is about to load.
    func armPaint(on webView: WKWebView) {
        let token = UUID().uuidString
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        // `removeAllUserScripts` clears every document-start script, the convos
        // bridge's `window.convos` bootstrap among them. Reinstall it before the
        // paint script so the page it is about to load still gets the bridge;
        // without this the button-gating `window.convos` is defined only on the
        // warm `about:blank` and never on the space URL. The message handler is
        // not a user script, so it survives the clear untouched.
        if let bootstrap = ConvosWebBridge.bootstrapUserScript {
            controller.addUserScript(bootstrap)
        }
        controller.addUserScript(
            WKUserScript(
                source: HomeWebViewPaintReporter.script(token: token),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        paintReporter(of: webView)?.currentToken = token
    }

    /// Parks a view in the pool's own window, behind the app's.
    ///
    /// A window of its own, not the app's key window, and that is the point.
    /// WebKit will not render a view that is in no window, so the spare has to
    /// be in one - but inserting and removing a screen-sized view in the window
    /// that hosts the navigation bar disturbs the transitions running there:
    /// the top bar's buttons stopped animating between the list and a
    /// conversation, which is a push away from the moment the pool parks or
    /// takes back a view. Its own window is invisible behind the app's opaque
    /// one, renders all the same, and cannot interfere with anything.
    private func parkOffscreen(_ webView: WKWebView) {
        webView.isUserInteractionEnabled = false
        webView.isHidden = false
        guard let window = parkingWindow() else { return }
        webView.frame = window.bounds
        window.rootViewController?.view.addSubview(webView)
    }

    /// The pool's own window, made once, sitting below everything the app
    /// draws. Never key, never interactive: somewhere to render, nothing else.
    private func parkingWindow() -> UIWindow? {
        if let parking { return parking }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return nil
        }
        let window = ParkingWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.windowLevel = .normal - 1
        window.isHidden = false
        parking = window
        return window
    }

    /// Whether two URLs name the same page.
    ///
    /// Not `==`: a bare host and the same host with a trailing slash are the
    /// same destination to everyone except `URL`, and the app holds the first
    /// while WebKit reports the second.
    private static func isSameDestination(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ url: URL) -> String {
        var string = url.absoluteString
        while string.hasSuffix("/") {
            string.removeLast()
        }
        return string
    }

    private enum Constant {
        /// How long a drawn page may be adopted without reloading.
        ///
        /// The page is the agent's and changes when the agent changes it, so a
        /// kept copy cannot stand indefinitely - but within a minute the reader
        /// is coming straight back to what they just left, and showing them a
        /// loading state for it would be theatre.
        static let freshness: TimeInterval = 60
    }
}

/// The window the pool parks its spare view in: visible to WebKit, invisible to
/// the reader, and untouchable. It takes no touches at all, so it cannot shadow
/// the app's own window even by accident.
private final class ParkingWindow: UIWindow {
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Receives the page's own report that it has painted, and forwards it to
/// whoever currently holds the web view.
///
/// A class of its own because the handler is installed with the configuration
/// and outlives every surface that borrows the view: pointing it straight at a
/// coordinator would retain that coordinator for the life of the view, and
/// deliver one conversation's paint to the next conversation's surface.
final class HomeWebViewPaintReporter: NSObject, WKScriptMessageHandler {
    static let messageName: String = "homeFirstPaint"

    /// Called with the source of the report ("fcp" or "load"). Cleared while
    /// the view sits in the pool.
    var onPaint: ((String) -> Void)?

    /// The token of the load currently being waited on. A report carrying any
    /// other token is a document that has already been replaced, and saying so
    /// would reveal the new page's cover over a page that has not drawn.
    /// See `HomeWebViewPool.armPaint(on:)`.
    var currentToken: String?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName else { return }
        guard let body = message.body as? [String: Any],
              let token = body["token"] as? String,
              let currentToken,
              token == currentToken else { return }
        onPaint?((body["source"] as? String) ?? "unknown")
    }

    /// Asks the page to say when it has actually drawn, rather than guessing a
    /// delay after didFinish.
    ///
    /// Two signals, whichever comes first. `first-contentful-paint` is the real
    /// answer and `buffered: true` catches it even when it lands before this
    /// script runs. The load/double-rAF path is for pages that never emit a
    /// paint entry at all - two frames after `load` is the earliest moment a
    /// page has certainly rendered - so a page WebKit reports no paint timing
    /// for still reveals itself rather than sitting behind the cover until the
    /// fallback fires.
    static func script(token: String) -> String {
        """
    (function() {
        var reported = false;
        function report(source) {
            if (reported) { return; }
            reported = true;
            try {
                window.webkit.messageHandlers.\(messageName).postMessage({
                    source: source,
                    token: "\(token)"
                });
            } catch (error) {}
        }
        try {
            var observer = new PerformanceObserver(function(list) {
                var entries = list.getEntries();
                for (var i = 0; i < entries.length; i++) {
                    if (entries[i].name === 'first-contentful-paint') { report('fcp'); }
                }
            });
            observer.observe({ type: 'paint', buffered: true });
        } catch (error) {}
        window.addEventListener('load', function() {
            requestAnimationFrame(function() {
                requestAnimationFrame(function() { report('load'); });
            });
        });
    })();
    """
    }
}

private extension WKUserContentController {
    /// The reporter this controller was built with, if it still holds one.
    var paintReporter: HomeWebViewPaintReporter? {
        // WebKit exposes no way to read back a message handler, so the pool
        // keeps its own map rather than guessing. See `HomeWebViewPool`.
        HomeWebViewPaintReporterRegistry.shared.reporter(for: self)
    }
}

/// Maps a content controller to the reporter installed on it.
///
/// `WKUserContentController` will not hand back a handler once added, and the
/// pool needs to reach the one it installed to point it at the current surface.
/// Keys are weak so an evicted web view takes its entry with it.
@MainActor
final class HomeWebViewPaintReporterRegistry {
    static let shared: HomeWebViewPaintReporterRegistry = HomeWebViewPaintReporterRegistry()

    private let table: NSMapTable<WKUserContentController, HomeWebViewPaintReporter> =
        .weakToStrongObjects()

    private init() {}

    func register(_ reporter: HomeWebViewPaintReporter, for controller: WKUserContentController) {
        table.setObject(reporter, forKey: controller)
    }

    func reporter(for controller: WKUserContentController) -> HomeWebViewPaintReporter? {
        table.object(forKey: controller)
    }
}

/// The convos bridge installed on a pooled view, together with the mutable host
/// its plugins dispatch to.
///
/// The bridge is registered through a weak proxy, so it needs a strong owner:
/// the pool holds it here for the life of the view rather than the surface, so
/// `window.convos` survives a surface being torn down and the view returning to
/// the pool. The host's closures are repointed at each adopting surface and
/// reset when the view is released. See `HomeWebViewPool.makeWebView`.
@MainActor
final class HomeBridgeBinding {
    let bridge: ConvosWebBridge
    let host: HomeBridgeHost

    init(bridge: ConvosWebBridge, host: HomeBridgeHost) {
        self.bridge = bridge
        self.host = host
    }
}

/// Maps a content controller to the convos bridge binding installed on it.
///
/// The same reason as `HomeWebViewPaintReporterRegistry`: WebKit will not hand
/// a message handler back, so the pool keeps its own map to reach the bridge it
/// installed. Keys are weak so an evicted web view takes its entry with it.
@MainActor
final class HomeBridgeBindingRegistry {
    static let shared: HomeBridgeBindingRegistry = HomeBridgeBindingRegistry()

    private let table: NSMapTable<WKUserContentController, HomeBridgeBinding> =
        .weakToStrongObjects()

    private init() {}

    func register(_ binding: HomeBridgeBinding, for controller: WKUserContentController) {
        table.setObject(binding, forKey: controller)
    }

    func binding(for controller: WKUserContentController) -> HomeBridgeBinding? {
        table.object(forKey: controller)
    }
}
