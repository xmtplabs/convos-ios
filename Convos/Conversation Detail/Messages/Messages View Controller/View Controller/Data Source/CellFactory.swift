import ConvosCore
import UIKit

// swiftlint:disable force_cast

final class CellFactory {
    static func createCell(in collectionView: UICollectionView,
                           for indexPath: IndexPath,
                           with item: MessagesListItemType,
                           onTapAvatar: @escaping () -> Void) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier,
                                                      for: indexPath) as! MessagesListItemTypeCell
        cell.setup(item: item, onTapAvatar: onTapAvatar)
        return cell
    }
}

// swiftlint:enable force_cast
