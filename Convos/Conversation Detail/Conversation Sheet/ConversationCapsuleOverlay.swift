import SwiftUI
import UIKit

/// Hosts the conversation's capsule in a window of its own, above the sheet.
///
/// The capsule has to be over the sheet and outlive it, and neither is possible
/// from inside the conversation. A presentation is added above the presenting
/// controller's view, so a capsule in the conversation sits behind the sheet;
/// a capsule inside the sheet is dismissed along with it. A window above the
/// one they both live in is over both, and answers to neither.
///
/// The window passes through every touch that is not the capsule's, so the Home
/// stays scrollable and the sheet keeps its own drag - the window is a place to
/// draw, not a layer that eats input.
struct ConversationCapsuleOverlay<Capsule: View>: ViewModifier {
    /// Whether the capsule should be on screen at all. The conversation hides it
    /// while it is leaving, so it does not outlive the screen it belongs to.
    var isVisible: Bool
    /// How many presentations the conversation expects to be over it and still
    /// wants the capsule: one while its own sheet is up, none while it is away.
    /// Anything beyond that is a menu, an alert or a picker, and the capsule has
    /// no business floating over it.
    var ownPresentationDepth: Int
    /// Covered by something the conversation knows about, rather than something
    /// the poll has to notice - the info sheet, which is raised from the app's
    /// chrome above this screen and never appears in this screen's own
    /// presentation chain.
    var isCovered: Bool
    @ViewBuilder var capsule: () -> Capsule

