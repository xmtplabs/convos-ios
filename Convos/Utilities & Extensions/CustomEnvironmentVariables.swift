import SwiftUI

// MARK: - Safe Area Insets Environment Value

private struct SafeAreaInsetsEnvironmentKey: EnvironmentKey {
    static let defaultValue: EdgeInsets = EdgeInsets()
}

public extension EnvironmentValues {
    var safeAreaInsets: EdgeInsets {
        get { self[SafeAreaInsetsEnvironmentKey.self] }
        set { self[SafeAreaInsetsEnvironmentKey.self] = newValue }
    }
}

// MARK: - View Modifier to inject safe area insets into environment

private struct SafeAreaEnvironmentModifier: ViewModifier {
    @State private var currentInsets: EdgeInsets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .environment(\.safeAreaInsets, currentInsets)
            // The window safe area can change without an orientation event —
            // notably when an iPad app window is moved or resized in Stage
            // Manager. Observing the live safe area keeps the value current;
            // a stale value mispositions overlays like the app-indicator pill
            // in a floating window. The observed proxy inset includes any
            // `additionalTopSafeArea`, so the action re-reads the base window
            // inset to preserve the existing positioning math.
            .onGeometryChange(for: EdgeInsets.self) { proxy in
                proxy.safeAreaInsets
            } action: { _ in
                updateInsets()
            }
            .onAppear { updateInsets() }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                DispatchQueue.main.async { updateInsets() }
            }
    }

    private func updateInsets() {
        guard let window = Self.activeWindow() else { return }
        let insets = EdgeInsets(
            top: window.safeAreaInsets.top,
            leading: window.safeAreaInsets.left,
            bottom: window.safeAreaInsets.bottom,
            trailing: window.safeAreaInsets.right
        )
        if insets != currentInsets {
            currentInsets = insets
        }
    }

    /// The foreground-active scene's key window (falling back to the first
    /// available), so we read the safe area of the window the app is
    /// actually shown in rather than an arbitrary connected scene.
    private static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    }
}

public extension View {
    /// Injects an environment value `safeAreaInsets` that mirrors the system safe area insets
    /// so any descendant can access it via `@Environment(\.safeAreaInsets)`.
    func withSafeAreaEnvironment() -> some View {
        modifier(SafeAreaEnvironmentModifier())
    }
}
