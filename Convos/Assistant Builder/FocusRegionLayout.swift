import Foundation

/// The shape of the focus canvas in a given moment. Models the full state
/// matrix from the locked layout-rules spec — top region (focused member)
/// is sized independently of the bottom region (me + others), and the
/// bottom region's two slots each pick a size variant.
///
/// Single source of truth: SwiftUI views read `topFraction`, `othersSlot`,
/// and `localSlot`, then SwiftUI's shared spring animates every transition.
struct FocusRegionLayout: Equatable {
    /// What the *local* user's bubble looks like in the bottom region.
    /// `.full` is the keyboard-bound editor in its tall form. The two
    /// compact variants render as `TypingDotsBubble` instead.
    enum LocalSlot: Equatable {
        case full                 // editor visible, full size
        case compactStaticDots    // I have text but I'm idle (other is the active typer)
        case compactNoDots        // I haven't started, other is typing
    }

    /// What the *other-members* bubble looks like. `.hidden` removes it
    /// from the layout entirely; otherwise it sits between the focused
    /// bubble and the local user's bubble.
    enum OthersSlot: Equatable {
        case hidden               // no others have any text
        case full                 // others' text shown in a full bubble
        case compactAnimatedDots  // others are typing but local user wins the Full slot
    }

    let topFraction: CGFloat
    let othersSlot: OthersSlot
    let localSlot: LocalSlot

    static let idle = FocusRegionLayout(topFraction: 0.5, othersSlot: .hidden, localSlot: .full)

    static func resolve(
        focusedTyping: Bool,
        local: AssistantBuilderViewModel.BubbleActivity,
        others: AssistantBuilderViewModel.BubbleActivity
    ) -> FocusRegionLayout {
        // Locked rule: when both local and others are actively typing, the
        // local user wins the Full slot on their own device. Others get the
        // animated dots indicator. Local has to pause (rest) before others
        // can grow into the Full bubble — that pause is the social signal.
        let localActive = local == .active
        let othersActive = others == .active

        // Top region collapses to the "rested focused member" form when
        // anyone in the bottom region is competing for attention. Otherwise
        // it's tall.
        let topFraction: CGFloat = focusedTyping
            ? 0.65
            : (localActive || othersActive || local == .resting || others == .resting ? 0.30 : 0.50)

        let othersSlot: OthersSlot
        let localSlot: LocalSlot

        switch (localActive, othersActive, local, others) {
        // Nobody has anything → just my empty editor.
        case (_, _, .empty, .empty):
            othersSlot = .hidden
            localSlot = .full

        // Just me typing/resting, others empty → my Full editor.
        case (_, _, _, .empty):
            othersSlot = .hidden
            localSlot = .full

        // Just others active or resting, I'm empty → others Full, my compact pill (no dots).
        case (_, _, .empty, _):
            othersSlot = .full
            localSlot = .compactNoDots

        // I'm actively typing AND others have text → I win the Full slot,
        // others get compact (animated dots if they're still actively
        // typing, no dots if they're resting between bursts).
        case (true, _, _, _):
            othersSlot = othersActive ? .compactAnimatedDots : .compactAnimatedDots
            localSlot = .full

        // I'm resting (have text but idle) AND others are active → others
        // expand to Full and I shrink to the compact static-dots pill.
        case (false, true, .resting, _):
            othersSlot = .full
            localSlot = .compactStaticDots

        // I'm resting AND others are also resting → both have text, neither
        // is active. Default to my Full slot (most recent caller); others
        // get the compact static-dots-style indicator (animated dots feels
        // wrong if they're not actively typing right now).
        case (false, false, .resting, .resting):
            othersSlot = .compactAnimatedDots
            localSlot = .full

        default:
            othersSlot = .hidden
            localSlot = .full
        }

        return FocusRegionLayout(
            topFraction: topFraction,
            othersSlot: othersSlot,
            localSlot: localSlot
        )
    }
}