    func body(content: Content) -> some View {
        content.background {
            CapsuleWindowHost(
                isVisible: isVisible,
                ownPresentationDepth: ownPresentationDepth,
                isCovered: isCovered,
                capsule: capsule
            )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// The zero-size representable that owns the window. Embedded as a background so
/// it shares the conversation's lifetime: the window goes up when this appears
/// and comes down when it leaves.
private struct CapsuleWindowHost<Capsule: View>: UIViewControllerRepresentable {
    var isVisible: Bool
    var ownPresentationDepth: Int
    var isCovered: Bool
    @ViewBuilder var capsule: () -> Capsule

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.ownPresentationDepth = ownPresentationDepth
        controller.setCoveredByHost(isCovered)
        controller.update(capsule: capsule, isVisible: isVisible)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Coordinator) {
        controller.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}

    final class Controller: UIViewController {
        private var overlayWindow: PassthroughWindow?
        /// Typed, deliberately. An `AnyView` root is a different view to SwiftUI
        /// on every assignment, so the capsule's own `@State` was reset each time
        /// the conversation updated - which ate the flag that tells a re-tap from
        /// a tab change, and with it the first tap after the sheet came up.
        private var host: UIHostingController<CapsuleAppearance<Capsule>>?
        private var teardownTask: Task<Void, Never>?
        private var bottomConstraint: NSLayoutConstraint?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var presentationPoll: Timer?
        private var isCoveredByPresentation: Bool = false
        /// See `ConversationCapsuleOverlay.ownPresentationDepth`.
        var ownPresentationDepth: Int = 0
        /// Coverage the conversation reports directly. Kept apart from the
        /// polled kind so either can end without waiting for the other.
        private var isCoveredByHost: Bool = false
        /// Consecutive polls that saw something covering the sheet.
        ///
        /// A presentation reaches the hierarchy a moment before the state that
        /// describes it settles, so a single covered poll is as likely to be the
        /// conversation's own sheet arriving as it is to be something over it.
        /// Hiding on the second one holds the capsule still through that,
        /// while showing it again takes effect on the first uncovered poll.
        private var coveredPolls: Int = 0

        func update(capsule: @escaping () -> Capsule, isVisible: Bool) {
            guard isVisible else {
                fadeOutAndTearDown()
                return
            }
            teardownTask?.cancel()
            teardownTask = nil
            guard let scene = view.window?.windowScene else { return }
            if let host {
                // Never a bare `true`: an update landing while a menu is over the
                // sheet would pop the capsule back on top of it until the next
                // poll. See `applyPresentationCoverage`.
                host.rootView = CapsuleAppearance(isPresent: !isCoveredByPresentation, content: capsule)
                return
            }

            // The hosted view is sized to the capsule and pinned to the bottom,
            // rather than filling the window with the capsule somewhere inside it.
            // That is what makes the passthrough work: SwiftUI renders its content
            // into one view, so a full-screen host is indistinguishable from its
            // own background under hit-testing - every touch either hits the whole
            // screen or none of it.
            let controller = UIHostingController(
                rootView: CapsuleAppearance(isPresent: true, content: capsule)
            )
            controller.view.backgroundColor = .clear
            controller.sizingOptions = [.intrinsicContentSize]
            // No safe area for the hosted content. A hosting controller insets
            // its SwiftUI view by the safe area by default, and with intrinsic
            // sizing that inset becomes part of the view's own height - so the
            // capsule sat a home-indicator's worth above where it was pinned,
            // inside its own padding. The constraint below is what positions it.
            controller.safeAreaRegions = []
            controller.view.translatesAutoresizingMaskIntoConstraints = false

            let root = UIViewController()
            root.view.backgroundColor = .clear
            root.addChild(controller)
            root.view.addSubview(controller.view)
            controller.didMove(toParent: root)
            // The keyboard guide rather than the window's bottom, so the capsule
            // rides up with the keyboard and keeps its distance from the composer
            // instead of being buried behind it.
            //
            // `usesBottomSafeArea = false` is what makes the resting position
            // right: with it on, a dismissed keyboard leaves the guide sitting at
            // the safe area, which would lift the capsule a home indicator's
            // height above where a native tab bar sits. Off, the guide tracks the
            // window's own bottom edge when there is no keyboard.
            let keyboard = root.view.keyboardLayoutGuide
            keyboard.usesBottomSafeArea = false
            let bottom = controller.view.bottomAnchor.constraint(
                equalTo: keyboard.topAnchor,
                constant: -ConversationSheetMetrics.capsuleBottomInset
            )
            NSLayoutConstraint.activate([
                controller.view.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
                bottom
            ])
            bottomConstraint = bottom
            observeKeyboard()
            observePresentationsOverSheet()

            let window = PassthroughWindow(windowScene: scene)
            window.rootViewController = root
            window.backgroundColor = .clear
            // Only the strip the capsule lives in, never the whole screen. A
            // full-screen window over the app's took the navigation bar's own
            // transition with it: the top bar's buttons stopped blurring
            // between the list and a conversation and swapped in a hard cut
            // instead. The capsule never rises past the keyboard, so a bottom
            // strip is all it needs.
            window.frame = Self.capsuleStripFrame(in: scene)
            window.isHidden = false
            // Above the sheet, below anything the system puts up for itself -
            // alerts and the status bar stay where they belong.
            window.windowLevel = .normal + 1
            overlayWindow = window
            host = controller
        }

        /// Hides the capsule while anything is presented over the sheet.
        ///
        /// The capsule is in a window of its own, which is what puts it above the
        /// sheet - and what puts it above a system menu too, since those are
        /// presented inside the main window rather than a window of their own.
        /// Nothing about a window level can fix that: above the sheet and below
        /// the sheet's own menus is not an ordering windows can express. So the
        /// capsule steps aside instead.
        ///
        /// Polled rather than observed because the presentation this is watching
        /// for is the system's: a SwiftUI `Menu` publishes no presented state, and
        /// a context menu is presented without a notification, a delegate or a
        /// window to hook. One pointer walk at 10Hz while a conversation is open
        /// is cheaper than the alternatives, and the menu's own animation covers
        /// the latency.
        private func observePresentationsOverSheet() {
            presentationPoll?.invalidate()
            let timer = Timer(timeInterval: Constant.presentationPollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPresentationCoverage() }
            }
            RunLoop.main.add(timer, forMode: .common)
            presentationPoll = timer
        }

        /// Fades the capsule out while something covers the sheet, and back when
        /// it goes. The sheet itself is the first presentation over the
        /// conversation and is what the capsule belongs with; a second
        /// presentation on top of it is a menu, an alert or a picker, and the
        /// capsule has no business floating over any of them.
        private func applyPresentationCoverage() {
            guard let host else { return }
            var conversationRoot: UIViewController = self
            while let parent = conversationRoot.parent {
                conversationRoot = parent
            }
            var depth: Int = 0
            var presented: UIViewController? = conversationRoot.presentedViewController
            while let controller = presented {
                depth += 1
                presented = controller.presentedViewController
            }
            // Deeper than the conversation's own sheet means something else is
            // over it. Counting rather than assuming the sheet is always the
            // first presentation: with the sheet away, a picker raised from the
            // conversation is itself the first, and the capsule used to float
            // over it.
            let isCovered: Bool = depth > ownPresentationDepth
            coveredPolls = isCovered ? coveredPolls + 1 : 0
            applyCoverage(coveredPolls >= Constant.coveredPollsBeforeHiding, host: host)
        }

        /// Records coverage the conversation reported itself, which needs no
        /// confirming - it is state, not an observation.
        func setCoveredByHost(_ covered: Bool) {
            guard isCoveredByHost != covered else { return }
            isCoveredByHost = covered
            guard let host else { return }
            applyCoverage(coveredPolls >= Constant.coveredPollsBeforeHiding, host: host)
        }

        /// Blurs the capsule away while it is covered, and back when it is not.
        ///
        /// The window stays up throughout, deliberately: taking it down and
        /// rebuilding it is what made the capsule crawl back after the info
        /// sheet closed, and there is nothing to tear down for - the capsule is
        /// coming straight back.
        private func applyCoverage(_ polled: Bool, host: UIHostingController<CapsuleAppearance<Capsule>>) {
            let isCovered: Bool = polled || isCoveredByHost
            guard isCovered != isCoveredByPresentation else { return }
            isCoveredByPresentation = isCovered
            host.rootView = CapsuleAppearance(isPresent: !isCovered, content: host.rootView.content)
        }

        /// The bottom strip the capsule window occupies, tall enough to hold
        /// the capsule when the keyboard has pushed it as high as it goes.
        private static func capsuleStripFrame(in scene: UIWindowScene) -> CGRect {
            let bounds = scene.screen.bounds
            let height = min(bounds.height, Constant.capsuleStripHeight)
            return CGRect(
                x: 0,
                y: bounds.height - height,
                width: bounds.width,
                height: height
            )
        }

        /// Swaps the inset as the keyboard comes and goes.
        ///
        /// Two values rather than one, because the guide tracks the keyboard's
        /// frame and that frame starts above the keyboard you can see - see
        /// `ConversationSheetMetrics.capsuleKeyboardBottomInset`.
        private func observeKeyboard() {
            let center = NotificationCenter.default
            keyboardObservers = [
                center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
                    let timing = KeyboardTiming(note)
                    MainActor.assumeIsolated { self?.applyKeyboardInset(keyboardIsUp: true, timing: timing) }
                },
                center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
                    let timing = KeyboardTiming(note)
                    MainActor.assumeIsolated { self?.applyKeyboardInset(keyboardIsUp: false, timing: timing) }
                }
            ]
        }

