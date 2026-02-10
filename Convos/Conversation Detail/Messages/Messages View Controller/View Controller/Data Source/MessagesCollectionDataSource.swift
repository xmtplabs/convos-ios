import ConvosCore
import Foundation
import UIKit

protocol MessagesCollectionDataSource: UICollectionViewDataSource, MessagesLayoutDelegate {
    var sections: [MessagesCollectionSection] { get set }
    func prepare(with collectionView: UICollectionView)
    var onTapInvite: ((MessageInvite) -> Void)? { get set }
    var onTapAvatar: ((ConversationMember) -> Void)? { get set }
    var onTapReactions: ((AnyMessage) -> Void)? { get set }
    var onDoubleTap: ((AnyMessage) -> Void)? { get set }
    var onReply: ((AnyMessage) -> Void)? { get set }
}
