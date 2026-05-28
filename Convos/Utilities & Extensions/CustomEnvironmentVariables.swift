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
            .onAppear {
                // Get safe area insets from the window when the view appears
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    currentInsets = EdgeInsets(
                        top: window.safeAreaInsets.top,
                        leading: window.safeAreaInsets.left,
                        bottom: window.safeAreaInsets.bottom,
                        trailing: window.safeAreaInsets.right
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                // Update insets when orientation changes
                DispatchQueue.main.async {
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first {
                        currentInsets = EdgeInsets(
                            top: window.safeAreaInsets.top,
                            leading: window.safeAreaInsets.left,
                            bottom: window.safeAreaInsets.bottom,
                            trailing: window.safeAreaInsets.right
                        )
                    }
                }
            }
    }
}

public extension View {
    /// Injects an environment value `safeAreaInsets` that mirrors the system safe area insets
    /// so any descendant can access it via `@Environment(\.safeAreaInsets)`.
    func withSafeAreaEnvironment() -> some View {
        modifier(SafeAreaEnvironmentModifier())
    }
}

// MARK: - Conversation Read-Only Environment Value

private struct ConversationReadOnlyEnvironmentKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    /// True when the active conversation is in a read-only state — currently
    /// driven by `StaleDeviceObserver.isDeviceRemoved`. Descendant gesture
    /// modifiers (double-tap-react, swipe-to-reply) and the long-press
    /// context menu read this to suppress their interactive affordances
    /// without every call site having to thread an explicit flag through.
    var isConversationReadOnly: Bool {
        get { self[ConversationReadOnlyEnvironmentKey.self] }
        set { self[ConversationReadOnlyEnvironmentKey.self] = newValue }
    }
}