        /// Moves the capsule's inset on the keyboard's own curve.
        ///
        /// The guide already animates with the keyboard; changing the constant
        /// outside an animation made that 12pt jump instantly while the rest of the
        /// travel glided, so the capsule appeared to move at two speeds. The
        /// notification carries the duration and curve UIKit is using, and matching
        /// them is what puts the capsule, the composer and the keyboard on one
        /// motion.
        private func applyKeyboardInset(keyboardIsUp: Bool, timing: KeyboardTiming) {
            guard let root = overlayWindow?.rootViewController?.view else { return }
            bottomConstraint?.constant = -(keyboardIsUp
                ? ConversationSheetMetrics.capsuleKeyboardBottomInset
                : ConversationSheetMetrics.capsuleBottomInset)

            UIView.animate(
                withDuration: timing.duration,
                delay: 0,
                options: timing.options
            ) {
                root.layoutIfNeeded()
            }
        }

        /// Blurs the capsule away, then takes the window down.
        ///
        /// The window has to outlive the animation - hiding it first would cut the
        /// capsule off mid-fade - so the teardown waits, and is cancelled if the
        /// conversation comes back before it lands.
        private func fadeOutAndTearDown() {
            guard let host, teardownTask == nil else { return }
            host.rootView = CapsuleAppearance(isPresent: false, content: host.rootView.content)
            teardownTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                self?.tearDown()
            }
        }

        func tearDown() {
            teardownTask?.cancel()
            teardownTask = nil
            presentationPoll?.invalidate()
            presentationPoll = nil
            isCoveredByPresentation = false
            isCoveredByHost = false
            coveredPolls = 0
            keyboardObservers.forEach(NotificationCenter.default.removeObserver)
            keyboardObservers = []
            bottomConstraint = nil
            overlayWindow?.isHidden = true
            overlayWindow = nil
            host = nil
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            tearDown()
        }
    }
}

