import ConvosCore
import UIKit

struct CellConfig {
    let shouldBlurPhotos: Bool
    let onTapInvite: (MessageInvite) -> Void
    let onTapAvatar: (AnyMessage) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
}

// swiftlint:disable force_cast

final class CellFactory {
    static func createCell(
        in collectionView: UICollectionView,
        for indexPath: IndexPath,
        with item: MessagesListItemType,
        config: CellConfig
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier,
            for: indexPath
        ) as! MessagesListItemTypeCell
        cell.setup(item: item, config: config)
        return cell
    }
}

// swiftlint:enable force_cast
