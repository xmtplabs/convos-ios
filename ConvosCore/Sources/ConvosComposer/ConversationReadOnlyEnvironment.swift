#if canImport(UIKit)
import SwiftUI

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
#endif