/// Blurs and fades the capsule in as the conversation arrives, and back out as
/// it leaves - the capsule is in a window of its own, so it has no transition of
/// its own to inherit from the screen it belongs to.
private struct CapsuleAppearance<Content: View>: View {
    var isPresent: Bool
    var content: () -> Content

    @State private var hasAppeared: Bool = false

    private var shown: Bool { isPresent && hasAppeared }

    var body: some View {
        content()
            .blur(radius: shown ? 0 : CapsuleAppearanceMetrics.blurRadius)
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : CapsuleAppearanceMetrics.enterScale)
            .animation(.smooth(duration: CapsuleAppearanceMetrics.duration), value: shown)
            .onAppear { hasAppeared = true }
    }
}

private enum Constant {
    /// How often the capsule checks whether something has been presented over
    /// the sheet. Fast enough that the capsule is gone before a menu has
    /// finished animating in, slow enough to cost nothing.
    static let presentationPollInterval: TimeInterval = 0.1
    /// Two polls, so a presentation appearing a beat before the state that
    /// describes it cannot flicker the capsule out and back.
    static let coveredPollsBeforeHiding: Int = 2
    /// How much of the bottom of the screen the capsule's window covers. Deep
    /// enough for the capsule riding above a keyboard, shallow enough to leave
    /// the navigation bar - and its transitions - in the app's own window.
    static let capsuleStripHeight: CGFloat = 420
}

/// The duration and curve UIKit is using for the keyboard, lifted out of the
/// notification so the capsule can travel on the same motion.
struct KeyboardTiming: Sendable {
    var duration: Double
    var options: UIView.AnimationOptions

    init(_ note: Notification) {
        let info = note.userInfo
        duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let rawCurve = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 0
        options = UIView.AnimationOptions(rawValue: UInt(rawCurve) << 16)
    }
}

/// How the capsule arrives and leaves.
private enum CapsuleAppearanceMetrics {
    static let blurRadius: CGFloat = 12.0
    static let enterScale: CGFloat = 0.92
    static let duration: TimeInterval = 0.24
}

/// A window that only takes the touches its content actually wants.
///
/// Without this the window would swallow the whole screen: the Home would stop
/// scrolling and the sheet would stop dragging, because every touch would land
/// on a full-screen window with a capsule somewhere in it.
private final class PassthroughWindow: UIWindow {
    /// Never key, however much it is tapped.
    ///
    /// A window that becomes key makes the previous key window resign its first
    /// responder - which, when the capsule is tapped mid-typing, tears the
    /// keyboard down before the tab change can hand focus to the other lane. The
    /// capsule needs the touches, not the focus.
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The hosting controller's own view is the background: a hit that lands on
        // it and not on something inside it is a hit on nothing.
        return hit == rootViewController?.view ? nil : hit
    }
}

extension View {
    /// Floats a capsule above everything the conversation presents. See
    /// `ConversationCapsuleOverlay`.
    func conversationCapsuleOverlay<Capsule: View>(
        isVisible: Bool,
        ownPresentationDepth: Int,
        isCovered: Bool,
        @ViewBuilder capsule: @escaping () -> Capsule
    ) -> some View {
        modifier(ConversationCapsuleOverlay(
            isVisible: isVisible,
            ownPresentationDepth: ownPresentationDepth,
            isCovered: isCovered,
            capsule: capsule
        ))
    }
}
