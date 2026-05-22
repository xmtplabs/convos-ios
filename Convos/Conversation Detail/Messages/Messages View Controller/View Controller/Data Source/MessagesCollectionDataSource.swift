import ConvosCore
import Foundation
import SwiftUI
import UIKit

protocol MessagesCollectionDataSource: UICollectionViewDataSource, MessagesLayoutDelegate {
    var sections: [MessagesCollectionSection] { get set }
    func prepare(with collectionView: UICollectionView)
    var onTapInvite: ((MessageInvite) -> Void)? { get set }
    var onTapAvatar: ((ConversationMember) -> Void)? { get set }
    var onTapReactions: ((AnyMessage) -> Void)? { get set }
    var onTapReadReceipts: ((MessagesGroup) -> Void)? { get set }
    var onTapThinkingIndicator: ((ThinkingSessionDescriptor) -> Void)? { get set }
    var onReaction: ((String, String) -> Void)? { get set }
    var onToggleReaction: ((String, String) -> Void)? { get set }
    var onReply: ((AnyMessage) -> Void)? { get set }
    var contextMenuState: MessageContextMenuState? { get set }
    var shouldBlurPhotos: Bool { get set }
    var conversationId: String { get set }
    var onPhotoRevealed: ((String) -> Void)? { get set }
    var onPhotoHidden: ((String) -> Void)? { get set }
    var onPhotoDimensionsLoaded: ((String, Int, Int) -> Void)? { get set }
    var onAgentOutOfCredits: (() -> Void)? { get set }
    var onTapUpdateMember: ((ConversationMember) -> Void)? { get set }
    var onOpenFile: ((HydratedAttachment, AnyMessage) -> Void)? { get set }
    var onRetryMessage: ((AnyMessage) -> Void)? { get set }
    var onDeleteMessage: ((AnyMessage) -> Void)? { get set }
    var onRetryAssistantJoin: (() -> Void)? { get set }
    var onCopyInviteLink: (() -> Void)? { get set }
    var onConvoCode: (() -> Void)? { get set }
    var onInviteAssistant: (() -> Void)? { get set }
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)? { get set }
    var memberContactOverride: ((String) -> Contact?)? { get set }
    var hasAssistant: Bool { get set }
    var isAssistantJoinPending: Bool { get set }
    var isAssistantEnabled: Bool { get set }
    var headerMode: MessagesHeaderMode { get set }
    var assistantBuilderTransitionNamespace: Namespace.ID? { get set }
    var hidesInviteCard: Bool { get set }
}
