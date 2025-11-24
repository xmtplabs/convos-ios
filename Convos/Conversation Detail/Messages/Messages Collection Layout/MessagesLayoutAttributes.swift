import Foundation
import UIKit

// swiftlint:disable force_cast no_assertions

final class MessagesLayoutAttributes: UICollectionViewLayoutAttributes {
    var alignment: MessagesListItemAlignment = .fullWidth
    var interItemSpacing: CGFloat = 0
    var additionalInsets: UIEdgeInsets = .zero
    var viewSize: CGSize = .zero
    var adjustedContentInsets: UIEdgeInsets = .zero
    var visibleBoundsSize: CGSize = .zero
    var layoutFrame: CGRect = .zero

    #if DEBUG
    var id: UUID?
    #endif

    convenience init(kind: ItemKind, indexPath: IndexPath = IndexPath(item: 0, section: 0)) {
        switch kind {
        case .cell:
            self.init(forCellWith: indexPath)
        case .header:
            self.init(forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, with: indexPath)
        case .footer:
            self.init(forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, with: indexPath)
        }
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! MessagesLayoutAttributes
        copy.viewSize = viewSize
        copy.alignment = alignment
        copy.interItemSpacing = interItemSpacing
        copy.layoutFrame = layoutFrame
        copy.additionalInsets = additionalInsets
        copy.visibleBoundsSize = visibleBoundsSize
        copy.adjustedContentInsets = adjustedContentInsets
        #if DEBUG
        copy.id = id
        #endif
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        super.isEqual(object)
            && alignment == (object as? MessagesLayoutAttributes)?.alignment
            && interItemSpacing == (object as? MessagesLayoutAttributes)?.interItemSpacing
    }

    var kind: ItemKind {
        switch (representedElementCategory, representedElementKind) {
        case (.cell, nil):
            .cell
        case (.supplementaryView, .some(UICollectionView.elementKindSectionHeader)):
            .header
        case (.supplementaryView, .some(UICollectionView.elementKindSectionFooter)):
            .footer
        default:
            preconditionFailure("Unsupported element kind.")
        }
    }

    func typedCopy() -> MessagesLayoutAttributes {
        guard let typedCopy = copy() as? MessagesLayoutAttributes else {
            fatalError("Internal inconsistency.")
        }
        return typedCopy
    }
}

// swiftlint:enable force_cast no_assertions
