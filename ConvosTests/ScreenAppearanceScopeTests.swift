@testable import Convos
import UIKit
import XCTest

/// Which controller the Agent tab's dark override lands on.
///
/// The scope is embedded deep inside the screen's own view tree, so the
/// controller it has to find is an ancestor: the one the navigation stack
/// pushed, or - with nothing pushing it - the one the presentation put on
/// screen. Landing anywhere below that leaves part of the screen (the
/// composer's glass, the sheet's own background, the keyboard) resolving
/// against the presenting scheme.
@MainActor
final class ScreenAppearanceScopeTests: XCTestCase {
    // MARK: - Pushed

    func testStylesThePushedScreenRatherThanTheWrapperItLivesIn() {
        let screen = UIViewController()
        let wrapper = UIViewController()
        let navigationController = UINavigationController(rootViewController: screen)
        embed(wrapper, in: screen)

        let scope = attachScope(style: .dark, to: wrapper)

        XCTAssertEqual(screen.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(wrapper.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(scope.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(navigationController.overrideUserInterfaceStyle, .unspecified)
    }

    // MARK: - Presented

    func testStylesThePresentedScreenWhenNothingPushedIt() throws {
        let presenter = UIViewController()
        let window = try showWindow(rootViewController: presenter)
        defer { dismantle(window) }
        let sheet = UIViewController()
        present(sheet, from: presenter)
        let wrapper = UIViewController()
        embed(wrapper, in: sheet)

        _ = attachScope(style: .dark, to: wrapper)

        XCTAssertEqual(sheet.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(wrapper.overrideUserInterfaceStyle, .unspecified)
        // The screen behind the sheet keeps its own appearance, so dismissing
        // cannot flash it dark.
        XCTAssertEqual(presenter.overrideUserInterfaceStyle, .unspecified)
    }

    /// A sheet that carries its own navigation stack is still a push as far as
    /// the override is concerned - the pushed branch has to keep winning.
    func testPushInsideAPresentedNavigationStackStylesThePushedScreen() throws {
        let presenter = UIViewController()
        let window = try showWindow(rootViewController: presenter)
        defer { dismantle(window) }
        let screen = UIViewController()
        let navigationController = UINavigationController(rootViewController: screen)
        present(navigationController, from: presenter)

        _ = attachScope(style: .dark, to: screen)

        XCTAssertEqual(screen.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(navigationController.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(presenter.overrideUserInterfaceStyle, .unspecified)
    }

    // MARK: - Neither

    /// Nothing pushed or presented this host, so the override stays on the
    /// nearest ancestor instead of climbing to the window's root.
    func testStylesTheNearestAncestorForAHostThatIsNeitherPushedNorPresented() throws {
        let root = UIViewController()
        let window = try showWindow(rootViewController: root)
        defer { dismantle(window) }
        let host = UIViewController()
        embed(host, in: root)

        _ = attachScope(style: .dark, to: host)

        XCTAssertEqual(host.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(root.overrideUserInterfaceStyle, .unspecified)
    }

    // MARK: - Bookkeeping

    func testClearingTheStyleHandsTheScreenItsOwnAppearanceBack() {
        let screen = UIViewController()
        let navigationController = UINavigationController(rootViewController: screen)
        let scope = attachScope(style: .dark, to: screen)
        XCTAssertEqual(screen.overrideUserInterfaceStyle, .dark)

        scope.style = .unspecified

        XCTAssertEqual(screen.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(navigationController.overrideUserInterfaceStyle, .unspecified)
    }

    /// The scope can be re-parented onto another screen (the same host
    /// re-presented, this time pushed). The screen it left keeps no override.
    func testMovingToAnotherScreenResetsThePreviousOne() throws {
        let presenter = UIViewController()
        let window = try showWindow(rootViewController: presenter)
        defer { dismantle(window) }
        let sheet = UIViewController()
        present(sheet, from: presenter)
        let scope = attachScope(style: .dark, to: sheet)
        XCTAssertEqual(sheet.overrideUserInterfaceStyle, .dark)

        let pushed = UIViewController()
        let navigationController = UINavigationController(rootViewController: pushed)
        scope.willMove(toParent: nil)
        scope.view.removeFromSuperview()
        scope.removeFromParent()
        embed(scope, in: pushed)

        XCTAssertEqual(sheet.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(pushed.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(navigationController.overrideUserInterfaceStyle, .unspecified)
    }

    // MARK: - Helpers

    /// Embeds `child` in `parent` the way UIKit does for a representable's
    /// controller, including the `didMove` the scope keys off.
    private func embed(_ child: UIViewController, in parent: UIViewController) {
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
    }

    private func attachScope(
        style: UIUserInterfaceStyle,
        to parent: UIViewController
    ) -> ScreenAppearanceScope.Controller {
        let scope = ScreenAppearanceScope.Controller()
        scope.style = style
        embed(scope, in: parent)
        return scope
    }

    /// Tears the window down so a presentation cannot outlive its test.
    private func dismantle(_ window: UIWindow) {
        window.rootViewController?.dismiss(animated: false)
        window.rootViewController = nil
        window.isHidden = true
    }

    /// A window of the test host's own scene, so presentations actually run
    /// and `presentingViewController` is set the way it is in the app.
    private func showWindow(rootViewController: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene to present in"
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    private func present(_ presented: UIViewController, from presenter: UIViewController) {
        let presentation = expectation(description: "presented")
        presenter.present(presented, animated: false) { presentation.fulfill() }
        wait(for: [presentation], timeout: 5.0)
        XCTAssertNotNil(presented.presentingViewController)
    }
}
