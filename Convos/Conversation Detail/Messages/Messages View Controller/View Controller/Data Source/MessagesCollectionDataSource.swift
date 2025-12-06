import ConvosCore
import Foundation
import UIKit

protocol MessagesCollectionDataSource: UICollectionViewDataSource, MessagesLayoutDelegate {
    var sections: [MessagesCollectionSection] { get set }
    func prepare(with collectionView: UICollectionView)
    var onTapInvite: ((MessageInvite) -> Void)? { get set }
    var onTapAvatar: ((IndexPath) -> Void)? { get set }
}
