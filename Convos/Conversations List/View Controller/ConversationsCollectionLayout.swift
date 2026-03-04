import UIKit

enum ConversationsSection: Int, CaseIterable {
    case pinned
    case list
}

final class ConversationsCompositionalLayout: UICollectionViewCompositionalLayout {
    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) else {
            return nil
        }
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
