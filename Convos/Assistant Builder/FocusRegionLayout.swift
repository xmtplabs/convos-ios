import Foundation

/// Encodes the typing-state matrix from the plan (§5.4) as a single value
/// the view can derive layout fractions from. Keeping this as a pure value
/// type means the view body just reads `topFraction` / `bottomLayout` and
/// SwiftUI can interpolate between configurations with one shared animation.
struct FocusRegionLayout: Equatable {
    enum BottomLayout: Equatable {
        /// User bubble fills the bottom region; no other-members bubble.
        case userOnly
        /// Other-members bubble fills the bottom region; user bubble has 0
        /// width and is hidden.
        case othersOnly
        /// Both bubbles share the bottom region. `userFraction` is in (0, 1).
        case split(userFraction: CGFloat)
    }

    let topFraction: CGFloat
    let bottomLayout: BottomLayout

    static let idle = FocusRegionLayout(topFraction: 0.5, bottomLayout: .userOnly)

    /// Resolve the layout from the typing state, mirroring the table in the
    /// plan exactly. "Typing" means the corresponding bubble has non-empty
    /// text in the active session.
    static func resolve(userTyping: Bool, othersTyping: Bool, othersJustStopped: Bool = false) -> FocusRegionLayout {
        switch (userTyping, othersTyping, othersJustStopped) {
        case (false, false, _):
            return .init(topFraction: 0.5, bottomLayout: .userOnly)
        case (true, false, false):
            return .init(topFraction: 0.5, bottomLayout: .userOnly)
        case (false, true, false):
            return .init(topFraction: 0.3, bottomLayout: .split(userFraction: 0.3))
        case (true, true, _):
            return .init(topFraction: 0.5, bottomLayout: .split(userFraction: 0.5))
        case (true, false, true):
            return .init(topFraction: 0.7, bottomLayout: .split(userFraction: 0.7))
        case (false, true, true):
            // "Other started, then stopped, user has nothing yet" — give
            // their final phrase the bottom and shrink user to a sliver.
            return .init(topFraction: 0.3, bottomLayout: .split(userFraction: 0.3))
        }
    }
}
