#if canImport(UIKit)
import UIKit

/// Collection view that applies quiescent layout passes without inherited
/// animations. Self-sizing invalidations triggered from an animated SwiftUI
/// render (e.g. a sent message appending inside the bottom group's cell)
/// otherwise inherit the in-flight CA transaction: the cell's bounds growth
/// animates while its center applies instantly, which reads as the visible
/// content dipping by half the height delta for a few frames. Two kinds of
/// passes keep their animations: batch updates (the layout reports those
/// via `isInBatchUpdates`) and passes inside an explicit UIView animation
/// (keyboard inset changes, rotation), which report a nonzero inherited
/// duration -- the SwiftUI transaction case measures zero there.
final class MessagesCollectionView: UICollectionView {
    override func layoutSubviews() {
        let layoutIsBatching = (collectionViewLayout as? MessagesCollectionLayout)?.isInBatchUpdates ?? false
        if layoutIsBatching || UIView.inheritedAnimationDuration > 0 {
            super.layoutSubviews()
        } else {
            UIView.performWithoutAnimation {
                super.layoutSubviews()
            }
        }
    }
}
#endif
