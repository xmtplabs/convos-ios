import UIKit

enum ConversationsSection: Int, CaseIterable {
    case pinned
    case list
}

final class ConversationsCompositionalLayout: UICollectionViewCompositionalLayout {
    /// Gates the fade/scale-in attributes for inserted rows. False until the
    /// view controller has applied its first populated snapshot, so the
    /// initial population always lands with UIKit's standard attributes: if
    /// the insert animation is interrupted (an apply while offscreen, or a
    /// follow-up non-animated apply), rows starting at alpha 0 would be left
    /// invisible until the next layout pass re-applies attributes.
    var animatesAppearingItems: Bool = false

    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) else {
            return nil
        }
        guard animatesAppearingItems else { return attributes }
        let copy = attributes.copy() as? UICollectionViewLayoutAttributes ?? attributes
        copy.alpha = 0
        copy.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        return copy
    }

    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath) else {
            return nil
        }
        let copy = attributes.copy() as? UICollectionViewLayoutAttributes ?? attributes
        copy.alpha = 0
        copy.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        return copy
    }
}
