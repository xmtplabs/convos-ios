import ConvosCore
import UIKit

@MainActor
struct MessageCellActions {
    let onTapInvite: (MessageInvite) -> Void
    let onTapAvatar: (AnyMessage) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void
}

// swiftlint:disable force_cast

@MainActor
final class CellFactory {
    static func createCell(
        in collectionView: UICollectionView,
        for indexPath: IndexPath,
        with item: MessagesListItemType,
        actions: MessageCellActions
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier,
            for: indexPath
        ) as! MessagesListItemTypeCell
        cell.setup(item: item, actions: actions)
        return cell
    }
}

// swiftlint:enable force_cast
