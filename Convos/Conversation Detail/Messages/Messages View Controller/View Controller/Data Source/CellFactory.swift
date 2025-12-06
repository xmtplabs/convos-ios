import ConvosCore
import UIKit

// swiftlint:disable force_cast

final class CellFactory {
    static func createCell(in collectionView: UICollectionView,
                           for indexPath: IndexPath,
                           with item: MessagesListItemType,
                           onTapInvite: @escaping (MessageInvite) -> Void,
                           onTapAvatar: @escaping (AnyMessage) -> Void) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier,
                                                      for: indexPath) as! MessagesListItemTypeCell
        cell.setup(item: item, onTapAvatar: onTapAvatar, onTapInvite: onTapInvite)
        return cell
    }
}

// swiftlint:enable force_cast
