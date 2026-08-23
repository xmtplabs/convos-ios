import SwiftUI

/// Reports whether the Home tab currently has a page pushed, so a host that
/// renders its own leading toolbar item can stand down while the conversation
/// screen owns that slot with its back button.
///
/// Only the new-convo sheet needs this: presented modally it draws a close (X)
/// in the leading slot, and without the report both it and the browser's back
/// chevron render at once. Extracted into a modifier rather than another
/// `.onChange` on the conversation body, which is already at its type-check
/// budget (see CLAUDE.md build-performance notes).
struct HomeBrowsingReporter: ViewModifier {
    let isBrowsing: Bool
    let onChanged: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        content
            .onAppear { onChanged?(isBrowsing) }
            .onChange(of: isBrowsing) { _, newValue in onChanged?(newValue) }
            // Leaving the screen entirely ends the browsing chain as far as
            // the host is concerned; otherwise its own item stays hidden.
            .onDisappear { onChanged?(false) }
    }
}
